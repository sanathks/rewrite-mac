import CoreAudio
import Foundation
import WhisperKit

final class WhisperKitEngine {
    private var whisperKit: WhisperKit?
    private let audioCapture = AudioCapture()

    var onFinalResult: ((String) -> Void)?
    var onError: ((SpeechError) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    static var modelBaseDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Rewrite/whisper-models", isDirectory: true)
    }

    private static func modelFolderKey(for size: WhisperModelSize) -> String {
        "whisperModelFolder_\(size.rawValue)"
    }

    static func isModelReady(size: WhisperModelSize) -> Bool {
        guard let path = UserDefaults.standard.string(forKey: modelFolderKey(for: size)) else {
            return false
        }
        let url = URL(fileURLWithPath: path)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []
        return contents.contains { $0.pathExtension == "mlmodelc" }
    }

    func preload(size: WhisperModelSize, completion: (() -> Void)? = nil) {
        guard WhisperKitEngine.isModelReady(size: size), whisperKit == nil else {
            completion?()
            return
        }
        guard let path = UserDefaults.standard.string(
            forKey: WhisperKitEngine.modelFolderKey(for: size)
        ) else {
            completion?()
            return
        }

        Task {
            let kit = try? await WhisperKit(WhisperKitConfig(
                modelFolder: path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            ))
            await MainActor.run {
                self.whisperKit = kit
                completion?()
            }
        }
    }

    func startRecording() {
        let settings = Settings.shared
        let resolved = SpeechService.deviceID(forUID: settings.selectedMicUID)
        let deviceID: AudioDeviceID? = resolved != 0 ? resolved : nil
        audioCapture.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }
        audioCapture.startCapture(deviceID: deviceID)

        if whisperKit == nil {
            preload(size: settings.whisperModelSize)
        }
    }

    func stopRecording() {
        audioCapture.stopCapture()
        let finalAudio = audioCapture.drainSamples()

        guard let kit = whisperKit else {
            onError?(.modelNotFound)
            return
        }

        guard finalAudio.count > 16000 else {
            onError?(.noSpeechDetected)
            return
        }

        Task.detached { [weak self] in
            do {
                let results = try await kit.transcribe(audioArray: finalAudio)
                let text = results.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if text.isEmpty {
                        self?.onError?(.noSpeechDetected)
                    } else {
                        self?.onFinalResult?(text)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.onError?(.transcriptionFailed(error.localizedDescription))
                }
            }
        }
    }

    static func downloadModel(
        size: WhisperModelSize,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                let folder = try await WhisperKit.download(
                    variant: size.whisperKitModelName,
                    downloadBase: modelBaseDirectory,
                    progressCallback: { prog in
                        DispatchQueue.main.async { progress(prog.fractionCompleted) }
                    }
                )
                UserDefaults.standard.set(folder.path, forKey: modelFolderKey(for: size))
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
