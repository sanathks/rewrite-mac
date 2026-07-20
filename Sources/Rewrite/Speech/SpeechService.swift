import AVFoundation
import CoreAudio
import Foundation

enum SpeechError: Error, LocalizedError {
    case modelNotFound
    case microphonePermissionDenied
    case transcriptionFailed(String)
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Speech model not found. Download it from Settings."
        case .microphonePermissionDenied:
            return "Microphone permission denied. Grant access in System Settings > Privacy."
        case .transcriptionFailed(let detail):
            return "Transcription failed: \(detail)"
        case .noSpeechDetected:
            return "No speech detected."
        }
    }
}

// MARK: - SpeechService

final class SpeechService {
    static let shared = SpeechService()

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((SpeechError) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private var parakeetEngine: ParakeetEngine?
    private var whisperEngine: WhisperKitEngine?
    private var isActive = false

    private var safetyTimer: Timer?
    private static let safetyTimeout: TimeInterval = 60

    private init() {}

    func preloadModel() {
        switch Settings.shared.sttEngine {
        case .parakeet:
            if parakeetEngine == nil { parakeetEngine = ParakeetEngine() }
            parakeetEngine?.preload()
        case .whisperKit:
            if whisperEngine == nil { whisperEngine = WhisperKitEngine() }
            whisperEngine?.preload(size: Settings.shared.whisperModelSize)
        }
    }

    func startRecording() {
        guard SpeechService.hasMicrophonePermission else {
            SpeechService.requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.startRecording()
                } else {
                    self?.onError?(.microphonePermissionDenied)
                }
            }
            return
        }

        isActive = true

        switch Settings.shared.sttEngine {
        case .parakeet:
            if parakeetEngine == nil { parakeetEngine = ParakeetEngine() }
            parakeetEngine?.onFinalResult = { [weak self] text in self?.onFinalResult?(text) }
            parakeetEngine?.onError = { [weak self] error in self?.onError?(error) }
            parakeetEngine?.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
            parakeetEngine?.startRecording()
        case .whisperKit:
            if whisperEngine == nil { whisperEngine = WhisperKitEngine() }
            whisperEngine?.onFinalResult = { [weak self] text in self?.onFinalResult?(text) }
            whisperEngine?.onError = { [weak self] error in self?.onError?(error) }
            whisperEngine?.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
            whisperEngine?.startRecording()
        }

        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: Self.safetyTimeout, repeats: false) { [weak self] _ in
            self?.stopRecording()
        }
    }

    func disableSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    func stopRecording() {
        safetyTimer?.invalidate()
        safetyTimer = nil

        if isActive {
            switch Settings.shared.sttEngine {
            case .parakeet:
                parakeetEngine?.stopRecording()
            case .whisperKit:
                whisperEngine?.stopRecording()
            }
        }
        isActive = false
    }

    // MARK: - Model Status

    static func isModelReady() -> Bool {
        switch Settings.shared.sttEngine {
        case .parakeet:
            return ParakeetEngine.isModelReady()
        case .whisperKit:
            return WhisperKitEngine.isModelReady(size: Settings.shared.whisperModelSize)
        }
    }

    static func downloadModel(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch Settings.shared.sttEngine {
        case .parakeet:
            ParakeetEngine.downloadModel(progress: progress, completion: completion)
        case .whisperKit:
            WhisperKitEngine.downloadModel(
                size: Settings.shared.whisperModelSize,
                progress: progress,
                completion: completion
            )
        }
    }

    // MARK: - Microphone Permission

    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Audio Devices

    /// Look up the stable UID for an AudioDeviceID. Returns nil if the device
    /// has no UID or no longer exists.
    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uidRef)
        guard status == noErr, let cfUID = uidRef?.takeRetainedValue() else { return nil }
        return cfUID as String
    }

    /// Resolve a stored UID to the current AudioDeviceID. Returns 0 if the
    /// device is not currently connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID {
        guard !uid.isEmpty else { return 0 }
        for device in availableInputDevices() where device.uid == uid {
            return device.id
        }
        return 0
    }

    static func availableInputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, uid: String, name: String)] = []
        for deviceID in deviceIDs {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var streamSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
            guard status == noErr, streamSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
            guard status == noErr, let cfName = nameRef?.takeUnretainedValue() else { continue }

            guard let uid = deviceUID(for: deviceID) else { continue }
            result.append((id: deviceID, uid: uid, name: cfName as String))
        }

        return result
    }
}

