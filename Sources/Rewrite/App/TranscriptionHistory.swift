import Foundation

struct TranscriptionEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let text: String
}

final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    private let maxEntries = 20
    private let defaultsKey = "transcriptionHistory"

    private(set) var entries: [TranscriptionEntry] = []

    private init() {
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(TranscriptionEntry(id: UUID(), timestamp: Date(), text: trimmed), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
