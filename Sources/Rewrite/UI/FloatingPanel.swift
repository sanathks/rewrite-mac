import AppKit

/// A non-activating floating panel that never steals focus from the source app.
/// This is the same pattern used by Maccy, WritingTools, and Raycast.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        appearance = NSAppearance(named: .darkAqua)
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
