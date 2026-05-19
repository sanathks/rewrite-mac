import AppKit
import SwiftUI

/// Settings → Launcher tab. Configures the hold-prefix-then-key shortcut
/// system handled by `LauncherEngine`.
struct LauncherSettingsTab: View {
    @ObservedObject private var settings = Settings.shared
    /// Binding currently in the "press a key" capture mode.
    @State private var capturingForBindingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Launcher")
                .font(.title2)
                .fontWeight(.semibold)

            Toggle("Enable launcher", isOn: $settings.launcherEnabled)
                .toggleStyle(.switch)
                .onChange(of: settings.launcherEnabled) { enabled in
                    if enabled {
                        LauncherEngine.shared.install()
                    } else {
                        LauncherEngine.shared.uninstall()
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Prefix key")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.launcherPrefixKey) {
                    ForEach(LauncherPrefixKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .onChange(of: settings.launcherPrefixKey) { _ in
                    LauncherEngine.shared.reload()
                }
                Text("Hold this key, then press a shortcut to launch the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("Shortcuts")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    addBinding()
                } label: {
                    Label("Add Shortcut…", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if settings.launcherBindings.isEmpty {
                Text("No shortcuts yet. Click Add Shortcut to pick an app and bind a key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(settings.launcherBindings) { binding in
                        bindingRow(binding)
                    }
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func bindingRow(_ binding: LauncherBinding) -> some View {
        HStack(spacing: 12) {
            Button {
                capturingForBindingID = binding.id
            } label: {
                Text(capturingForBindingID == binding.id ? "Press a key…" : binding.triggerKey.uppercased())
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(capturingForBindingID == binding.id
                                  ? Color.accentColor.opacity(0.3)
                                  : Color.gray.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .background(
                KeyCaptureBridge(isCapturing: capturingForBindingID == binding.id) { key in
                    apply(triggerKey: key, to: binding.id)
                }
            )

            AppIconView(url: binding.appURL)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(binding.displayName)
                    .font(.body)
                Text(binding.appURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                remove(binding.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func addBinding() {
        let panel = NSOpenPanel()
        panel.title = "Select an application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier ?? ""
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let binding = LauncherBinding(
            triggerKey: "",
            appBundleID: bundleID,
            appURL: url,
            displayName: name
        )
        settings.launcherBindings.append(binding)
        capturingForBindingID = binding.id
        LauncherEngine.shared.reload()
    }

    private func remove(_ id: UUID) {
        settings.launcherBindings.removeAll { $0.id == id }
        if capturingForBindingID == id { capturingForBindingID = nil }
        LauncherEngine.shared.reload()
    }

    private func apply(triggerKey: String, to id: UUID) {
        let key = triggerKey.lowercased()
        // Refuse if another binding already uses this key.
        if settings.launcherBindings.contains(where: { $0.id != id && $0.triggerKey == key }) {
            NSSound.beep()
            return
        }
        if let index = settings.launcherBindings.firstIndex(where: { $0.id == id }) {
            settings.launcherBindings[index].triggerKey = key
        }
        capturingForBindingID = nil
        LauncherEngine.shared.reload()
    }
}

// MARK: - Helpers

/// Renders the file icon for the bound application via NSWorkspace.
private struct AppIconView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSWorkspace.shared.icon(forFile: url.path)
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Captures a single keypress inside a SwiftUI view. Used to let the user
/// pick the chord key by literally pressing it once.
private struct KeyCaptureBridge: NSViewRepresentable {
    let isCapturing: Bool
    let onCapture: (String) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        if isCapturing {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, let first = chars.first else { return }
        // Ignore non-letter / non-digit / non-symbol keys (Esc, arrows…).
        if first.isLetter || first.isNumber || first.isPunctuation {
            onCapture?(String(first))
        }
    }
}
