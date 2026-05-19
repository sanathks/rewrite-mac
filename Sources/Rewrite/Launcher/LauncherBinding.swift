import Foundation

/// One configured "prefix + key → launch app" shortcut.
struct LauncherBinding: Codable, Identifiable, Equatable {
    var id: UUID
    /// Single-character lowercase trigger key, e.g. "g", "s". The character
    /// is matched against the event's first character; we deliberately
    /// don't store the keycode because keyboard layouts differ.
    var triggerKey: String
    /// Persistent identifier so we can re-resolve the app if it moves.
    var appBundleID: String
    /// File URL of the app's bundle, used to show its icon in the UI and
    /// as a launch fallback when LaunchServices doesn't know the bundle ID.
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

/// Held-key choices for the launcher prefix. Space is the default — it
/// covers the Karabiner-style "hyper on hold" workflow without occupying
/// a modifier the user might already use.
enum LauncherPrefixKey: String, Codable, CaseIterable, Identifiable {
    case space
    case rightCommand
    case capsLock
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .space: return "Space"
        case .rightCommand: return "Right \u{2318}"
        case .capsLock: return "Caps Lock"
        case .fn: return "fn"
        }
    }

    /// Carbon virtual key code used to match the held key against the
    /// CGEventTap stream.
    var keyCode: UInt16 {
        switch self {
        case .space: return 49           // kVK_Space
        case .rightCommand: return 54    // kVK_RightCommand
        case .capsLock: return 57        // kVK_CapsLock
        case .fn: return 63              // kVK_Function
        }
    }
}
