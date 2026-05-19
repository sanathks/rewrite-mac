import AppKit
import SwiftUI

final class OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView()
            .preferredColorScheme(.dark)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 520, height: 440))
        win.center()
        win.appearance = NSAppearance(named: .darkAqua)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Onboarding View

private struct OnboardingView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var step = 0
    @State private var isConnected = false
    @State private var isLoadingModels = false
    @State private var availableModels: [String] = []
    @State private var hasAccessibility = false

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(totalSteps), height: 3)
                            .animation(.easeInOut(duration: 0.3), value: step)
                    }
            }
            .frame(height: 3)

            // Content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: accessibilityStep
                case 2: serverStep
                case 3: doneStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
        .frame(width: 520, height: 440)
        .onAppear {
            hasAccessibility = AccessibilityService.isTrusted()
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png"),
               let nsImage = NSImage(contentsOf: iconURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            VStack(spacing: 8) {
                Text("Welcome to Rewrite")
                    .font(.title)
                    .fontWeight(.bold)
                Text("System-wide grammar correction, text rewriting, and voice input -- powered by local LLMs.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Spacer()

            Button("Get Started") {
                withAnimation { step = 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Step 1: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("Accessibility Permission")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Rewrite needs Accessibility access to read selected text and replace it in any app. This stays on your Mac -- nothing is sent to the cloud.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if hasAccessibility {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.subheadline)
            } else {
                VStack(spacing: 12) {
                    Button("Open System Settings") {
                        AccessibilityService.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Check Again") {
                        hasAccessibility = AccessibilityService.isTrusted()
                    }
                    .controlSize(.small)
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            navigationButtons(canContinue: true)
        }
    }

    // MARK: - Step 2: Server

    private var serverStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("Connect to LLM Server")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Install Ollama or LM Studio on your Mac. Rewrite connects to your local server for all text processing.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(spacing: 12) {
                HStack {
                    TextField("http://localhost:11434", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Button(isLoadingModels ? "Connecting..." : "Connect") {
                        loadModels()
                    }
                    .controlSize(.regular)
                    .disabled(isLoadingModels)
                }

                if isConnected {
                    Label("Connected - \(availableModels.count) model(s) found", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.subheadline)

                    if !availableModels.isEmpty {
                        HStack {
                            Text("Model:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Picker("", selection: $settings.modelName) {
                                ForEach(availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                }
            }

            Spacer()

            navigationButtons(canContinue: true)
        }
    }

    // MARK: - Step 3: Done

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("You're All Set")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Here are your shortcuts to get started:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(
                    shortcut: settings.grammarShortcut.displayString,
                    description: "Fix grammar silently"
                )
                shortcutRow(
                    shortcut: settings.rewriteShortcut.displayString,
                    description: "Open rewrite popup"
                )
                shortcutRow(
                    shortcut: settings.sttShortcut.displayString,
                    description: "Hold to dictate"
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )

            Spacer()

            Button("Start Using Rewrite") {
                settings.hasCompletedOnboarding = true
                OnboardingWindow.close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Helpers

    private func shortcutRow(shortcut: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(shortcut)
                .font(.system(size: 14, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                )
                .frame(minWidth: 80)
            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func navigationButtons(canContinue: Bool) -> some View {
        HStack {
            if step > 0 {
                Button("Back") {
                    withAnimation { step -= 1 }
                }
                .controlSize(.regular)
            }

            Spacer()

            Button(step == 0 ? "Get Started" : "Continue") {
                withAnimation { step += 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!canContinue)
        }
    }

    private func loadModels() {
        isLoadingModels = true
        LLMService.shared.fetchModels { models in
            DispatchQueue.main.async {
                availableModels = models
                isConnected = !models.isEmpty
                isLoadingModels = false
                if !models.isEmpty && !models.contains(settings.modelName) {
                    settings.modelName = models.contains("gemma3:4b") ? "gemma3:4b" : models[0]
                }
            }
        }
    }
}
