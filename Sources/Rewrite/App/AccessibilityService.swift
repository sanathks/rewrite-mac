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
            return getTextAroundCursor()
        }

        return text
    }

    /// When nothing is selected, grab the paragraph (or sentence if too long)
    /// around the current cursor position. This enables "fix grammar" without
    /// manual text selection.
    func getTextAroundCursor() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success else {
            return nil
        }

        let focused = focusedRaw as! AXUIElement
        cachedFocusedElement = focused

        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        sourceAppPID = pid
        enableEnhancedUI(for: pid)

        // Get the full text content
        var fullTextRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &fullTextRaw
        ) == .success, let fullText = fullTextRaw as? String, !fullText.isEmpty else {
            return nil
        }

        // Determine cursor position
        let cursorPos = findCursorPosition(in: fullText, focusedElement: focused)
        guard cursorPos >= 0, cursorPos <= fullText.count else { return nil }

        // Try paragraph first, then sentence
        if let paragraph = extractParagraph(from: fullText, at: cursorPos) {
            return paragraph
        }

        return nil
    }

    /// Find the character offset of the cursor/selection start.
    private func findCursorPosition(in text: String, focusedElement: AXUIElement) -> Int {
        let chars = Array(text)

        // 1. Try AXSelectedTextRangeAttribute (AppKit text views)
        if let rangeValue = copyAXAttributeAsValue(focusedElement, kAXSelectedTextRangeAttribute as CFString) {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue, .cfRange, &cfRange) {
                return min(cfRange.location, chars.count)
            }
        }

        // 2. Try AXSelectedTextMarkerRangeAttribute (web views)
        if let markerRangeRaw = copyAXAttribute(focusedElement, "AXSelectedTextMarkerRange" as CFString),
           let markerRange = markerRangeRaw as? AXValue {
            // For web views, try to get the start marker's character position
            // This is a best-effort — web views often don't expose character positions
            var startMarker: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                focusedElement,
                "AXStartTextMarkerAttribute" as CFString,
                markerRange,
                &startMarker
            ) == .success, let marker = startMarker as? AXValue {
                // Try to get character position from the marker
                if let charPos = getCharacterPosition(from: marker, in: focusedElement) {
                    return min(charPos, chars.count)
                }
            }
        }

        // 3. Try AXCursorCharacterPositionAttribute (some text fields)
        if let cursorPosRaw = copyAXAttributeAsInt32(focusedElement, "AXCursorCharacterPosition" as CFString) {
            return min(cursorPosRaw, chars.count)
        }

        // 4. Fallback: use mouse position to estimate cursor
        return estimateCursorPositionFromMouse(in: text)
    }

    /// Copy an AX attribute value as an AXValue (for ranges, rects, etc.)
    private func copyAXAttributeAsValue(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as? AXValue else { return nil }
        return value
    }

    /// Copy an AX attribute as a raw AnyObject
    private func copyAXAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw
    }

    /// Copy an AX attribute as an Int32
    private func copyAXAttributeAsInt32(_ element: AXUIElement, _ attribute: CFString) -> Int32? {
        var value: Int32 = 0
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    /// Get character position from a text marker (for web views).
    /// This is a best-effort — many web views don't expose this.
    private func getCharacterPosition(from marker: AXValue, in element: AXUIElement) -> Int? {
        // Try to get the character position via AXPositionAttribute
        // This is implementation-specific and may not work for all web views
        var posRaw: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXPositionAttribute" as CFString, &posRaw) == .success {
            // Some web views expose character position directly
            if let charPos = posRaw as? Int32 {
                return Int(charPos)
            }
        }
        return nil
    }

    /// Estimate cursor position based on mouse location.
    private func estimateCursorPositionFromMouse(in text: String) -> Int {
        guard let screen = NSScreen.screens.first else { return text.count / 2 }
        let mouse = NSEvent.mouseLocation
        let axY = Float(screen.frame.height - mouse.y)

        let systemWide = AXUIElementCreateSystemWide()
        var elementRaw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(mouse.x), axY, &elementRaw
        ) == .success, let element = elementRaw else {
            return text.count / 2
        }

        // Try to get text marker range from this element
        if let markerRangeRaw = copyAXAttribute(element, "AXSelectedTextMarkerRange" as CFString),
           let markerRange = markerRangeRaw as? AXValue {
            var startMarker: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXStartTextMarkerAttribute" as CFString,
                markerRange,
                &startMarker
            ) == .success, let marker = startMarker as? AXValue {
                if let charPos = getCharacterPosition(from: marker, in: element) {
                    return charPos
                }
            }
        }

        return text.count / 2
    }

    /// Extract the paragraph containing the given character position.
    /// A paragraph is delimited by newlines. If the paragraph is too long
    /// (>500 chars), falls back to sentence extraction.
    private func extractParagraph(from text: String, at position: Int) -> String? {
        let chars = Array(text)
        guard position >= 0, position <= chars.count else { return nil }

        // Find paragraph start (scan backwards for newline)
        var start = position
        while start > 0 {
            start -= 1
            if chars[start] == "\n" || chars[start] == "\r" {
                start += 1
                break
            }
        }

        // Find paragraph end (scan forwards for newline)
        var end = position
        while end < chars.count {
            if chars[end] == "\n" || chars[end] == "\r" {
                break
            }
            end += 1
        }

        let paragraph = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)

        // If paragraph is too long, extract sentence instead
        if paragraph.count > 500 {
            return extractSentence(from: text, at: position)
        }

        return paragraph.isEmpty ? nil : paragraph
    }

    /// Extract the sentence containing the given character position.
    /// A sentence is delimited by period+space, newline, or end of text.
    private func extractSentence(from text: String, at position: Int) -> String? {
        let chars = Array(text)
        guard position >= 0, position < chars.count else { return nil }

        // Find sentence start (scan backwards for sentence boundary)
        var start = position
        while start > 0 {
            start -= 1
            if chars[start] == "." || chars[start] == "!" || chars[start] == "?" {
                // Check if followed by space/newline (actual sentence boundary)
                if start + 1 < chars.count && (chars[start + 1] == " " || chars[start + 1] == "\n" || chars[start + 1] == "\r") {
                    start += 1
                    break
                }
            }
            if chars[start] == "\n" || chars[start] == "\r" {
                start += 1
                break
            }
        }

        // Find sentence end (scan forwards for sentence boundary)
        var end = position
        while end < chars.count {
            if chars[end] == "." || chars[end] == "!" || chars[end] == "?" {
                if end + 1 < chars.count && (chars[end + 1] == " " || chars[end + 1] == "\n" || chars[end + 1] == "\r" || end + 1 == chars.count) {
                    end += 1
                    break
                }
            }
            if chars[end] == "\n" || chars[end] == "\r" {
                break
            }
            end += 1
        }

        let sentence = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
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

        // If there was an original selection, try direct AX write first.
        if !originalText.isEmpty {
            if replaceSelectedTextViaAX(text, originalText: originalText) { return }
        }

        // For paragraph/sentence replacement (no original selection) or when
        // AX write fails, use clipboard-based paste.
        replaceTextViaClipboard(text)
    }

    /// Replace the currently selected text (or paragraph under cursor) via
    /// clipboard paste. This is used when the user triggered grammar fix
    /// without an explicit selection — we've grabbed the paragraph and need
    /// to select it before pasting the replacement.
    private func replaceTextViaClipboard(_ text: String) {
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

    /// Replace a paragraph/sentence at the cursor position via clipboard.
    /// This is the full flow for grammar fix without selection:
    /// 1. Select the paragraph text via AX
    /// 2. Paste the replacement
    func replaceParagraph(_ text: String, originalText: String) {
        // Ensure the source app is focused
        if let app = NSRunningApplication(processIdentifier: sourceAppPID), !app.isActive {
            app.activate()
            let start = Date()
            while !app.isActive && Date().timeIntervalSince(start) < 0.5 {
                usleep(20_000)
            }
            usleep(50_000)
        }

        // Re-query the focused element
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRaw: AnyObject?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success {
            cachedFocusedElement = (focusedRaw as! AXUIElement)
        }

        // Select the paragraph text before pasting
        if let focused = cachedFocusedElement {
            selectParagraph(focused, originalText: originalText)
        }

        // Paste the replacement
        replaceTextViaClipboard(text)
    }

    /// Select the paragraph text in the focused AX element.
    private func selectParagraph(_ element: AXUIElement, originalText: String) {
        let chars = Array(originalText)
        guard !chars.isEmpty else { return }

        // Try AppKit-style range selection
        let range = CFRange(location: 0, length: chars.count)
        let rangeValue = AXValueCreate(.cfRange, &range)!
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )

        // Brief pause to let the selection take effect
        usleep(50_000)
    }

    /// Insert text at cursor via clipboard paste (no AX write attempt).
    /// Use this for voice input where there is no prior selection.
    func insertTextInSourceApp(_ text: String) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let appExists = NSRunningApplication(processIdentifier: sourceAppPID) != nil
        NSLog("[voice-insert] enter sourceAppPID=\(sourceAppPID) front=\(frontPid)(\(frontName)) appExists=\(appExists) NSApp.isActive=\(NSApp.isActive) textLen=\(text.count)")

        if let app = NSRunningApplication(processIdentifier: sourceAppPID), !app.isActive {
            NSLog("[voice-insert] activating sourceAppPID=\(sourceAppPID)")
            app.activate()
            let start = Date()
            while !app.isActive && Date().timeIntervalSince(start) < 0.5 {
                usleep(20_000)
            }
            NSLog("[voice-insert] post-activate isActive=\(app.isActive) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
            usleep(50_000)
        }

        let saved = savePasteboard()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))

        let pbCheck = pasteboard.string(forType: .string) ?? "<nil>"
        NSLog("[voice-insert] pre-paste pb=\(pbCheck.prefix(40)) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)(\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) NSApp.isActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow?.className ?? "nil")")

        simulateKeyPress(keyCode: 0x09, flags: .maskCommand) // Cmd+V
        usleep(200_000)

        restorePasteboard(saved)
        NSLog("[voice-insert] done")
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
