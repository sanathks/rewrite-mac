import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var isConnected = false
    @State private var hasAccessibility = false
    @State private var audioDevices: [(id: UInt32, name: String)] = []
    @State private var availableModels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rewrite")
                .font(.headline)

            Divider()

            // LLM Model picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if availableModels.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("Not connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Picker("", selection: $settings.modelName) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Microphone picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Microphone")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.selectedMicDeviceID) {
                    Text("System Default").tag(UInt32(0))
                    ForEach(audioDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            Divider()

            HStack {
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(isConnected ? "Connected" : "Disconnected")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Circle()
                    .fill(hasAccessibility ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(hasAccessibility ? "Accessibility" : "No Access")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Button("Settings...") {
                    SettingsWindow.show()
                }
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
                        panel.orderOut(nil)
                    }
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear {
            hasAccessibility = AccessibilityService.isTrusted()
            audioDevices = SpeechService.availableInputDevices()
            LLMService.shared.fetchModels { models in
                DispatchQueue.main.async {
                    availableModels = models
                    isConnected = !models.isEmpty
                }
            }
        }
    }
}
