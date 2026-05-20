import AppKit
import SwiftUI

/// Small floating pill that appears just above the user's selection while
/// a "silent" rewrite (Fix Grammar) is in flight. Reuses `StageLabel`
/// from `RecordingIndicatorPanel` so the animation matches the voice
/// "Drafting…/Cleaning…" feedback the user is already familiar with.
///
/// Non-activating — the source app keeps key focus so the AX write-back
/// on completion lands correctly.
final class InlineProgressPanel {
    private var panel: FloatingPanel?
    /// Pre-built hosting controller. Created lazily and reused so the
    /// first show isn't slowed by SwiftUI cold-start.
    private var hostingController: NSHostingController<InlineProgressView>?
    private let viewModel = InlineProgressViewModel()

    private let panelSize = NSSize(width: 180, height: 32)

    func show(at selectionRect: NSRect, label: String) {
        viewModel.label = label
        viewModel.isVisible = true

        let panel = ensurePanel()
        panel.setFrameOrigin(origin(for: selectionRect))
        panel.orderFrontRegardless()
    }

    func close() {
        viewModel.isVisible = false
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }
        let hosting = NSHostingController(rootView: InlineProgressView(model: viewModel))
        hosting.view.frame = NSRect(origin: .zero, size: panelSize)
        hostingController = hosting

        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: panelSize))
        p.contentView = hosting.view
        p.setContentSize(panelSize)
        panel = p
        return p
    }

    /// Anchor below the selection rect (Cocoa coords: smaller Y is lower
    /// on screen). Mirrors `ResultPanel.panelOrigin` so both feedback
    /// surfaces sit in the same place relative to the user's selection.
    /// Clamps to the visible frame of the screen the rect lives on so
    /// edge selections don't get clipped.
    private func origin(for selectionRect: NSRect) -> NSPoint {
        var origin: NSPoint
        if selectionRect.width > 0 && selectionRect.height > 0 {
            origin = NSPoint(
                x: selectionRect.origin.x,
                y: selectionRect.origin.y - panelSize.height - 4
            )
        } else if selectionRect.origin.x != 0 || selectionRect.origin.y != 0 {
            origin = NSPoint(
                x: selectionRect.origin.x - panelSize.width / 2,
                y: selectionRect.origin.y - panelSize.height - 4
            )
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(
                x: mouse.x - panelSize.width / 2,
                y: mouse.y - panelSize.height - 4
            )
        }

        let screen = screenContaining(point: NSPoint(
            x: selectionRect.midX, y: selectionRect.midY
        )) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let v = screen.visibleFrame
            origin.x = max(v.minX, min(origin.x, v.maxX - panelSize.width))
            origin.y = max(v.minY, min(origin.y, v.maxY - panelSize.height))
        }
        return origin
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(point, $0.frame) }
    }
}

final class InlineProgressViewModel: ObservableObject {
    @Published var label: String = ""
    /// Gates the shimmer's TimelineView so it doesn't burn CPU when the
    /// panel is hidden but still allocated.
    @Published var isVisible: Bool = false
}

struct InlineProgressView: View {
    @ObservedObject var model: InlineProgressViewModel

    var body: some View {
        StageLabel(label: model.label, isAnimating: model.isVisible)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .preferredColorScheme(.dark)
    }
}
