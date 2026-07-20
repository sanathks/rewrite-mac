import Foundation
import SpeakerKit
import WhisperKit

/// Lazily loads and caches the WhisperKit + SpeakerKit model instances shared
/// across meeting transcriptions. Both are expensive to load, so we keep one
/// of each alive for the process lifetime.
enum MeetingModels {
    private static var whisper: WhisperKit?
    private static var speaker: SpeakerKit?
    private static let lock = NSLock()

    /// Cache directory for SpeakerKit's pyannote CoreML models.
    static var speakerModelBaseDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Rewrite/speaker-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - WhisperKit

    /// Loads WhisperKit at the configured model size. Downloads it if missing
    /// (reusing the dictation model cache and UserDefaults path).
    static func whisperKit() async throws -> WhisperKit {
        if let kit = cachedWhisper() { return kit }

        let size = Settings.shared.whisperModelSize
        let folderKey = "whisperModelFolder_\(size.rawValue)"

        let modelFolder: String
        if let path = UserDefaults.standard.string(forKey: folderKey),
           FileManager.default.fileExists(atPath: path) {
            modelFolder = path
        } else {
            let url = try await WhisperKit.download(
                variant: size.whisperKitModelName,
                downloadBase: WhisperKitEngine.modelBaseDirectory
            )
            UserDefaults.standard.set(url.path, forKey: folderKey)
            modelFolder = url.path
        }

        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        ))
        setWhisper(kit)
        return kit
    }

    // MARK: - SpeakerKit

    static func speakerKit() async throws -> SpeakerKit {
        if let kit = cachedSpeaker() { return kit }

        let config = PyannoteConfig(
            downloadBase: speakerModelBaseDirectory.path,
            download: true,
            load: true,
            verbose: false
        )
        let kit = try await SpeakerKit(config)
        setSpeaker(kit)
        return kit
    }

    static var isSpeakerModelReady: Bool {
        // pyannote-v3 CoreML models land under the download base once fetched.
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: speakerModelBaseDirectory.path
        )) ?? []
        return !contents.isEmpty
    }

    // MARK: - Thread-safe accessors

    private static func cachedWhisper() -> WhisperKit? {
        lock.lock(); defer { lock.unlock() }; return whisper
    }
    private static func setWhisper(_ kit: WhisperKit) {
        lock.lock(); whisper = kit; lock.unlock()
    }
    private static func cachedSpeaker() -> SpeakerKit? {
        lock.lock(); defer { lock.unlock() }; return speaker
    }
    private static func setSpeaker(_ kit: SpeakerKit) {
        lock.lock(); speaker = kit; lock.unlock()
    }
}
