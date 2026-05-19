import AppKit
import SwiftUI

/// Settings → Launcher tab. Configures modifier-prefix + key chord
/// shortcuts handled by `LauncherEngine`.
struct LauncherSettingsTab: View {
    @ObservedObject private var settings = Settings.shared
    /// Binding currently in "press a key" capture mode.
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
                Text("Prefix")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.launcherPrefix) {
                    ForEach(LauncherPrefix.allCases) { prefix in
                        Text(prefix.displayName).tag(prefix)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: settings.launcherPrefix) { _ in
                    LauncherEngine.shared.reload()
                }
                Text("Hold this modifier combination, then press a shortcut key to launch the app.")
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
                    Label("Add Shortcut\u{2026}", systemImage: "plus")
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
                Text(capturingForBindingID == binding.id ? "Press a key\u{2026}" : binding.triggerKey.uppercased())
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
        // Restrict to letters / digits to match the LauncherEngine keycode
        // table. Anything else is silently ignored.
        if first.isLetter || first.isNumber {
            onCapture?(String(first))
        }
    }
}
