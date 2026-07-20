import CoreAudio
import Foundation
import SpeakerKit
import WhisperKit

/// Records a meeting to a single audio buffer, then on stop runs WhisperKit
/// (word-level timestamps) + SpeakerKit diarization and merges them into
/// speaker-attributed turns. Batch-after-stop: no chunking, no cross-chunk
/// speaker re-identification. Simple and correct for meetings up to ~1 hour.
@MainActor
final class MeetingTranscriber: ObservableObject {
    /// Shared instance so auto-detection (and any window) drives the same
    /// recording state. The Meetings tab observes this rather than owning it.
    static let shared = MeetingTranscriber()

    enum State: Equatable {
        case idle
        case recording
        case processing(String) // stage label
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var audioLevel: Float = 0
    /// Set when system-audio capture was requested but could not start, so the
    /// UI can note that the recording is mic-only.
    @Published var systemAudioNote: String?

    private let audioCapture = AudioCapture()
    private var systemCapture: (any SystemAudioCapturing)?
    private var capturingSystemAudio = false
    private var startDate: Date?
    private var timer: Timer?
    private var suggestedTitle: String = "Meeting"
    private var calendarEventId: String?

    var isRecording: Bool { if case .recording = state { return true } else { return false } }

    // MARK: - Lifecycle

    func start() {
        guard case .idle = state else { return }
        guard SpeechService.hasMicrophonePermission else {
            SpeechService.requestMicrophonePermission { [weak self] granted in
                if granted { self?.start() }
                else { self?.state = .error("Microphone permission denied.") }
            }
            return
        }

        let suggestion = MeetingDetector.suggestedTitle()
        suggestedTitle = suggestion.title
        calendarEventId = suggestion.eventId

        let resolved = SpeechService.deviceID(forUID: Settings.shared.selectedMicUID)
        let deviceID: AudioDeviceID? = resolved != 0 ? resolved : nil
        audioCapture.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        audioCapture.startCapture(deviceID: deviceID)

        // System audio (remote side of a call) is best-effort via Core Audio
        // process taps: no Screen Recording permission, no purple indicator. If
        // the audio-capture permission is missing or the tap fails, we keep the
        // mic-only recording going rather than aborting.
        capturingSystemAudio = false
        systemAudioNote = nil
        if Settings.shared.meetingCaptureSystemAudio, #available(macOS 14.2, *) {
            let capture = CoreAudioTapCapture()
            systemCapture = capture
            Task { [weak self] in
                do {
                    try await capture.start()
                    await MainActor.run { self?.capturingSystemAudio = true }
                } catch {
                    await MainActor.run {
                        self?.capturingSystemAudio = false
                        self?.systemCapture = nil
                        self?.systemAudioNote = "System audio off (mic only): \(error.localizedDescription)"
                    }
                }
            }
        }

        startDate = Date()
        elapsed = 0
        state = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Stops recording and kicks off transcription. `completion` fires with the
    /// finished session (already saved to the store) or nil on failure.
    func stop(completion: @escaping (MeetingSession?) -> Void) {
        guard case .recording = state else { completion(nil); return }
        timer?.invalidate()
        timer = nil
        audioLevel = 0

        audioCapture.stopCapture()
        let micAudio = audioCapture.drainSamples()
        let wasCapturingSystem = capturingSystemAudio
        let started = startDate ?? Date()
        let title = suggestedTitle
        let eventId = calendarEventId

        let capture = systemCapture
        systemCapture = nil

        guard micAudio.count > 16_000 else {
            state = .error("Recording too short.")
            capturingSystemAudio = false
            Task { await capture?.stop() }
            completion(nil)
            return
        }

        state = .processing("Transcribing...")
        capturingSystemAudio = false

        Task {
            var audio = micAudio
            if wasCapturingSystem, let capture {
                await capture.stop()
                let systemAudio = capture.drainSamples()
                audio = Self.mix(micAudio, systemAudio)
            }

            do {
                let session = try await Self.process(
                    audio: audio,
                    startedAt: started,
                    title: title,
                    calendarEventId: eventId,
                    onStage: { [weak self] stage in
                        Task { @MainActor in self?.state = .processing(stage) }
                    }
                )
                await MainActor.run {
                    MeetingStore.shared.save(session)
                    self.state = .idle
                    self.startDate = nil
                    completion(session)
                }
                // Best-effort LLM title if calendar gave us nothing useful.
                await Self.maybeGenerateTitle(for: session)
            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                    self.startDate = nil
                    completion(nil)
                }
            }
        }
    }

    func reset() { state = .idle }

    // MARK: - Processing pipeline (off main actor)

    private static func process(
        audio: [Float],
        startedAt: Date,
        title: String,
        calendarEventId: String?,
        onStage: @escaping (String) -> Void
    ) async throws -> MeetingSession {
        onStage("Transcribing...")
        let kit = try await MeetingModels.whisperKit()
        let options = DecodingOptions(
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)

        onStage("Identifying speakers...")
        let speakerKit = try await MeetingModels.speakerKit()
        let diarization = try await speakerKit.diarize(audioArray: audio)

        onStage("Merging...")
        let turns = buildTurns(from: diarization, transcription: results)

        return MeetingSession(
            id: UUID(),
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(audio.count) / 16_000),
            turns: turns,
            speakerNames: [:],
            calendarEventId: calendarEventId
        )
    }

    /// Sum two 16 kHz mono streams that started at the same moment. Overlapping
    /// samples are added (soft-clamped to avoid clipping); the tail of the
    /// longer stream is appended as-is. Both come from independent clocks so
    /// there is minor drift over a long meeting, which is fine for transcription.
    private static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        guard !b.isEmpty else { return a }
        guard !a.isEmpty else { return b }
        let n = Swift.max(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            let sum = av + bv
            out[i] = sum > 1 ? 1 : (sum < -1 ? -1 : sum)
        }
        return out
    }

    /// Align diarization segments to word-timed transcription and collapse
    /// consecutive same-speaker segments into readable turns.
    private static func buildTurns(
        from diarization: DiarizationResult,
        transcription: [TranscriptionResult]
    ) -> [SpeakerTurn] {
        let grouped = diarization.addSpeakerInfo(to: transcription, strategy: .subsegment)
        let flat = grouped.flatMap { $0 }.sorted { $0.startTime < $1.startTime }

        var turns: [SpeakerTurn] = []
        for seg in flat {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let speaker = seg.speaker.speakerId ?? -1
            if var last = turns.last, last.speakerId == speaker {
                last = SpeakerTurn(
                    id: last.id,
                    speakerId: speaker,
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    text: last.text + " " + text
                )
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(
                    id: UUID(),
                    speakerId: speaker,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: text
                ))
            }
        }
        return turns
    }

    /// If the meeting title is a fallback (no calendar match), ask the LLM to
    /// name it from the transcript. Silent no-op if the LLM is unavailable.
    private static func maybeGenerateTitle(for session: MeetingSession) async {
        guard session.calendarEventId == nil, !session.turns.isEmpty else { return }
        let transcript = session.turns.prefix(20)
            .map { "\($0.text)" }
            .joined(separator: " ")
            .prefix(1500)
        let prompt = """
        Give a short, specific title (3 to 6 words) for this meeting based on the transcript below. Return only the title, no quotes or punctuation at the end.

        Transcript:
        \(transcript)
        """
        let title: String? = await withCheckedContinuation { continuation in
            LLMService.shared.generate(prompt: prompt) { result in
                switch result {
                case .success(let text): continuation.resume(returning: text)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
        guard let title else { return } // LLM unavailable - keep the fallback title.
        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        guard !cleaned.isEmpty, cleaned.count < 80 else { return }
        await MainActor.run {
            MeetingStore.shared.renameMeeting(session.id, to: cleaned)
        }
    }
}
