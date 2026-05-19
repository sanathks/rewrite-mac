import AppKit
import Carbon.HIToolbox

/// Modifier-combo + key → launch app. Uses Carbon `RegisterEventHotKey`
/// so the OS only invokes our handler on the exact registered combination
/// — no event tap, no held-key state machine, no risk of breaking plain
/// typing or stealing input from other apps.
///
/// Re-registers all hotkeys whenever the user changes the prefix or
/// edits a binding via Settings (call `reload()`).
final class LauncherEngine {
    static let shared = LauncherEngine()
    private init() {}

    /// 'LNCH' — distinct signature from `HotkeyManager` ('GFXR') so the
    /// two event handlers don't accidentally dispatch each other's events.
    private static let signature: OSType = 0x4C4E4348

    private var handlerInstalled = false
    private var nextHotKeyID: UInt32 = 1000
    /// EventHotKeyID.id → binding.
    private var bindingsByHotKeyID: [UInt32: LauncherBinding] = [:]
    /// EventHotKeyID.id → ref (kept so we can unregister cleanly).
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    // MARK: - Public

    /// Install the Carbon event handler and register all current bindings.
    /// Safe to call repeatedly — re-registers from a clean slate.
    func install() {
        installHandler()
        reload()
    }

    /// Drop every registered hotkey. Handler stays installed (cheap, no
    /// events arrive without registrations) so a later `install()` is fast.
    func uninstall() {
        unregisterAll()
    }

    /// Re-read prefix + bindings from Settings and re-register everything.
    /// Idempotent; safe to call from `@Published` observers.
    func reload() {
        unregisterAll()
        let settings = Settings.shared
        guard settings.launcherEnabled else { return }
        let mods = settings.launcherPrefix.carbonModifiers
        for binding in settings.launcherBindings {
            register(binding: binding, modifiers: mods)
        }
    }

    // MARK: - Registration

    private func register(binding: LauncherBinding, modifiers: UInt32) {
        guard let keyCode = Self.carbonKeyCode(for: binding.triggerKey) else { return }
        let id = nextHotKeyID
        nextHotKeyID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return }
        hotKeyRefs[id] = ref
        bindingsByHotKeyID[id] = binding
    }

    private func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        bindingsByHotKeyID.removeAll()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            launcherHotkeyHandler,
            1,
            &eventTypes,
            selfPtr,
            nil
        )
        handlerInstalled = true
    }

    fileprivate func handle(id: UInt32) {
        guard let binding = bindingsByHotKeyID[id] else { return }
        launch(binding)
    }

    // MARK: - Launch

    private func launch(_ binding: LauncherBinding) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: binding.appURL, configuration: config) { [bundleID = binding.appBundleID] _, error in
            guard error != nil else { return }
            // Fallback: bundle ID lookup if the cached URL is stale.
            if let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: fallback, configuration: config, completionHandler: nil)
            }
        }
    }

    // MARK: - Key code mapping

    /// US-ANSI keycodes for the practical chord-trigger subset: a–z and 0–9.
    /// Other characters return nil; the UI restricts input to this set so
    /// users can't bind keys we can't register.
    private static func carbonKeyCode(for char: String) -> UInt32? {
        guard let c = char.lowercased().first else { return nil }
        switch c {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0)
        case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2)
        case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4)
        case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6)
        case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8)
        case "9": return UInt32(kVK_ANSI_9)
        default: return nil
        }
    }
}

// MARK: - C-callable handler

private func launcherHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    // Ignore events that aren't ours (HotkeyManager's main shortcuts).
    if hotKeyID.signature != 0x4C4E4348 { return OSStatus(eventNotHandledErr) }
    let engine = Unmanaged<LauncherEngine>.fromOpaque(userData).takeUnretainedValue()
    engine.handle(id: hotKeyID.id)
    return noErr
}
