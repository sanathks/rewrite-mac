import AppKit
import EventKit
import Foundation

/// Best-effort meeting context detection. Two independent signals:
///   1. A running conferencing app (Zoom / Teams / Meet-in-browser / Webex).
///   2. A calendar event happening right now (via EventKit, which reads the
///      system Calendar that Google Calendar syncs into - no OAuth needed).
/// Neither is required to record; they only supply a nice default title.
enum MeetingDetector {
    private static let eventStore = EKEventStore()

    /// Bundle IDs of common conferencing apps.
    private static let conferencingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.google.Chrome",       // Meet runs in browser
    ]

    /// A conferencing app that is currently running, if any.
    static func activeConferencingApp() -> String? {
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            if conferencingBundleIDs.contains(bundleID), bundleID != "com.google.Chrome" {
                return app.localizedName ?? bundleID
            }
        }
        return nil
    }

    // MARK: - Calendar

    static func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    static var hasCalendarAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    /// The calendar event overlapping `date` (default now), preferring the one
    /// whose window most tightly contains the moment. Returns nil if no access
    /// or no matching event.
    static func currentEvent(at date: Date = Date()) -> EKEvent? {
        guard hasCalendarAccess else { return nil }
        let window: TimeInterval = 60 * 60 // look 1h either side
        let predicate = eventStore.predicateForEvents(
            withStart: date.addingTimeInterval(-window),
            end: date.addingTimeInterval(window),
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.startDate <= date && $0.endDate >= date }
            .sorted { ($0.endDate.timeIntervalSince($0.startDate)) < ($1.endDate.timeIntervalSince($1.startDate)) }
        return events.first
    }

    /// A sensible default title for a meeting starting now.
    static func suggestedTitle(at date: Date = Date()) -> (title: String, eventId: String?) {
        if let event = currentEvent(at: date), let t = event.title, !t.isEmpty {
            return (t, event.eventIdentifier)
        }
        if let app = activeConferencingApp() {
            return ("\(app) call", nil)
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return ("Meeting \(fmt.string(from: date))", nil)
    }
}
