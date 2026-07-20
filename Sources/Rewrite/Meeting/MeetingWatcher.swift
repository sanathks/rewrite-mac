import AppKit
import Foundation
import UserNotifications

/// Polls for a meeting starting (a running conferencing app or a live calendar
/// event) and, on a fresh detection, posts a notification offering to start
/// recording. It never starts recording on its own - the user must confirm.
@MainActor
final class MeetingWatcher: NSObject {
    static let shared = MeetingWatcher()

    static let categoryID = "meeting-detected"
    static let startActionID = "meeting-start-recording"
    static let ignoreActionID = "meeting-ignore"

    private var timer: Timer?
    private let interval: TimeInterval = 25

    /// Signatures we have already prompted for (or that are actively being
    /// recorded), so we do not nag repeatedly about the same meeting.
    private var handledSignatures: Set<String> = []
    /// The signature seen on the previous tick, to detect the no-meeting ->
    /// meeting transition rather than firing every tick.
    private var lastSignature: String?

    private override init() { super.init() }

    // MARK: - Control

    func start() {
        guard timer == nil else { return }
        requestAuthorization()
        registerCategory()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Run one check shortly after enabling.
        Task { @MainActor in self.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSignature = nil
        handledSignatures.removeAll()
    }

    func syncWithSettings() {
        if Settings.shared.meetingAutoDetectEnabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Detection

    private func tick() {
        // Never prompt while already recording or busy processing.
        if MeetingTranscriber.shared.state != .idle {
            lastSignature = currentSignature()
            return
        }

        guard let signature = currentSignature() else {
            lastSignature = nil
            return
        }

        // Only act on a transition into a meeting (or a genuinely new meeting),
        // and only once per meeting.
        let isNewMeeting = signature != lastSignature
        lastSignature = signature
        guard isNewMeeting, !handledSignatures.contains(signature) else { return }

        handledSignatures.insert(signature)
        notifyMeetingDetected()
    }

    /// A stable string identifying the current meeting, or nil if none.
    private func currentSignature() -> String? {
        if let event = MeetingDetector.currentEvent(), let id = event.eventIdentifier {
            return "cal:\(id)"
        }
        if let app = MeetingDetector.activeConferencingApp() {
            return "app:\(app)"
        }
        return nil
    }

    // MARK: - Notification

    private func notifyMeetingDetected() {
        let suggestion = MeetingDetector.suggestedTitle()
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "Start recording \u{201C}\(suggestion.title)\u{201D}?"
        content.categoryIdentifier = Self.categoryID
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func registerCategory() {
        let start = UNNotificationAction(
            identifier: Self.startActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreActionID,
            title: "Ignore",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [start, ignore],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
