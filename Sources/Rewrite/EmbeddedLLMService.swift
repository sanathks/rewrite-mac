import Foundation
import LocalLLMClient
import LocalLLMClientLlama

/// Status of the currently-selected embedded model on disk and in memory.
enum EmbeddedModelStatus: Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    case downloaded
    case loading
    case ready
    case error(String)
}

/// On-device Gemma 4 inference via llama.cpp (Metal). Manages download of the
/// GGUF file for the currently-selected `EmbeddedLLMModel` and lazy-loads it
/// into a `LlamaClient` on first generation.
///
/// Model weights are downloaded only when this service's `downloadSelectedModel`
/// is invoked explicitly from Settings — never on app launch.
///
/// We piggyback on `LLMSession.DownloadModel.llama(...)` to manage the
/// HuggingFace download (its `isDownloaded` / `downloadModel(onProgress:)` /
/// `modelPath` surface is the public way to drive `FileDownloader` without
/// importing the non-product `LocalLLMClientUtility` module).
actor EmbeddedLLMService {
    static let shared = EmbeddedLLMService()

    private var client: LlamaClient?
    /// Key uniquely identifying the model currently loaded into `client`.
    private var loadedKey: String?
    private(set) var status: EmbeddedModelStatus = .notDownloaded

    /// Observer callbacks; always invoked on the main actor.
    private var statusObservers: [@MainActor (EmbeddedModelStatus) -> Void] = []

    private init() {
        Task { await self.refreshStatus() }
    }

    // MARK: - Helpers

    private func makeDownloadModel(for model: EmbeddedLLMModel) -> LLMSession.DownloadModel {
        // The factory builds a DownloadModel whose `downloader` targets the HF
        // repo + filename. We only ever invoke its download / status APIs; the
        // associated `makeClient` is never called because we instantiate the
        // LlamaClient ourselves via `LocalLLMClient.llama(url:)`.
        LLMSession.DownloadModel.llama(
            id: model.huggingFaceRepo,
            model: model.ggufFilename
        )
    }

    private func key(for model: EmbeddedLLMModel) -> String {
        "\(model.huggingFaceRepo)#\(model.ggufFilename)"
    }

    // MARK: - Status

    func refreshStatus() async {
        let selected = await MainActor.run { Settings.shared.embeddedModel }
        let k = key(for: selected)
        let isDownloaded = makeDownloadModel(for: selected).isDownloaded

        if loadedKey == k && client != nil {
            setStatus(.ready)
        } else if isDownloaded {
            setStatus(.downloaded)
        } else {
            setStatus(.notDownloaded)
        }
    }

    /// Subscribe to status changes. Block is invoked on the main actor.
    func observe(_ block: @escaping @MainActor (EmbeddedModelStatus) -> Void) {
        statusObservers.append(block)
        let snapshot = status
        Task { @MainActor in block(snapshot) }
    }

    private func setStatus(_ newStatus: EmbeddedModelStatus) {
        status = newStatus
        let snapshot = newStatus
        let observers = statusObservers
        Task { @MainActor in
            for observer in observers { observer(snapshot) }
        }
    }

    // MARK: - Download

    /// Download the currently-selected embedded model. No-op if already cached.
    func downloadSelectedModel() async {
        let selected = await MainActor.run { Settings.shared.embeddedModel }
        let dm = makeDownloadModel(for: selected)

        if dm.isDownloaded {
            await refreshStatus()
            return
        }

        setStatus(.downloading(fraction: 0))
        do {
            try await dm.downloadModel { [weak self] fraction in
                await self?.setStatus(.downloading(fraction: fraction))
            }
            await refreshStatus()
        } catch {
            setStatus(.error(error.localizedDescription))
        }
    }

    // MARK: - Generation

    /// Generate a response with the embedded model (non-streaming).
    /// Internally just consumes the streaming API to completion.
    func generate(
        prompt: String,
        systemPrompt: String? = nil
    ) async throws -> String {
        var output = ""
        for try await chunk in try await stream(prompt: prompt, systemPrompt: systemPrompt) {
            output += chunk
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stream a response token-by-token. Cancelling the consuming task stops
    /// generation (llama.cpp's generator honors `Task.isCancelled`).
    func stream(
        prompt: String,
        systemPrompt: String? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await ensureLoaded()
        guard let client else {
            throw LLMError.connectionFailed("Embedded model not loaded.")
        }

        var messages: [LLMInput.Message] = []
        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(prompt))

        // `textStream` returns a `Generator` (AsyncSequence) — wrap it as an
        // AsyncThrowingStream so call sites work with a standard type.
        let generator = try client.textStream(from: .chat(messages))
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in generator {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Load the model matching the current Settings selection. Never downloads
    /// here — download is a separate, user-initiated action.
    private func ensureLoaded() async throws {
        let selected = await MainActor.run { Settings.shared.embeddedModel }
        let k = key(for: selected)

        if loadedKey == k, client != nil {
            return
        }

        let dm = makeDownloadModel(for: selected)
        guard dm.isDownloaded else {
            throw LLMError.connectionFailed(
                "Gemma 4 model is not downloaded. Open Settings → Provider to download it."
            )
        }

        setStatus(.loading)
        let modelURL = dm.modelPath.appending(component: selected.ggufFilename)
        do {
            let parameter = LlamaClient.Parameter(
                context: 4096,
                temperature: 0.3,
                topK: 40,
                topP: 0.95
            )
            client = try await LocalLLMClient.llama(url: modelURL, parameter: parameter)
            loadedKey = k
            setStatus(.ready)
        } catch {
            client = nil
            loadedKey = nil
            setStatus(.error(error.localizedDescription))
            throw error
        }
    }
}
