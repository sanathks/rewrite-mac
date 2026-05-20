import Combine
import CoreAudio
import Foundation
import SherpaOnnxSwift

final class ParakeetEngine {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    /// Hotwords list the cached recognizer was built with. If it diverges
    /// from `Settings.shared.voiceHotwords` we discard the cached recognizer
    /// and build a new one — the hotwords file path is baked into the
    /// recognizer at creation time.
    private var recognizerHotwordsKey: String = ""
    private var hotwordsObserver: AnyCancellable?
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
        observeHotwordsIfNeeded()

        let currentKey = Settings.shared.voiceHotwords
        if recognizer != nil && recognizerHotwordsKey == currentKey { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rec = ParakeetEngine.createRecognizer(hotwords: currentKey)
            DispatchQueue.main.async {
                self?.recognizer = rec
                self?.recognizerHotwordsKey = currentKey
            }
        }
    }

    /// Wire up a one-shot observer that drops the cached recognizer when
    /// the user edits the hotwords list. The next `preload()` /
    /// `startRecording()` rebuilds it. Cheap — recognizer creation is a
    /// few hundred ms and only pays the cost when the list actually changes.
    private func observeHotwordsIfNeeded() {
        guard hotwordsObserver == nil else { return }
        hotwordsObserver = Settings.shared.$voiceHotwords
            .dropFirst()
            .sink { [weak self] _ in
                self?.recognizer = nil
                self?.recognizerHotwordsKey = ""
            }
    }

    func startRecording() {
        isRecording = true
        observeHotwordsIfNeeded()

        let settings = Settings.shared
        let resolved = SpeechService.deviceID(forUID: settings.selectedMicUID)
        let deviceID: AudioDeviceID? = resolved != 0 ? resolved : nil
        audioCapture.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }
        audioCapture.startCapture(deviceID: deviceID)

        let currentKey = settings.voiceHotwords
        let needsBuild = (recognizer == nil || recognizerHotwordsKey != currentKey)
            && ParakeetEngine.isModelReady()
        if needsBuild {
            Task.detached { [weak self] in
                let capturedSelf = self
                let rec = ParakeetEngine.createRecognizer(hotwords: currentKey)
                await MainActor.run {
                    capturedSelf?.recognizer = rec
                    capturedSelf?.recognizerHotwordsKey = currentKey
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

    private static func createRecognizer(hotwords: String) -> SherpaOnnxOfflineRecognizer? {
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

        // Hotwords require modified_beam_search; greedy_search ignores them.
        // The existing >1-second audio guard in `stopRecording` keeps the
        // hallucinate-on-silence risk in check.
        let hotwordsPath = writeHotwordsFile(hotwords) ?? ""
        let useHotwords = !hotwordsPath.isEmpty
        let decodingMethod = useHotwords ? "modified_beam_search" : "greedy_search"

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: decodingMethod,
            hotwordsFile: hotwordsPath,
            hotwordsScore: 2.0
        )

        return SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// Serialise the user's hotwords list to a file sherpa-onnx can read.
    /// Returns the file path, or `nil` when there's nothing to write —
    /// caller falls back to greedy_search without hotwords.
    private static func writeHotwordsFile(_ hotwords: String) -> String? {
        let words = hotwords
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        let dir = caches.appendingPathComponent("Rewrite", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("parakeet-hotwords.txt")
        do {
            try words.joined(separator: "\n").write(
                to: url, atomically: true, encoding: .utf8
            )
            return url.path
        } catch {
            return nil
        }
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
