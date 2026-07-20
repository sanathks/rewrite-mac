import Foundation
import Combine

final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [MeetingSession] = []

    private let storeURL: URL = {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Rewrite/meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meetings.json")
    }()

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([MeetingSession].self, from: data) else { return }
        meetings = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ session: MeetingSession) {
        if let idx = meetings.firstIndex(where: { $0.id == session.id }) {
            meetings[idx] = session
        } else {
            meetings.insert(session, at: 0)
        }
        persist()
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        persist()
    }

    func renameSpeaker(in sessionId: UUID, speakerId: Int, to name: String) {
        guard let idx = meetings.firstIndex(where: { $0.id == sessionId }) else { return }
        var session = meetings[idx]
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.speakerNames.removeValue(forKey: "\(speakerId)")
        } else {
            session.speakerNames["\(speakerId)"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        meetings[idx] = session
        persist()
    }

    func renameMeeting(_ id: UUID, to title: String) {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meetings[idx].title = trimmed
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
