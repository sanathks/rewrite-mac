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
        // Give the window an empty toolbar so NavigationSplitView can anchor
        // its sidebar-toggle button and properly reserve the title-bar safe
        // area on first render. Without this, the sidebar starts flush to
        // the top of the window and overlaps the traffic-light buttons
        // until a tab switch forces a relayout.
        let toolbar = NSToolbar(identifier: "RewriteSettingsToolbar")
        toolbar.displayMode = .iconOnly
        win.toolbar = toolbar
        win.toolbarStyle = .unified
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}

// MARK: - Sidebar Navigation

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case modes
    case shortcuts
    case voice
    case launcher

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .modes: return "Modes"
        case .shortcuts: return "Shortcuts"
        case .voice: return "Voice"
        case .launcher: return "Launcher"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .modes: return "text.badge.star"
        case .shortcuts: return "keyboard"
        case .voice: return "mic"
        case .launcher: return "bolt.fill"
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
    @State private var embeddedStatus: EmbeddedModelStatus = .notDownloaded
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var audioDevices: [(id: UInt32, uid: String, name: String)] = []
    @State private var selectedTab: SettingsTab = .general
    /// Token for our EmbeddedLLMService status subscription so we can
    /// unsubscribe on .onDisappear; otherwise a stale observer is left on
    /// the singleton each time the Settings window closes.
    @State private var embeddedStatusObserverID: UUID?
    /// Binding NavigationSplitView's column visibility to SwiftUI state is
    /// what makes SwiftUI register the sidebar-toggle toolbar item on
    /// initial render. Without an explicit binding the toggle only
    /// appears after the first tab switch triggers a layout pass.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let recommendedModelName = "gemma3:4b"

    private let engineDescription =
        "NVIDIA Parakeet TDT. Best English accuracy (~6% WER), fast on Apple Silicon. Transcribes after recording ends. Supports custom vocabulary boosting."

    private var isLLMReady: Bool {
        switch settings.llmProvider {
        case .remote: return isConnected
        case .embedded:
            switch embeddedStatus {
            case .downloaded, .ready, .loading: return true
            default: return false
            }
        }
    }

    private var needsOnboarding: Bool {
        !hasAccessibility || !isLLMReady
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                        label: settings.llmProvider == .embedded ? "Gemma 4" : "LLM Server",
                        isOK: isLLMReady,
                        okText: settings.llmProvider == .embedded ? "Ready" : "Connected",
                        failText: settings.llmProvider == .embedded ? "Not downloaded" : "Disconnected"
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
            // Wrap in Group + .id() so SwiftUI rebuilds the detail subtree
            // when needsOnboarding flips. NavigationSplitView otherwise
            // fails to re-measure the column on detail content swaps and
            // renders the new content at zero size (blank panel).
            Group {
                if needsOnboarding {
                    onboardingView
                } else {
                    detailView
                }
            }
            .id(needsOnboarding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 620, minHeight: 440)
        .onAppear {
            loadModels()
            hasAccessibility = AccessibilityService.isTrusted()
            hasMicrophone = SpeechService.hasMicrophonePermission
            checkModelStatus()
            audioDevices = SpeechService.availableInputDevices()
            Task {
                let id = await EmbeddedLLMService.shared.observe { status in
                    embeddedStatus = status
                }
                embeddedStatusObserverID = id
            }
        }
        .onDisappear {
            if let id = embeddedStatusObserverID {
                Task { await EmbeddedLLMService.shared.unobserve(id) }
                embeddedStatusObserverID = nil
            }
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

                // Step 2: LLM (provider-aware)
                OnboardingStep(
                    number: 2,
                    title: settings.llmProvider == .embedded
                        ? "Download Gemma 4 model"
                        : "Connect to LLM Server",
                    description: settings.llmProvider == .embedded
                        ? "Run Gemma 4 on-device via llama.cpp. The model file is ~3–5 GB depending on the variant you pick."
                        : "Install Ollama or LM Studio and start the server.",
                    isComplete: isLLMReady
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Provider", selection: $settings.llmProvider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .onChange(of: settings.llmProvider) { provider in
                            if provider == .remote {
                                Task { await EmbeddedLLMService.shared.unload() }
                                loadModels()
                            } else {
                                Task {
                                    await EmbeddedLLMService.shared.refreshStatus()
                                    if Settings.shared.keepModelLoaded {
                                        await EmbeddedLLMService.shared.prewarm()
                                    }
                                }
                            }
                        }

                        if settings.llmProvider == .embedded {
                            Picker("Model", selection: $settings.embeddedModel) {
                                ForEach(EmbeddedLLMModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 360)
                            .onChange(of: settings.embeddedModel) { _ in
                                Task { await EmbeddedLLMService.shared.refreshStatus() }
                            }
                            embeddedStatusView
                        } else if !isConnected {
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
            }

            Spacer()

            if hasAccessibility && isLLMReady {
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
        case .launcher:
            LauncherSettingsTab()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Provider")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: settings.llmProvider) { provider in
                    if provider == .remote {
                        Task { await EmbeddedLLMService.shared.unload() }
                        loadModels()
                    } else {
                        Task {
                            await EmbeddedLLMService.shared.refreshStatus()
                            if Settings.shared.keepModelLoaded {
                                await EmbeddedLLMService.shared.prewarm()
                            }
                        }
                    }
                }
            }

            embeddedProviderSection

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

                HStack {
                    Text("Model")
                        .font(.subheadline)
                    Spacer()
                    Text("Parakeet TDT 0.6B INT8 (~640 MB)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
                    Picker("", selection: $settings.selectedMicUID) {
                        Text("System Default").tag("")
                        ForEach(audioDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Post-process transcript with LLM", isOn: $settings.voicePostProcessEnabled)
                        .toggleStyle(.switch)

                    Text("Pipes the raw transcript through the LLM using the prompt below. Useful for cleaning filler words, fixing punctuation, or any custom transformation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.voicePostProcessEnabled {
                        TextEditor(text: $settings.voicePostProcessPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120, maxHeight: 200)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )

                        HStack {
                            Spacer()
                            Button("Reset to default") {
                                settings.voicePostProcessPrompt = Settings.defaultVoicePostProcessPrompt
                            }
                            .controlSize(.small)
                            .disabled(settings.voicePostProcessPrompt == Settings.defaultVoicePostProcessPrompt)
                        }
                    }
                }

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

    // MARK: - Provider sections

    private var remoteProviderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        }
    }

    @ViewBuilder
    private var embeddedProviderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.embeddedModel) {
                    ForEach(EmbeddedLLMModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .onChange(of: settings.embeddedModel) { _ in
                    Task {
                        await EmbeddedLLMService.shared.unload()
                        await EmbeddedLLMService.shared.refreshStatus()
                        if Settings.shared.keepModelLoaded {
                            await EmbeddedLLMService.shared.prewarm()
                        }
                    }
                }
                Text("Runs on-device via llama.cpp on Metal. Weights download to ~/Library/Caches/models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep model loaded", isOn: $settings.keepModelLoaded)
                    .toggleStyle(.switch)
                    .onChange(of: settings.keepModelLoaded) { keep in
                        Task {
                            if keep {
                                await EmbeddedLLMService.shared.prewarm()
                            } else {
                                await EmbeddedLLMService.shared.unload()
                            }
                        }
                    }
                Text("Holds ~3–5 GB in memory and pings the model every two minutes so the first rewrite is instant. Turn off to free memory.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            embeddedStatusView
        }
    }

    @ViewBuilder
    private var embeddedStatusView: some View {
        switch embeddedStatus {
        case .notDownloaded:
            HStack(spacing: 8) {
                Button("Download Model") {
                    Task { await EmbeddedLLMService.shared.downloadSelectedModel() }
                }
                .controlSize(.small)
                Text("Not downloaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))% downloaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .downloaded:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Downloaded · ready to use")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model into memory…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .ready:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Loaded and ready")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
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
