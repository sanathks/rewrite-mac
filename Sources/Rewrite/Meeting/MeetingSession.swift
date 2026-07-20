import Foundation

struct SpeakerTurn: Identifiable, Codable, Sendable {
    let id: UUID
    let speakerId: Int   // -1 for no match
    let startTime: Float // seconds from recording start
    let endTime: Float
    let text: String
}

struct MeetingSession: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var turns: [SpeakerTurn]
    var speakerNames: [String: String] // "0" -> "Alice", "1" -> "Bob"
    var calendarEventId: String?

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    func speakerName(for id: Int) -> String {
        speakerNames["\(id)"] ?? "Speaker \(id + 1)"
    }
}
