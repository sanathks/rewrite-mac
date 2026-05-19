import Carbon
import AppKit

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var grammarHotKeyRef: EventHotKeyRef?
    private var rewriteHotKeyRef: EventHotKeyRef?
    private var sttHotKeyRef: EventHotKeyRef?
    private var handsFreeHotKeyRef: EventHotKeyRef?
    private var onGrammar: (() -> Void)?
    private var onRewrite: (() -> Void)?
    private var onSTTStart: (() -> Void)?
    private var onSTTStop: (() -> Void)?
    private var onHandsFree: (() -> Void)?
    private var onSTTHoldTransition: (() -> Void)?
    private var handlerInstalled = false

    // Modifier-only shortcut support for STT
    private var sttModifierOnlyShortcut: Shortcut?
    private var modifierMonitor: Any?
    private var sttModifierHeld = false

    // Hold-to-transition timer for STT -> hands-free
    private var sttHoldTimer: Timer?
    private static let holdTransitionInterval: TimeInterval = 15

    private init() {}

    func register(
        grammar: Shortcut,
        rewrite: Shortcut,
        stt: Shortcut,
        handsFree: Shortcut,
        onGrammar: @escaping () -> Void,
        onRewrite: @escaping () -> Void,
        onSTTStart: @escaping () -> Void,
        onSTTStop: @escaping () -> Void,
        onHandsFree: @escaping () -> Void,
        onSTTHoldTransition: @escaping () -> Void
    ) {
        self.onGrammar = onGrammar
        self.onRewrite = onRewrite
        self.onSTTStart = onSTTStart
        self.onSTTStop = onSTTStop
        self.onHandsFree = onHandsFree
        self.onSTTHoldTransition = onSTTHoldTransition

        if !handlerInstalled {
            var eventTypes = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                ),
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)
                )
            ]
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                hotkeyHandler,
                2,
                &eventTypes,
                selfPtr,
                nil
            )
            handlerInstalled = true
        }

        registerKey(shortcut: grammar, id: 1, ref: &grammarHotKeyRef)
        registerKey(shortcut: rewrite, id: 2, ref: &rewriteHotKeyRef)
        registerKey(shortcut: handsFree, id: 4, ref: &handsFreeHotKeyRef)

        if stt.isModifierOnly {
            registerModifierOnlySTT(stt)
        } else {
            removeModifierMonitor()
            registerKey(shortcut: stt, id: 3, ref: &sttHotKeyRef)
        }
    }

    func updateShortcuts(grammar: Shortcut, rewrite: Shortcut, stt: Shortcut, handsFree: Shortcut) {
        unregisterKey(ref: &grammarHotKeyRef)
        unregisterKey(ref: &rewriteHotKeyRef)
        unregisterKey(ref: &sttHotKeyRef)
        unregisterKey(ref: &handsFreeHotKeyRef)
        removeModifierMonitor()

        registerKey(shortcut: grammar, id: 1, ref: &grammarHotKeyRef)
        registerKey(shortcut: rewrite, id: 2, ref: &rewriteHotKeyRef)
        registerKey(shortcut: handsFree, id: 4, ref: &handsFreeHotKeyRef)

        if stt.isModifierOnly {
            registerModifierOnlySTT(stt)
        } else {
            registerKey(shortcut: stt, id: 3, ref: &sttHotKeyRef)
        }
    }

    // MARK: - Pause / Resume (for shortcut recording)

    private var pausedShortcuts: (grammar: Shortcut, rewrite: Shortcut, stt: Shortcut, handsFree: Shortcut)?

    func pause() {
        let settings = Settings.shared
        pausedShortcuts = (settings.grammarShortcut, settings.rewriteShortcut, settings.sttShortcut, settings.handsFreeShortcut)
        unregisterKey(ref: &grammarHotKeyRef)
        unregisterKey(ref: &rewriteHotKeyRef)
        unregisterKey(ref: &sttHotKeyRef)
        unregisterKey(ref: &handsFreeHotKeyRef)
        removeModifierMonitor()
    }

    func resume() {
        guard let shortcuts = pausedShortcuts else { return }
        pausedShortcuts = nil
        updateShortcuts(grammar: shortcuts.grammar, rewrite: shortcuts.rewrite, stt: shortcuts.stt, handsFree: shortcuts.handsFree)
    }

    // MARK: - Modifier-only STT

    private func registerModifierOnlySTT(_ shortcut: Shortcut) {
        sttModifierOnlyShortcut = shortcut
        sttModifierHeld = false

        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierEvent(event)
        }
    }

    private func removeModifierMonitor() {
        sttHoldTimer?.invalidate()
        sttHoldTimer = nil
        if let monitor = modifierMonitor {
            NSEvent.removeMonitor(monitor)
            modifierMonitor = nil
        }
        sttModifierOnlyShortcut = nil
        if sttModifierHeld {
            sttModifierHeld = false
            onSTTStop?()
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        guard let shortcut = sttModifierOnlyShortcut else { return }

        let currentMods = carbonModifiers(from: event.modifierFlags)
        let matches = (currentMods & shortcut.modifiers) == shortcut.modifiers

        if matches && !sttModifierHeld {
            sttModifierHeld = true
            // Dispatch async to avoid deadlock -- STT engine start may block
            // on audio setup which needs the main queue to be free.
            DispatchQueue.main.async { [weak self] in
                self?.onSTTStart?()
                self?.startSTTHoldTimer()
            }
        } else if !matches && sttModifierHeld {
            sttModifierHeld = false
            sttHoldTimer?.invalidate()
            sttHoldTimer = nil
            DispatchQueue.main.async { [weak self] in
                self?.onSTTStop?()
            }
        }
    }

    // MARK: - Carbon hotkeys

    private func registerKey(shortcut: Shortcut, id: UInt32, ref: inout EventHotKeyRef?) {
        guard !shortcut.isModifierOnly else { return }
        let hotKeyID = EventHotKeyID(signature: 0x47465852, id: id)
        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
    }

    private func unregisterKey(ref: inout EventHotKeyRef?) {
        if let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
        }
    }

    fileprivate func handleHotkey(id: UInt32, pressed: Bool) {
        switch id {
        case 1:
            if pressed { onGrammar?() }
        case 2:
            if pressed { onRewrite?() }
        case 3:
            if pressed {
                onSTTStart?()
                startSTTHoldTimer()
            } else {
                sttHoldTimer?.invalidate()
                sttHoldTimer = nil
                onSTTStop?()
            }
        case 4:
            if pressed { onHandsFree?() }
        default:
            break
        }
    }

    private func startSTTHoldTimer() {
        sttHoldTimer?.invalidate()
        sttHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTransitionInterval, repeats: false) { [weak self] _ in
            self?.sttHoldTimer = nil
            self?.onSTTHoldTransition?()
        }
    }
}

private func hotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else {
        return OSStatus(eventNotHandledErr)
    }
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
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotkey(id: hotKeyID.id, pressed: pressed)
    return noErr
}
