import AVFoundation
import CoreAudio
import Foundation
import WhisperKit

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

    private var whisperEngine: WhisperKitEngine?
    private var parakeetEngine: ParakeetEngine?
    private var activeEngine: STTEngine?

    private var safetyTimer: Timer?
    private static let safetyTimeout: TimeInterval = 60

    private init() {}

    func preloadModel() {
        let settings = Settings.shared
        switch settings.sttEngine {
        case .whisperKit:
            if whisperEngine == nil {
                whisperEngine = WhisperKitEngine()
            }
            whisperEngine?.preload()
        case .parakeet:
            if parakeetEngine == nil {
                parakeetEngine = ParakeetEngine()
            }
            parakeetEngine?.preload()
        }
    }

    func startRecording() {
        let settings = Settings.shared

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

        activeEngine = settings.sttEngine

        switch settings.sttEngine {
        case .whisperKit:
            if whisperEngine == nil {
                whisperEngine = WhisperKitEngine()
            }
            whisperEngine?.onPartialResult = { [weak self] text in self?.onPartialResult?(text) }
            whisperEngine?.onFinalResult = { [weak self] text in self?.onFinalResult?(text) }
            whisperEngine?.onError = { [weak self] error in self?.onError?(error) }
            whisperEngine?.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
            whisperEngine?.startRecording()

        case .parakeet:
            if parakeetEngine == nil {
                parakeetEngine = ParakeetEngine()
            }
            parakeetEngine?.onFinalResult = { [weak self] text in self?.onFinalResult?(text) }
            parakeetEngine?.onError = { [weak self] error in self?.onError?(error) }
            parakeetEngine?.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
            parakeetEngine?.startRecording()
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

        switch activeEngine {
        case .whisperKit:
            whisperEngine?.stopRecording()
        case .parakeet:
            parakeetEngine?.stopRecording()
        case .none:
            break
        }

        activeEngine = nil
    }

    // MARK: - Model Status

    static func isModelReady() -> Bool {
        let settings = Settings.shared
        switch settings.sttEngine {
        case .whisperKit:
            return WhisperKitEngine.isModelReady(settings.whisperModelSize)
        case .parakeet:
            return ParakeetEngine.isModelReady()
        }
    }

    static func downloadModel(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let settings = Settings.shared
        switch settings.sttEngine {
        case .whisperKit:
            WhisperKitEngine.downloadModel(size: settings.whisperModelSize, progress: progress, completion: completion)
        case .parakeet:
            ParakeetEngine.downloadModel(progress: progress, completion: completion)
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

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
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

        var result: [(id: AudioDeviceID, name: String)] = []
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

            result.append((id: deviceID, name: cfName as String))
        }

        return result
    }
}

// MARK: - WhisperKit Engine

final class WhisperKitEngine {
    private var whisperKit: WhisperKit?
    private var isRecording = false
    private var accumulatedText = ""
    private var recordingTask: Task<Void, Never>?
    private var cachedModelSize: WhisperModelSize?
    private let audioCapture = AudioCapture()

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((SpeechError) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    /// HuggingFace Hub cache base for WhisperKit model downloads
    private static var hubCacheBase: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Rewrite/whisper-models", isDirectory: true)
    }

    private static func modelPathKey(for size: WhisperModelSize) -> String {
        "whisperModelPath_\(size.rawValue)"
    }

    static func storedModelPath(for size: WhisperModelSize) -> String? {
        UserDefaults.standard.string(forKey: modelPathKey(for: size))
    }

    func preload() {
        let settings = Settings.shared
        let modelSize = settings.whisperModelSize

        guard cachedModelSize != modelSize else { return }
        guard WhisperKitEngine.isModelReady(modelSize) else { return }

        Task {
            do {
                guard let folder = WhisperKitEngine.storedModelPath(for: modelSize) else { return }
                let config = WhisperKitConfig(
                    modelFolder: folder,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
                let kit = try await WhisperKit(config)
                await MainActor.run {
                    self.whisperKit = kit
                    self.cachedModelSize = modelSize
                }
            } catch {
                // Preload failed -- will retry on startRecording
            }
        }
    }

    func startRecording() {
        let settings = Settings.shared
        let modelSize = settings.whisperModelSize

        accumulatedText = ""
        isRecording = true

        // Start audio capture immediately (engine may already be warm)
        let deviceID: AudioDeviceID? = settings.selectedMicDeviceID != 0
            ? settings.selectedMicDeviceID
            : nil
        audioCapture.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }
        audioCapture.startCapture(deviceID: deviceID)

        // If model isn't loaded yet, load it first
        guard let kit = whisperKit, cachedModelSize == modelSize else {
            guard let folder = WhisperKitEngine.storedModelPath(for: modelSize) else {
                onError?(.modelNotFound)
                return
            }
            recordingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let config = WhisperKitConfig(
                        modelFolder: folder,
                        verbose: false,
                        prewarm: true,
                        load: true,
                        download: false
                    )
                    let kit = try await WhisperKit(config)
                    await MainActor.run {
                        self.whisperKit = kit
                        self.cachedModelSize = modelSize
                        if self.isRecording {
                            self.startTranscriptionLoop(kit: kit)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.onError?(.transcriptionFailed(error.localizedDescription))
                    }
                }
            }
            return
        }

        startTranscriptionLoop(kit: kit)
    }

    private func startTranscriptionLoop(kit: WhisperKit) {
        recordingTask = Task { [weak self] in
            guard let self else { return }

            while self.isRecording && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.isRecording else { break }

                let currentAudio = self.audioCapture.samples
                guard currentAudio.count > 8000 else { continue }

                do {
                    let options = DecodingOptions(language: "en", wordTimestamps: false)
                    let results = try await kit.transcribe(
                        audioArray: currentAudio,
                        decodeOptions: options
                    )
                    let text = results.compactMap { $0.text }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !text.isEmpty {
                        await MainActor.run {
                            self.accumulatedText = text
                            self.onPartialResult?(text)
                        }
                    }
                } catch {
                    // Ignore cancellation errors during periodic transcription
                }
            }
        }
    }

    func stopRecording() {
        isRecording = false
        audioCapture.stopCapture()

        let finalAudio = audioCapture.drainSamples()

        recordingTask?.cancel()
        recordingTask = nil

        let kit = whisperKit

        // Do a final transcription on the complete audio
        guard let kit = kit, finalAudio.count > 4000 else {
            let text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                onError?(.noSpeechDetected)
            } else {
                onFinalResult?(text)
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let options = DecodingOptions(language: "en", wordTimestamps: false)
                let results = try await kit.transcribe(
                    audioArray: finalAudio,
                    decodeOptions: options
                )
                let text = results.compactMap { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                await MainActor.run {
                    if text.isEmpty {
                        self.onError?(.noSpeechDetected)
                    } else {
                        self.onFinalResult?(text)
                    }
                }
            } catch {
                await MainActor.run {
                    let existing = self.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if existing.isEmpty {
                        self.onError?(.noSpeechDetected)
                    } else {
                        self.onFinalResult?(existing)
                    }
                }
            }
        }
    }

    // MARK: - Model Management

    static func isModelReady(_ size: WhisperModelSize) -> Bool {
        guard let path = storedModelPath(for: size) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return contents.contains(where: { $0.hasSuffix(".mlmodelc") })
    }

    static func downloadModel(
        size: WhisperModelSize,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                await MainActor.run { progress(0.01) }

                // WhisperKit.download() handles HuggingFace download.
                // downloadBase is the hub cache root; it creates its own directory structure.
                let modelFolder = try await WhisperKit.download(
                    variant: size.whisperKitModelName,
                    downloadBase: hubCacheBase,
                    progressCallback: { downloadProgress in
                        let fraction = min(downloadProgress.fractionCompleted, 1.0)
                        DispatchQueue.main.async { progress(fraction) }
                    }
                )

                // Store the actual path for later use
                let path = modelFolder.path
                UserDefaults.standard.set(path, forKey: modelPathKey(for: size))

                await MainActor.run {
                    progress(1.0)
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
}
