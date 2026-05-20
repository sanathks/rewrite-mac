import AppKit
import SwiftUI

/// Small bottom-right toast that asks the user to add a learned word to
/// their voice vocabulary. Auto-dismisses after `autoDismissAfter` seconds
/// if the user doesn't react. Always called on the main thread.
final class HotwordSuggestionPanel {
    static let shared = HotwordSuggestionPanel()
    private init() {}

    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<HotwordSuggestionView>?
    private var autoDismissWorkItem: DispatchWorkItem?

    private let panelSize = NSSize(width: 280, height: 64)
    private let bottomRightMargin: CGFloat = 24
    private let autoDismissAfter: TimeInterval = 10

    func show(word: String, onChoice: @escaping (Bool) -> Void) {
        hide(invokeCallback: nil)

        let view = HotwordSuggestionView(
            word: word,
            onAdd: { [weak self] in
                self?.hide(invokeCallback: { onChoice(true) })
            },
            onDismiss: { [weak self] in
                self?.hide(invokeCallback: { onChoice(false) })
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize)
        )
        panel.contentView = hosting
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(bottomRightOrigin())
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostingView = hosting

        let work = DispatchWorkItem { [weak self] in
            self?.hide(invokeCallback: { onChoice(false) })
        }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: work)
    }

    private func hide(invokeCallback: (() -> Void)?) {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        invokeCallback?()
    }

    private func bottomRightOrigin() -> NSPoint {
        // Pin to the screen where the cursor currently lives so the toast
        // appears on the user's active display, not always the primary.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first!
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.maxX - panelSize.width - bottomRightMargin,
            y: frame.minY + bottomRightMargin
        )
    }
}

private struct HotwordSuggestionView: View {
    let word: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 1) {
                Text("Add to vocabulary?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Text(word)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button(action: onAdd) {
                Text("Add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.22))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
