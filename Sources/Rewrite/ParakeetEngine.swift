import CoreAudio
import Foundation
import SherpaOnnxSwift

final class ParakeetEngine {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var isRecording = false
    private let audioCapture = AudioCapture()

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((SpeechError) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private static let modelFiles = [
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt",
    ]

    private static let downloadURLBase =
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main"

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent(
            "Rewrite/models/parakeet-tdt-0.6b-v3-int8", isDirectory: true
        )
    }

    static func isModelReady() -> Bool {
        let dir = modelDirectory
        return modelFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path)
        }
    }

    func preload() {
        guard ParakeetEngine.isModelReady() else { return }
        guard recognizer == nil else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rec = ParakeetEngine.createRecognizer()
            DispatchQueue.main.async {
                self?.recognizer = rec
            }
        }
    }

    func startRecording() {
        isRecording = true

        let settings = Settings.shared
        let deviceID: AudioDeviceID? = settings.selectedMicDeviceID != 0
            ? settings.selectedMicDeviceID
            : nil
        audioCapture.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }
        audioCapture.startCapture(deviceID: deviceID)

        // Pre-load recognizer if needed
        if recognizer == nil && ParakeetEngine.isModelReady() {
            Task.detached { [weak self] in
                let capturedSelf = self
                let rec = ParakeetEngine.createRecognizer()
                await MainActor.run {
                    capturedSelf?.recognizer = rec
                }
            }
        }
    }

    func stopRecording() {
        isRecording = false
        audioCapture.stopCapture()

        let finalAudio = audioCapture.drainSamples()

        guard let recognizer = recognizer else {
            onError?(.modelNotFound)
            return
        }

        guard finalAudio.count > 16000 else {
            onError?(.noSpeechDetected)
            return
        }

        // Check audio energy to avoid decoding silence/noise
        // (modified_beam_search with hotwords can hallucinate from silence)
        // Decode on background thread
        Task.detached { [weak self] in
            let capturedSelf = self
            let result = recognizer.decode(samples: finalAudio, sampleRate: 16000)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                if text.isEmpty {
                    capturedSelf?.onError?(.noSpeechDetected)
                } else {
                    capturedSelf?.onFinalResult?(text)
                }
            }
        }
    }

    // MARK: - Model Creation

    private static func createRecognizer() -> SherpaOnnxOfflineRecognizer? {
        let dir = modelDirectory.path

        let transducerConfig = sherpaOnnxOfflineTransducerModelConfig(
            encoder: "\(dir)/encoder.int8.onnx",
            decoder: "\(dir)/decoder.int8.onnx",
            joiner: "\(dir)/joiner.int8.onnx"
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: "\(dir)/tokens.txt",
            transducer: transducerConfig,
            numThreads: 4,
            modelType: "nemo_transducer"
        )

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )

        return SherpaOnnxOfflineRecognizer(config: &config)
    }

    // MARK: - Model Download

    static func downloadModel(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let destDir = modelDirectory

        do {
            try FileManager.default.createDirectory(
                at: destDir, withIntermediateDirectories: true
            )
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        let files = modelFiles
        let totalFiles = Double(files.count)
        var completedFiles = 0
        var downloadError: Error?
        let lock = NSLock()

        for file in files {
            guard let url = URL(string: "\(downloadURLBase)/\(file)") else {
                DispatchQueue.main.async { completion(.failure(SpeechError.modelNotFound)) }
                return
            }

            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                lock.lock()
                defer { lock.unlock() }

                if downloadError != nil { return }

                if let error = error {
                    downloadError = error
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 200 {
                    downloadError = SpeechError.modelNotFound
                    DispatchQueue.main.async { completion(.failure(SpeechError.modelNotFound)) }
                    return
                }

                guard let tempURL = tempURL else {
                    downloadError = SpeechError.modelNotFound
                    DispatchQueue.main.async { completion(.failure(SpeechError.modelNotFound)) }
                    return
                }

                let destFile = destDir.appendingPathComponent(file)
                do {
                    if FileManager.default.fileExists(atPath: destFile.path) {
                        try FileManager.default.removeItem(at: destFile)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destFile)
                } catch {
                    downloadError = error
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }

                completedFiles += 1
                let overallProgress = Double(completedFiles) / totalFiles
                DispatchQueue.main.async { progress(overallProgress) }

                if completedFiles == files.count {
                    DispatchQueue.main.async { completion(.success(())) }
                }
            }

            task.resume()
        }
    }
}
