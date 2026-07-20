import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var transcriber = MeetingTranscriber.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            systemAudioRow

            if store.meetings.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    meetingList
                        .frame(width: 200)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selection == nil { selection = store.meetings.first?.id }
        }
    }

    @ViewBuilder
    private var systemAudioRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(isOn: $settings.meetingCaptureSystemAudio) {
                    Text("Capture system audio (both sides of a call)")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            if settings.meetingCaptureSystemAudio {
                Text("Uses an audio-only capture - no screen recording, no purple indicator. macOS asks for audio-recording permission on first record.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let note = transcriber.systemAudioNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            HStack(spacing: 10) {
                Toggle(isOn: $settings.meetingAutoDetectEnabled) {
                    Text("Auto-detect meetings and offer to record")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            if settings.meetingAutoDetectEnabled {
                Text("Watches for a running call app or a live calendar event and sends a notification asking to record. Never records without your confirmation.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Header / record control

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meetings")
                    .font(.title2).fontWeight(.bold)
                Text("Record, transcribe, and identify speakers on-device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            recordControl
        }
    }

    @ViewBuilder
    private var recordControl: some View {
        switch transcriber.state {
        case .idle:
            Button {
                transcriber.start()
            } label: {
                Label("Record Meeting", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
        case .recording:
            HStack(spacing: 10) {
                RecordingDot()
                Text(timeString(transcriber.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                Button {
                    transcriber.stop { session in
                        if let session { selection = session.id }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        case .processing(let stage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage).font(.caption).foregroundColor(.secondary)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message).font(.caption).foregroundColor(.secondary)
                Button("Dismiss") { transcriber.reset() }
                    .controlSize(.small)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("No meetings yet")
                .font(.headline)
            Text("Press Record Meeting to capture your first one.\nSpeaker labels and titles are added automatically.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var meetingList: some View {
        List(selection: $selection) {
            ForEach(store.meetings) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.subheadline).fontWeight(.medium)
                        .lineLimit(1)
                    Text(dateString(meeting.startedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
                .tag(meeting.id)
                .contextMenu {
                    Button(role: .destructive) {
                        store.delete(meeting.id)
                        if selection == meeting.id { selection = store.meetings.first?.id }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let meeting = store.meetings.first(where: { $0.id == id }) {
            MeetingDetailView(meeting: meeting)
        } else {
            Text("Select a meeting")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Formatting

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - Detail View

private struct MeetingDetailView: View {
    let meeting: MeetingSession
    @ObservedObject private var store = MeetingStore.shared
    @State private var editingSpeaker: Int?
    @State private var draftName: String = ""

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown
    ]

    private func color(for speakerId: Int) -> Color {
        guard speakerId >= 0 else { return .secondary }
        return Self.speakerColors[speakerId % Self.speakerColors.count]
    }

    private var current: MeetingSession {
        store.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(current.title)
                    .font(.title3).fontWeight(.semibold)
                HStack(spacing: 8) {
                    Text(dateString(current.startedAt))
                    if let duration = current.duration {
                        Text("-")
                        Text(durationString(duration))
                    }
                    Text("-")
                    Text("\(distinctSpeakers.count) speaker\(distinctSpeakers.count == 1 ? "" : "s")")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if !distinctSpeakers.isEmpty {
                speakerLegend
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(current.turns) { turn in
                        turnRow(turn)
                    }
                }
                .padding(.trailing, 8)
            }
        }
    }

    private var distinctSpeakers: [Int] {
        var seen: [Int] = []
        for turn in current.turns where turn.speakerId >= 0 && !seen.contains(turn.speakerId) {
            seen.append(turn.speakerId)
        }
        return seen.sorted()
    }

    private var speakerLegend: some View {
        HStack(spacing: 12) {
            ForEach(distinctSpeakers, id: \.self) { id in
                HStack(spacing: 5) {
                    Circle().fill(color(for: id)).frame(width: 8, height: 8)
                    if editingSpeaker == id {
                        TextField("Name", text: $draftName, onCommit: {
                            store.renameSpeaker(in: current.id, speakerId: id, to: draftName)
                            editingSpeaker = nil
                        })
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    } else {
                        Text(current.speakerName(for: id))
                            .font(.caption)
                            .onTapGesture {
                                draftName = current.speakerNames["\(id)"] ?? ""
                                editingSpeaker = id
                            }
                    }
                }
            }
            Spacer()
        }
    }

    private func turnRow(_ turn: SpeakerTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color(for: turn.speakerId)).frame(width: 7, height: 7)
                Text(current.speakerName(for: turn.speakerId))
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(color(for: turn.speakerId))
                Text(timestamp(turn.startTime))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(turn.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timestamp(_ t: Float) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - Recording dot

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
