import AppKit
import ApplicationServices

final class AccessibilityService {
    static let shared = AccessibilityService()
    private init() {}

    /// The PID of the app that was focused when we last read text.
    var sourceAppPID: pid_t = 0

    /// Cached focused element from the last getSelectedText() call,
    /// reused by getSelectionRect() to avoid a second AX query that
    /// may fail for web-based apps.
    private var cachedFocusedElement: AXUIElement?

    /// PIDs we have already told to activate their accessibility tree.
    private var enhancedUIPIDs: Set<pid_t> = []

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Tell Chrome / Electron to expose their full accessibility tree.
    private func enableEnhancedUI(for pid: pid_t) {
        guard !enhancedUIPIDs.contains(pid) else { return }
        enhancedUIPIDs.insert(pid)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            axApp,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
        AXUIElementSetAttributeValue(
            axApp,
            "AXManualAccessibility" as CFString,
            true as CFTypeRef
        )
    }

    /// Read the currently selected text via the Accessibility API.
    func getSelectedText() -> String? {
        cachedFocusedElement = nil

        let systemWide = AXUIElementCreateSystemWide()

        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success else {
            return getSelectedTextViaClipboard()
        }

        let focused = focusedRaw as! AXUIElement
        cachedFocusedElement = focused

        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        sourceAppPID = pid
        enableEnhancedUI(for: pid)

        var selectedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedRaw
        ) == .success, let text = selectedRaw as? String, !text.isEmpty else {
            return getSelectedTextViaClipboard()
        }

        return text
    }

    /// Get the screen position of the currently selected text.
    /// Tries the focused element and its parents, then the element under
    /// the mouse cursor (for chat apps where focus is on the composer but
    /// the selection is in the message area), then falls back to mouse.
    func getSelectionRect() -> NSRect {
        // Try 1: focused element + parents
        if let cached = cachedFocusedElement {
            if let rect = findSelectionBounds(startingFrom: cached) {
                return axRectToAppKit(rect)
            }
        }

        // Try 2: element at the mouse position + parents.
        if let rect = selectionBoundsAtMouse() {
            return axRectToAppKit(rect)
        }

        // Try 3: mouse position (most reliable universal fallback)
        return mouseRect()
    }

    /// Walk an element and its parents looking for selection bounds.
    private func findSelectionBounds(startingFrom element: AXUIElement) -> CGRect? {
        var chain: [AXUIElement] = [element]
        var current = element
        for _ in 0..<10 {
            var parentRaw: AnyObject?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parentRaw
            ) == .success else { break }
            let parent = parentRaw as! AXUIElement
            chain.append(parent)
            current = parent
        }

        for el in chain {
            if let r = selectionBounds(for: el) { return r }
        }
        for el in chain {
            if let r = textMarkerBounds(for: el) { return r }
        }
        return nil
    }

    /// Get the AX element under the mouse cursor and try to get
    /// selection bounds from it or its parents. Only returns actual
    /// selection bounds, never element frames (which are too large).
    private func selectionBoundsAtMouse() -> CGRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        let mouse = NSEvent.mouseLocation
        let axX = Float(mouse.x)
        let axY = Float(screen.frame.height - mouse.y)

        let systemWide = AXUIElementCreateSystemWide()
        var elementRaw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, axX, axY, &elementRaw
        ) == .success, let element = elementRaw else {
            return nil
        }

        return findSelectionBounds(startingFrom: element)
    }

    // MARK: - Selection bounds strategies

    /// Standard AX range bounds (works with native NSTextView / NSTextField).
    private func selectionBounds(for element: AXUIElement) -> CGRect? {
        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success else { return nil }

        let rangeValue = rangeRaw as! AXValue
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &cfRange),
              cfRange.length > 0 else { return nil }

        var boundsRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRaw
        ) == .success else { return nil }

        let boundsValue = boundsRaw as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Text-marker based bounds (works with Chrome, Safari, Electron web views).
    private func textMarkerBounds(for element: AXUIElement) -> CGRect? {
        var markerRangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeRaw
        ) == .success, markerRangeRaw != nil else {
            return nil
        }

        var boundsRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRangeRaw!,
            &boundsRaw
        ) == .success else {
            return nil
        }

        let boundsValue = boundsRaw as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func elementFrame(for element: AXUIElement) -> CGRect? {
        var posRaw: AnyObject?
        var sizeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRaw
        ) == .success,
        AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRaw
        ) == .success else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Convert AX coordinates (top-left origin) to AppKit coordinates (bottom-left origin).
    private func axRectToAppKit(_ axRect: CGRect) -> NSRect {
        guard let screen = NSScreen.screens.first else {
            return NSRect(origin: .zero, size: axRect.size)
        }
        let screenHeight = screen.frame.height
        let flippedY = screenHeight - axRect.origin.y - axRect.height
        return NSRect(x: axRect.origin.x, y: flippedY,
                      width: axRect.width, height: axRect.height)
    }

    private func mouseRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
    }

    // MARK: - Pasteboard save / restore

    private typealias PasteboardItem = [(NSPasteboard.PasteboardType, Data)]

    private func savePasteboard() -> [PasteboardItem] {
        let pasteboard = NSPasteboard.general
        var snapshot: [PasteboardItem] = []
        guard let items = pasteboard.pasteboardItems else { return snapshot }
        for item in items {
            var typesAndData: PasteboardItem = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    typesAndData.append((type, data))
                }
            }
            snapshot.append(typesAndData)
        }
        return snapshot
    }

    private func restorePasteboard(_ snapshot: [PasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var pbItems: [NSPasteboardItem] = []
        for itemData in snapshot {
            let pbItem = NSPasteboardItem()
            for (type, data) in itemData {
                pbItem.setData(data, forType: type)
            }
            pbItems.append(pbItem)
        }
        pasteboard.writeObjects(pbItems)
    }

    // MARK: - AX-based text replacement

    /// Try to replace the selected text directly via AX attribute.
    /// Returns true if the write succeeded.
    /// Electron apps report success but don't modify the text — detected by
    /// reading back and comparing against the original selected text.
    private func replaceSelectedTextViaAX(_ text: String, originalText: String) -> Bool {
        guard let focused = cachedFocusedElement else { return false }

        // Check if the attribute is writable first.
        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        if settableResult != .success || !isSettable.boolValue {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if result != .success { return false }

        // Verify by reading back the selected text.
        // In native AppKit views, the selection collapses after replacement,
        // so the read-back returns "" (not `text`) — this is fine.
        // In Electron/web views, the write silently fails and the read-back
        // still shows the original selected text — in that case fall through
        // to the clipboard paste path.
        var readBack: AnyObject?
        if AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &readBack
        ) == .success,
           let written = readBack as? String,
           !originalText.isEmpty,
           written == originalText {
            // Write was ignored (Electron / read-only web view).
            return false
        }

        return true
    }

    // MARK: - Clipboard fallbacks

    /// Fallback: simulate Cmd+C and read from pasteboard.
    private func getSelectedTextViaClipboard() -> String? {
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            sourceAppPID = frontApp.processIdentifier
        }

        let saved = savePasteboard()

        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount

        simulateKeyPress(keyCode: 0x08, flags: .maskCommand) // Cmd+C
        usleep(150_000) // 150ms

        guard pasteboard.changeCount != oldChangeCount else {
            restorePasteboard(saved)
            return nil
        }
        let text = pasteboard.string(forType: .string)

        restorePasteboard(saved)
        return text
    }

    /// Replace text in the source app, preferring AX, falling back to paste.
    func replaceTextInSourceApp(_ text: String, originalText: String = "") {
        // Ensure the source app is focused (it may have lost focus during LLM
        // processing for the grammar-fix flow, or in rare edge cases).
        if let app = NSRunningApplication(processIdentifier: sourceAppPID), !app.isActive {
            app.activate()
            let start = Date()
            while !app.isActive && Date().timeIntervalSince(start) < 0.5 {
                usleep(20_000)
            }
            usleep(50_000)
        }

        // Re-query the focused element so the AX reference is fresh.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRaw: AnyObject?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success {
            cachedFocusedElement = (focusedRaw as! AXUIElement)
        }

        // Fast path: direct AX write (works for native AppKit text views).
        if replaceSelectedTextViaAX(text, originalText: originalText) { return }

        // Slow path: clipboard-based paste with save/restore.
        let saved = savePasteboard()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Mark as transient so clipboard managers ignore this temporary content.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))

        simulateKeyPress(keyCode: 0x09, flags: .maskCommand) // Cmd+V
        usleep(200_000) // wait for paste to land

        restorePasteboard(saved)
    }

    /// Insert text at cursor via clipboard paste (no AX write attempt).
    /// Use this for voice input where there is no prior selection.
    func insertTextInSourceApp(_ text: String) {
        if let app = NSRunningApplication(processIdentifier: sourceAppPID), !app.isActive {
            app.activate()
            let start = Date()
            while !app.isActive && Date().timeIntervalSince(start) < 0.5 {
                usleep(20_000)
            }
            usleep(50_000)
        }

        let saved = savePasteboard()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))

        simulateKeyPress(keyCode: 0x09, flags: .maskCommand) // Cmd+V
        usleep(200_000)

        restorePasteboard(saved)
    }

    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        usleep(50_000)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
