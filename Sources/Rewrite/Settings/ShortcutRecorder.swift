import SwiftUI
import AppKit
import Carbon

struct ShortcutRecorder: View {
    let label: String
    @Binding var shortcut: Shortcut
    /// When true, allows modifier-only shortcuts (e.g. Ctrl+Option with no letter key).
    var allowModifierOnly: Bool = false
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)

            Button(action: {
                if !isRecording {
                    HotkeyManager.shared.pause()
                    isRecording = true
                } else {
                    isRecording = false
                    HotkeyManager.shared.resume()
                }
            }) {
                Text(isRecording ? "Press shortcut..." : shortcut.displayString)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 100)
            }
            .controlSize(.small)
            .background(
                ShortcutCaptureView(
                    isRecording: $isRecording,
                    shortcut: $shortcut,
                    allowModifierOnly: allowModifierOnly
                )
                .frame(width: 0, height: 0)
            )
        }
    }
}

/// Hidden NSView that captures key events when recording
struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var shortcut: Shortcut
    var allowModifierOnly: Bool

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.allowModifierOnly = allowModifierOnly
        view.onCapture = { keyCode, modifiers in
            shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
            isRecording = false
            HotkeyManager.shared.resume()
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.isRecording = isRecording
        nsView.allowModifierOnly = allowModifierOnly
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class ShortcutCaptureNSView: NSView {
    var isRecording = false
    var allowModifierOnly = false
    var onCapture: ((UInt32, UInt32) -> Void)?
    /// Track which modifiers are currently held for modifier-only detection.
    private var heldModifiers: UInt32 = 0
    private var modifierStableTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let mods = carbonModifiers(from: event.modifierFlags)
        // Require at least one modifier key
        guard mods != 0 else { return }
        // Ignore bare modifier keys (Shift, Ctrl, etc. without a letter)
        guard event.keyCode != 0xFF else { return }

        modifierStableTimer?.invalidate()
        modifierStableTimer = nil
        onCapture?(UInt32(event.keyCode), mods)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording, allowModifierOnly else { return }

        let mods = carbonModifiers(from: event.modifierFlags)

        // Need at least 2 modifier keys for a modifier-only shortcut
        let modCount = [
            mods & UInt32(controlKey),
            mods & UInt32(optionKey),
            mods & UInt32(shiftKey),
            mods & UInt32(cmdKey)
        ].filter { $0 != 0 }.count

        modifierStableTimer?.invalidate()
        modifierStableTimer = nil

        if modCount >= 2 {
            heldModifiers = mods
            // Wait briefly to confirm the user isn't still adding modifiers
            modifierStableTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, self.isRecording else { return }
                // keyCode 0 signals modifier-only shortcut
                self.onCapture?(0, self.heldModifiers)
            }
        } else {
            heldModifiers = 0
        }
    }
}
