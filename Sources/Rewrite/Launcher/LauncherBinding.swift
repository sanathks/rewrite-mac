import Carbon.HIToolbox
import Foundation

/// One configured "modifier-combo + key → launch app" shortcut.
struct LauncherBinding: Codable, Identifiable, Equatable {
    var id: UUID
    /// Single-character lowercase trigger key, e.g. "g", "s". Matched
    /// against the event's typed character so it works across keyboard
    /// layouts.
    var triggerKey: String
    /// Persistent identifier so we can re-resolve the app if it moves.
    var appBundleID: String
    /// File URL of the app bundle, used to render its icon and as the
    /// primary launch path.
    var appURL: URL
    /// Human-readable name shown in Settings.
    var displayName: String

    init(
        id: UUID = UUID(),
        triggerKey: String,
        appBundleID: String,
        appURL: URL,
        displayName: String
    ) {
        self.id = id
        self.triggerKey = triggerKey.lowercased()
        self.appBundleID = appBundleID
        self.appURL = appURL
        self.displayName = displayName
    }
}

/// Modifier combination that prefixes every launcher chord. Carbon's
/// `RegisterEventHotKey` only fires when the exact modifier mask is held,
/// so picking an uncommon combo (⌃⌥ by default) reliably avoids clashes
/// with normal app shortcuts.
enum LauncherPrefix: String, Codable, CaseIterable, Identifiable {
    case ctrlOption
    case cmdOption
    case ctrlShift
    case cmdShift
    case cmdCtrl
    case optionShift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ctrlOption: return "\u{2303}\u{2325}"         // ⌃⌥
        case .cmdOption: return "\u{2318}\u{2325}"          // ⌘⌥
        case .ctrlShift: return "\u{2303}\u{21E7}"          // ⌃⇧
        case .cmdShift: return "\u{2318}\u{21E7}"           // ⌘⇧
        case .cmdCtrl: return "\u{2303}\u{2318}"            // ⌃⌘
        case .optionShift: return "\u{2325}\u{21E7}"        // ⌥⇧
        }
    }

    /// Carbon modifier mask used by `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        switch self {
        case .ctrlOption: return UInt32(controlKey | optionKey)
        case .cmdOption: return UInt32(cmdKey | optionKey)
        case .ctrlShift: return UInt32(controlKey | shiftKey)
        case .cmdShift: return UInt32(cmdKey | shiftKey)
        case .cmdCtrl: return UInt32(controlKey | cmdKey)
        case .optionShift: return UInt32(optionKey | shiftKey)
        }
    }
}
