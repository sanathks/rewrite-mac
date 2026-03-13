import AppKit
import SwiftUI
import ServiceManagement

final class SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsContentView()
            .preferredColorScheme(.dark)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Rewrite Settings"
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 620, height: 440))
        win.center()
        win.appearance = NSAppearance(named: .darkAqua)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.toolbar?.isVisible = false

        window = win
    }
}

// MARK: - Sidebar Navigation

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case modes
    case shortcuts
    case voice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .modes: return "Modes"
        case .shortcuts: return "Shortcuts"
        case .voice: return "Voice"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .modes: return "text.badge.star"
        case .shortcuts: return "keyboard"
        case .voice: return "mic"
        }
    }
}

// MARK: - Root View

private struct SettingsContentView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var isConnected = false
    @State private var hasAccessibility = false
    @State private var hasMicrophone = false
    @State private var isModelDownloaded = false
    @State private var isDownloadingModel = false
    @State private var downloadProgress: Double = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var audioDevices: [(id: UInt32, name: String)] = []
    @State private var selectedTab: SettingsTab = .general
    private let recommendedModelName = "gemma3:4b"

    private var engineDescription: String {
        switch settings.sttEngine {
        case .whisperKit:
            return "OpenAI Whisper on Apple Neural Engine. Streams words as you speak. Great multilingual accuracy with larger models."
        case .parakeet:
            return "NVIDIA Parakeet TDT. Best English accuracy (~6% WER), 10x faster than Whisper. Transcribes after recording ends (no live preview). Supports custom vocabulary boosting."
        }
    }

    private var needsOnboarding: Bool {
        !hasAccessibility || !isConnected
    }

    private func modelLabel(for model: String) -> String {
        model == recommendedModelName ? "\(model) (Recommended)" : model
    }

    private var recommendedModelHint: String {
        if availableModels.contains(recommendedModelName) {
            return "Recommended: \(recommendedModelName)"
        }
        return "Recommended: \(recommendedModelName) if available in Ollama"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsTab.allCases, selection: $selectedTab) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                Divider()

                // Status footer - always visible
                VStack(alignment: .leading, spacing: 6) {
                    StatusRow(
                        label: "LLM Server",
                        isOK: isConnected,
                        okText: "Connected",
                        failText: "Disconnected"
                    )
                    StatusRow(
                        label: "Accessibility",
                        isOK: hasAccessibility,
                        okText: "Granted",
                        failText: "Required"
                    )
                    StatusRow(
                        label: "Microphone",
                        isOK: hasMicrophone,
                        okText: "Granted",
                        failText: "Not granted"
                    )
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 170, max: 200)
        } detail: {
            if needsOnboarding {
                onboardingView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            } else {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 620, height: 440)
        .onAppear {
            loadModels()
            hasAccessibility = AccessibilityService.isTrusted()
            hasMicrophone = SpeechService.hasMicrophonePermission
            checkModelStatus()
            audioDevices = SpeechService.availableInputDevices()
        }
    }

    // MARK: - Onboarding

    private var onboardingView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Welcome to Rewrite")
                .font(.title)
                .fontWeight(.bold)

            Text("Complete the setup below to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                // Step 1: Accessibility
                OnboardingStep(
                    number: 1,
                    title: "Grant Accessibility Permission",
                    description: "Rewrite needs Accessibility access to read and replace text in other apps.",
                    isComplete: hasAccessibility
                ) {
                    if !hasAccessibility {
                        HStack(spacing: 8) {
                            Button("Open System Settings") {
                                AccessibilityService.requestPermission()
                            }
                            .controlSize(.small)
                            Button("Check Again") {
                                hasAccessibility = AccessibilityService.isTrusted()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                // Step 2: LLM Server
                OnboardingStep(
                    number: 2,
                    title: "Connect to LLM Server",
                    description: "Install Ollama or LM Studio and start the server.",
                    isComplete: isConnected
                ) {
                    if !isConnected {
                        HStack(spacing: 8) {
                            TextField("http://localhost:11434", text: $settings.serverURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Button("Connect") {
                                loadModels()
                            }
                            .controlSize(.small)
                            .disabled(isLoadingModels)
                            if isLoadingModels {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Spacer()

            if hasAccessibility && isConnected {
                Text("Setup complete. Select a section from the sidebar to configure settings.")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .modes:
            modesTab
        case .shortcuts:
            shortcutsTab
        case .voice:
            voiceTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server URL")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack {
                    TextField("http://localhost:11434", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        loadModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(isLoadingModels)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if availableModels.isEmpty {
                    HStack(spacing: 6) {
                        TextField("gemma3:4b", text: $settings.modelName)
                            .textFieldStyle(.roundedBorder)
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } else {
                    Picker("", selection: $settings.modelName) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(modelLabel(for: model)).tag(model)
                        }
                    }
                    .labelsHidden()

                    Text(recommendedModelHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Spacer()
        }
    }

    // MARK: - Modes

    private var modesTab: some View {
        RewriteModesView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Shortcuts")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Click a shortcut to change it")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                ShortcutRecorder(label: "Quick Fix", shortcut: $settings.grammarShortcut)
                ShortcutRecorder(label: "Rewrite Modes", shortcut: $settings.rewriteShortcut)
                ShortcutRecorder(label: "Voice Input", shortcut: $settings.sttShortcut, allowModifierOnly: true)
                ShortcutRecorder(label: "Hands-Free Voice", shortcut: $settings.handsFreeShortcut)
            }

            Spacer()
        }
    }

    // MARK: - Voice

    private var voiceTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Voice Input")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Engine")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $settings.sttEngine) {
                        ForEach(STTEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: settings.sttEngine) { _ in
                        checkModelStatus()
                    }
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding(.top, 1)
                    Text(engineDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.sttEngine == .whisperKit {
                    HStack {
                        Text("Model")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $settings.whisperModelSize) {
                            ForEach(WhisperModelSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .onChange(of: settings.whisperModelSize) { _ in
                            checkModelStatus()
                        }
                    }
                } else {
                    HStack {
                        Text("Model")
                            .font(.subheadline)
                        Spacer()
                        Text("Parakeet TDT 0.6B INT8 (~640 MB)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Circle()
                        .fill(isModelDownloaded ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(isModelDownloaded ? "Model Ready" : "Model Not Downloaded")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if !isModelDownloaded {
                        if isDownloadingModel {
                            ProgressView(value: downloadProgress)
                                .frame(width: 80)
                                .controlSize(.small)
                        } else {
                            Button("Download") {
                                downloadModel()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                HStack {
                    Text("Microphone")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $settings.selectedMicDeviceID) {
                        Text("System Default").tag(UInt32(0))
                        ForEach(audioDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Toggle("Auto Grammar Fix", isOn: $settings.autoGrammarOnSTT)
                    .toggleStyle(.switch)

                HStack {
                    Circle()
                        .fill(hasMicrophone ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(hasMicrophone ? "Microphone OK" : "Microphone Required")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if !hasMicrophone {
                        Spacer()
                        Button("Grant") {
                            SpeechService.requestMicrophonePermission { granted in
                                hasMicrophone = granted
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Spacer()
        }
        }
    }

    // MARK: - Helpers

    private func loadModels() {
        isLoadingModels = true
        LLMService.shared.fetchModels { models in
            DispatchQueue.main.async {
                availableModels = models
                isConnected = !models.isEmpty
                isLoadingModels = false
                if !models.isEmpty && !models.contains(settings.modelName) {
                    settings.modelName = models[0]
                }
            }
        }
    }

    private func checkModelStatus() {
        isModelDownloaded = SpeechService.isModelReady()
    }

    private func downloadModel() {
        isDownloadingModel = true
        downloadProgress = 0
        SpeechService.downloadModel(
            progress: { progress in
                downloadProgress = progress
            },
            completion: { result in
                isDownloadingModel = false
                switch result {
                case .success:
                    checkModelStatus()
                case .failure:
                    break
                }
            }
        )
    }
}

// MARK: - Status Row

private struct StatusRow: View {
    let label: String
    let isOK: Bool
    let okText: String
    let failText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOK ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text(isOK ? okText : failText)
                .font(.caption2)
                .foregroundColor(isOK ? .green.opacity(0.8) : .red.opacity(0.8))
        }
    }
}

// MARK: - Onboarding Step

private struct OnboardingStep<Actions: View>: View {
    let number: Int
    let title: String
    let description: String
    let isComplete: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : Color.accentColor)
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .strikethrough(isComplete)
                    .foregroundColor(isComplete ? .secondary : .primary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                actions()
                    .padding(.top, 4)
            }
        }
    }
}
