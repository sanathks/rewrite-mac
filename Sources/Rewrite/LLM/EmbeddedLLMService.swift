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

    /// Long-running task that pings the model every ~2 min while loaded.
    /// macOS can page mmap'd weight bytes back to disk under memory pressure
    /// even though our LlamaClient is alive; a tiny dummy decode touches
    /// the pages and keeps them in the OS page cache.
    private var keepAliveTask: Task<Void, Never>?
    private static let keepAliveInterval: UInt64 = 120 * 1_000_000_000  // 120 s

    /// Wall-clock time of the most recent real `generate(...)` call. The
    /// keep-alive task auto-unloads the model when this gets too old, so a
    /// laptop left idle for hours doesn't permanently hold 5 GB of weights.
    /// Keep-alive pings deliberately don't count as "use" — only real
    /// rewrites bump this.
    private var lastUseTime: Date = .now
    private static let idleUnloadInterval: TimeInterval = 30 * 60  // 30 min

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
            // User just opted into this model — prewarm so the first real
            // rewrite doesn't pay another ~10 s of cold-start cost.
            let keepLoaded = await MainActor.run { Settings.shared.keepModelLoaded }
            if keepLoaded {
                await prewarm()
            }
        } catch {
            setStatus(.error(error.localizedDescription))
        }
    }

    // MARK: - Prewarm / unload

    /// Load the model and run a tiny dummy decode so the first real
    /// generation doesn't pay the cold-start cost (GGUF mmap, KV cache
    /// allocation, Metal kernel compilation). Safe to call multiple times —
    /// no-op once the model is already warm. Errors are swallowed; the user
    /// will see a real error on the next actual generate if something is off.
    func prewarm() async {
        do {
            try await ensureLoaded()
            try await runDummyDecode()
        } catch {
            // Prewarm failures are non-fatal — leave the model unloaded
            // and let the next real call surface the error properly.
        }
        startKeepAlive()
    }

    /// One-token decode that warms Metal shaders and KV cache and (when
    /// re-run periodically) keeps the mmap'd weights resident in the OS
    /// page cache. Cancels itself after the first chunk so we never emit
    /// a real response.
    private func runDummyDecode() async throws {
        guard let client else { return }
        let stream = try client.textStream(from: .chat([.user("hi")]))
        for try await _ in stream {
            break
        }
    }

    /// Drop the cached `LlamaClient` so the OS can reclaim the ~5 GB of
    /// model weights. Next generation will pay the cold-start cost again.
    func unload() {
        stopKeepAlive()
        client = nil
        loadedKey = nil
        Task { await refreshStatus() }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        lastUseTime = .now
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepAliveInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                // Honour the user's preference at each tick: if they
                // turned the toggle off in the meantime, stop pinging.
                let keep = await MainActor.run { Settings.shared.keepModelLoaded }
                if !keep { return }
                // Idle auto-unload. If no real rewrite has happened in a
                // long time, drop the model so the OS can reclaim the
                // ~5 GB. Next rewrite pays the cold-start cost again.
                if await self.idleTooLong() {
                    await self.unload()
                    return
                }
                // Skip the ping while Low Power Mode is on. The user has
                // explicitly asked the system to do less work; keeping a
                // 5 GB model's pages hot is exactly the wrong thing.
                if ProcessInfo.processInfo.isLowPowerModeEnabled { continue }
                try? await self.runDummyDecode()
            }
        }
    }

    private func idleTooLong() -> Bool {
        Date.now.timeIntervalSince(lastUseTime) > Self.idleUnloadInterval
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
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
        // Mark real use so the idle-unload timer is held off.
        lastUseTime = .now

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
