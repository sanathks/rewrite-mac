import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Karabiner-style "hold prefix → press key → launch app" chord engine.
///
/// Installs a `CGEventTap` on the keyboard event stream. While the user
/// holds the configured prefix (Space by default), pressing another key
/// matches against `LauncherBinding`s and launches the corresponding app.
/// If no chord triggers before the user releases the prefix, the prefix
/// key is synthesised as a normal press so plain typing isn't broken.
///
/// Requires Accessibility privilege (already required by the rest of the
/// app). If not granted, `install()` is a no-op until the user authorises.
final class LauncherEngine {
    static let shared = LauncherEngine()
    private init() {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// State machine: tracks the held prefix and whether any chord fired
    /// during the current hold. Cleared on prefix keyUp.
    private var prefixHeld = false
    private var chordFired = false

    /// Resolved at install time from Settings. Updated by `reload()` when
    /// the user edits Settings.
    private var prefixKeyCode: UInt16 = LauncherPrefixKey.space.keyCode
    private var bindingsByKey: [String: LauncherBinding] = [:]

    /// Marker written into our synthesised events' userData so the tap
    /// can recognise them and pass through without re-triggering chord
    /// logic. Without this, `emitPrefixTap()` would feed events back into
    /// our own tap and stick the state machine in an infinite loop.
    private static let syntheticEventMarker: Int64 = 0x52455752_4954_4500  // 'REWRITE\0'

    // MARK: - Public API

    /// Install the event tap. Safe to call multiple times — uninstalls
    /// any existing tap first.
    func install() {
        uninstall()
        reload()

        guard AXIsProcessTrusted() else {
            // Without Accessibility, CGEventTap can be created but won't
            // receive events. Bail until the user grants the privilege.
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: refcon
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func uninstall() {
        if let tap, let runLoopSource {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        prefixHeld = false
        chordFired = false
    }

    /// Re-read current bindings + prefix from Settings. Cheap; safe to
    /// call from `@Published` observers.
    func reload() {
        let settings = Settings.shared
        prefixKeyCode = settings.launcherPrefixKey.keyCode
        var map: [String: LauncherBinding] = [:]
        for binding in settings.launcherBindings {
            map[binding.triggerKey.lowercased()] = binding
        }
        bindingsByKey = map
    }

    // MARK: - Tap callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<LauncherEngine>.fromOpaque(refcon).takeUnretainedValue()
        return engine.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The kernel can disable the tap if our callback is too slow.
        // Reset state so we don't come back with a stale prefixHeld=true.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            prefixHeld = false
            chordFired = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Events we synthesised ourselves (via emitPrefixTap) must not feed
        // back into chord logic — otherwise we recurse forever.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        // Only the launcher feature being on AND at least one binding
        // existing justifies handling events at all.
        if !Settings.shared.launcherEnabled || bindingsByKey.isEmpty {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            // Prefix down → start a chord window. Swallow the event so the
            // app receiving focus doesn't see the prefix yet.
            if keyCode == prefixKeyCode && !prefixHeld {
                prefixHeld = true
                chordFired = false
                return nil
            }

            // Chord key down while prefix is held → look up binding.
            if prefixHeld {
                let pressed = characterForKey(event: event)
                if let binding = bindingsByKey[pressed] {
                    chordFired = true
                    launch(binding)
                    return nil
                }
                // Unknown chord key. Treat as no-match: emit the buffered
                // prefix first so the user's intent (Space + something) is
                // recoverable, then this key. Reset state.
                emitPrefixTap()
                prefixHeld = false
                chordFired = false
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .keyUp && keyCode == prefixKeyCode {
            if chordFired {
                // Chord already launched something; drop the prefix release.
                prefixHeld = false
                chordFired = false
                return nil
            }
            if prefixHeld {
                // Prefix was held but no chord fired. Synthesise a normal
                // prefix-key press so typing works as expected.
                prefixHeld = false
                emitPrefixTap()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Helpers

    /// Best-effort lowercase character for a chord key event. Uses the
    /// event's Unicode payload first, falling back to keycode→char.
    private func characterForKey(event: CGEvent) -> String {
        var len = 0
        var chars: [UniChar] = Array(repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        if len > 0 {
            let str = String(utf16CodeUnits: chars, count: len).lowercased()
            return str
        }
        return ""
    }

    /// Synthesise a real press + release of the prefix key so it reaches
    /// the focused app exactly as if the user had typed it normally.
    /// Both events are stamped with `syntheticEventMarker` so our own tap
    /// recognises them and skips chord processing.
    private func emitPrefixTap() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: prefixKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: prefixKeyCode, keyDown: false)
        else { return }
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func launch(_ binding: LauncherBinding) {
        // Prefer launching by URL — the bundle ID lookup goes via
        // LaunchServices which can be slow for first-time apps.
        let url = binding.appURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [bundleID = binding.appBundleID] _, error in
            if error == nil { return }
            // Fallback: bundle ID lookup if the cached URL is stale.
            if let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: fallback, configuration: config, completionHandler: nil)
            }
        }
    }
}
