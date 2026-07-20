import AppKit
import SwiftUI
import Combine
import UserNotifications

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var currentPanel: ResultPanel?
    private let recordingIndicator = RecordingIndicatorPanel()
    private let inlineProgress = InlineProgressPanel()
    private var silenceTimer: Timer?
    private var recordingStartTime: Date?
    private var hasReceivedSpeech = false
    private var isHandsFreeMode = false
    private var isFinishingHandsFree = false
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        setupHotkeys()
        observeShortcutChanges()

        if !AccessibilityService.isTrusted() {
            AccessibilityService.requestPermission()
        }

        // Pre-load STT model for instant recording start
        SpeechService.shared.preloadModel()

        // Pre-build recording indicator panel for instant display
        recordingIndicator.prebuild()

        // Pre-warm the on-device LLM so the first rewrite is instant rather
        // than paying the ~10 s GGUF mmap + Metal kernel compilation cost.
        // Periodic keep-alive runs from inside the actor after this.
        if Settings.shared.llmProvider == .embedded && Settings.shared.keepModelLoaded {
            Task { await EmbeddedLLMService.shared.prewarm() }
        }

        // Launcher (Carbon-hotkey based). install() registers the event
        // handler + every binding from Settings, no-op if disabled.
        if Settings.shared.launcherEnabled {
            LauncherEngine.shared.install()
        }

        // Meeting auto-detection (notify-and-confirm). Handles its own timer
        // and no-ops when the setting is off.
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { MeetingWatcher.shared.syncWithSettings() }
        observeMeetingAutoDetectChanges()

        // Show onboarding wizard on first launch
        if !Settings.shared.hasCompletedOnboarding {
            DispatchQueue.main.async {
                OnboardingWindow.show()
            }
        }
    }

    private func observeMeetingAutoDetectChanges() {
        Settings.shared.$meetingAutoDetectEnabled
            .receive(on: RunLoop.main)
            .sink { _ in
                Task { @MainActor in MeetingWatcher.shared.syncWithSettings() }
            }
            .store(in: &cancellables)
    }

    private func setupMainMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png"),
               let source = NSImage(contentsOf: iconURL) {
                let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
                    source.draw(in: NSRect(x: 0, y: 1, width: 18, height: 17))
                    return true
                }
                image.isTemplate = true
                button.image = image
            }
            button.action = #selector(togglePopover)
            button.target = self
        }

    }

    private func setupHotkeys() {
        let settings = Settings.shared
        HotkeyManager.shared.register(
            grammar: settings.grammarShortcut,
            rewrite: settings.rewriteShortcut,
            stt: settings.sttShortcut,
            handsFree: settings.handsFreeShortcut,
            onGrammar: { [weak self] in self?.handleGrammarHotkey() },
            onRewrite: { [weak self] in self?.handleRewriteHotkey() },
            onSTTStart: { [weak self] in self?.handleSTTStart() },
            onSTTStop: { [weak self] in self?.handleSTTStop() },
            onHandsFree: { [weak self] in self?.enterHandsFreeMode() },
            onSTTHoldTransition: { [weak self] in self?.transitionToHandsFree() }
        )
    }

    private func observeShortcutChanges() {
        let settings = Settings.shared
        Publishers.CombineLatest4(
            settings.$grammarShortcut,
            settings.$rewriteShortcut,
            settings.$sttShortcut,
            settings.$handsFreeShortcut
        )
        .dropFirst()
        .sink { grammar, rewrite, stt, handsFree in
            HotkeyManager.shared.updateShortcuts(grammar: grammar, rewrite: rewrite, stt: stt, handsFree: handsFree)
        }
        .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        let menu = NSMenu()
        let settings = Settings.shared

        // Rewrite Selection — top section, one item per configured mode.
        // Clicking grabs the current AX selection from the foreground app
        // and opens the same result panel as the global hotkey. Status
        // menus on LSUIElement apps don't change the systemwide
        // foreground, so the source app's selection stays readable while
        // our menu is open.
        let modes = settings.rewriteModes
        if !modes.isEmpty {
            let rewriteSubmenu = NSMenu()
            let rewriteItem = NSMenuItem(title: "Rewrite Selection", action: nil, keyEquivalent: "")
            rewriteItem.image = NSImage(
                systemSymbolName: "text.badge.checkmark",
                accessibilityDescription: "Rewrite"
            )
            for mode in modes {
                let item = NSMenuItem(
                    title: mode.name,
                    action: #selector(runRewriteMode(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mode.id
                rewriteSubmenu.addItem(item)
            }
            rewriteItem.submenu = rewriteSubmenu
            menu.addItem(rewriteItem)
            menu.addItem(.separator())
        }

        // Model submenu — only meaningful for the remote provider. For
        // the embedded provider the model is picked in Settings (a fixed
        // short list of GGUFs), so we hide the submenu entirely to keep
        // the menu uncluttered.
        if settings.llmProvider == .remote {
            let modelMenu = NSMenu()
            let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
            LLMService.shared.fetchModels { models in
                DispatchQueue.main.async {
                    modelMenu.removeAllItems()
                    if models.isEmpty {
                        let item = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
                        item.isEnabled = false
                        modelMenu.addItem(item)
                    } else {
                        for model in models {
                            let item = NSMenuItem(title: model, action: #selector(self.selectModel(_:)), keyEquivalent: "")
                            item.target = self
                            item.representedObject = model
                            if model == settings.modelName {
                                item.state = .on
                            }
                            modelMenu.addItem(item)
                        }
                    }
                }
            }
            // Add current model as placeholder while loading
            if !settings.modelName.isEmpty {
                let placeholder = NSMenuItem(title: settings.modelName, action: nil, keyEquivalent: "")
                placeholder.state = .on
                modelMenu.addItem(placeholder)
            }
            modelItem.submenu = modelMenu
            menu.addItem(modelItem)
        }

        // Microphone submenu
        let micMenu = NSMenu()
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let defaultMicItem = NSMenuItem(title: "System Default", action: #selector(selectMic(_:)), keyEquivalent: "")
        defaultMicItem.target = self
        defaultMicItem.representedObject = ""
        if settings.selectedMicUID.isEmpty {
            defaultMicItem.state = .on
        }
        micMenu.addItem(defaultMicItem)
        micMenu.addItem(.separator())

        let devices = SpeechService.availableInputDevices()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            if device.uid == settings.selectedMicUID {
                item.state = .on
            }
            micMenu.addItem(item)
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let historyEntries = TranscriptionHistory.shared.entries
        if !historyEntries.isEmpty {
            let historyMenu = NSMenu()
            let historyItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
            historyItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Recent Transcriptions")

            for entry in historyEntries {
                let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ")
                let label = oneLine.count > 50 ? String(oneLine.prefix(50)) + "…" : oneLine
                let item = NSMenuItem(title: label, action: #selector(copyTranscription(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                historyMenu.addItem(item)
            }

            historyMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearTranscriptionHistory), keyEquivalent: "")
            clearItem.target = self
            historyMenu.addItem(clearItem)

            historyItem.submenu = historyMenu
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())

        // LLM status row — text + meaning depends on the active provider.
        // Embedded: query the actor for the current load state. Remote:
        // probe the server's model list.
        let statusItem = NSMenuItem(title: "LLM: \u{2026}", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        switch settings.llmProvider {
        case .embedded:
            statusItem.title = "Gemma 4: \u{2026}"
            Task {
                let status = await EmbeddedLLMService.shared.status
                await MainActor.run {
                    statusItem.title = "Gemma 4: \(Self.embeddedStatusText(status))"
                }
            }
        case .remote:
            statusItem.title = "LLM: Disconnected"
            LLMService.shared.fetchModels { models in
                DispatchQueue.main.async {
                    statusItem.title = models.isEmpty ? "LLM: Disconnected" : "LLM: Connected"
                }
            }
        }

        let accText = AccessibilityService.isTrusted() ? "Accessibility: OK" : "Accessibility: Required"
        let accItem = NSMenuItem(title: accText, action: nil, keyEquivalent: "")
        accItem.isEnabled = false
        menu.addItem(accItem)

        menu.addItem(.separator())

        let settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settingsMenuItem.target = self
        settingsMenuItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        menu.addItem(settingsMenuItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        if let model = sender.representedObject as? String {
            Settings.shared.modelName = model
        }
    }

    /// Short, human-friendly label for the embedded model's runtime state,
    /// used by the menu-bar status row.
    private static func embeddedStatusText(_ status: EmbeddedModelStatus) -> String {
        switch status {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .downloaded: return "Downloaded"
        case .loading: return "Loading\u{2026}"
        case .ready: return "Ready"
        case .error: return "Error"
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        Settings.shared.selectedMicUID = (sender.representedObject as? String) ?? ""
    }

    @objc private func copyTranscription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearTranscriptionHistory() {
        TranscriptionHistory.shared.clear()
    }

    @objc private func openSettingsMenu() {
        SettingsWindow.show()
    }


    private func handleGrammarHotkey() {
        guard AccessibilityService.isTrusted() else {
            AccessibilityService.requestPermission()
            return
        }

        guard let text = AccessibilityService.shared.getSelectedText(), !text.isEmpty else {
            NSSound.beep()
            return
        }

        let selectionRect = AccessibilityService.shared.getSelectionRect()
        let settings = Settings.shared
        let mode = settings.rewriteModes.first(where: { $0.id == settings.defaultModeId })
            ?? settings.rewriteModes[0]
        let prompt = Prompts.rewrite(mode: mode, text: text)

        // Anchor a small "Fixing grammar…" shimmer next to the selection so
        // the user sees the hotkey was received. This is the only rewrite
        // path that writes back without any other UI; everything else
        // (Rewrite hotkey, voice) already shows a panel of its own.
        inlineProgress.show(at: selectionRect, label: "Polishing\u{2026}")

        LLMService.shared.generate(prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                self?.inlineProgress.close()
                switch result {
                case .success(let corrected):
                    AccessibilityService.shared.replaceTextInSourceApp(corrected, originalText: text)
                case .failure:
                    NSSound.beep()
                }
            }
        }
    }

    private func handleRewriteHotkey() {
        guard AccessibilityService.isTrusted() else {
            AccessibilityService.requestPermission()
            return
        }

        // Try explicit selection first; fall back to paragraph around cursor.
        let text: String?
        let wasSelected: Bool
        if let selected = AccessibilityService.shared.getSelectedText(), !selected.isEmpty {
            text = selected
            wasSelected = true
        } else if let paragraph = AccessibilityService.shared.getTextAroundCursor(), !paragraph.isEmpty {
            text = paragraph
            wasSelected = false
        } else {
            return
        }

        let selectionRect = AccessibilityService.shared.getSelectionRect()
        guard let initialMode = defaultRewriteMode() else { return }

        runRewrite(text: text, initialMode: initialMode, near: selectionRect, wasSelected: wasSelected)
    }

    /// Resolve the mode to start with: the user's chosen default if set,
    /// otherwise the first mode in the list. Returns nil only when the
    /// mode list is unexpectedly empty.
    private func defaultRewriteMode() -> RewriteMode? {
        let settings = Settings.shared
        let modes = settings.rewriteModes
        guard !modes.isEmpty else { return nil }
        if let modeId = settings.defaultModeId,
           let mode = modes.first(where: { $0.id == modeId }) {
            return mode
        }
        return modes[0]
    }

    /// Shared rewrite pipeline used by both the global hotkey and the
    /// menu-bar "Rewrite Selection" entries. `selectionRect` is the
    /// on-screen anchor used for panel placement — pass `.zero` if you
    /// don't have one and the panel falls back to the mouse-cursor
    /// position. `wasSelected` indicates whether the text came from an
    /// explicit selection (true) or from paragraph extraction around the
    /// cursor (false). This affects how the replacement is performed.
    private func runRewrite(text: String, initialMode: RewriteMode, near selectionRect: NSRect, wasSelected: Bool = true) {
        let modes = Settings.shared.rewriteModes
        guard !modes.isEmpty else { return }

        currentPanel?.close()

        let panel = ResultPanel(modes: modes)
        currentPanel = panel

        // Shared helper — same stream/append/complete plumbing for both
        // the initial mode run and the follow-up refinement runs.
        func streamPrompt(_ prompt: String) {
            let modelName = LLMService.activeModelLabel
            let handle = LLMService.shared.generateStream(
                prompt: prompt,
                onChunk: { chunk in
                    panel.appendChunk(chunk, modelName: modelName)
                },
                onComplete: { result in
                    switch result {
                    case .success:
                        panel.completeStream(modelName: modelName)
                    case .failure(let err):
                        panel.updateError(err.localizedDescription)
                    }
                }
            )
            panel.setActiveStream(handle)
        }

        func runMode(_ mode: RewriteMode) {
            streamPrompt(Prompts.rewrite(mode: mode, text: text))
        }

        func runRefine(previousText: String, instruction: String) {
            streamPrompt(Prompts.refine(
                previousOutput: previousText,
                instruction: instruction
            ))
        }

        panel.show(
            near: selectionRect,
            initialMode: initialMode,
            onModeSelected: { mode in
                runMode(mode)
            },
            onReplace: { [weak self] result in
                self?.currentPanel = nil
                if wasSelected {
                    AccessibilityService.shared.replaceTextInSourceApp(result, originalText: text)
                } else {
                    AccessibilityService.shared.replaceParagraph(result, originalText: text)
                }
            },
            onCopy: { [weak self] result in
                self?.currentPanel = nil
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            },
            onRefine: { previous, instruction in
                runRefine(previousText: previous, instruction: instruction)
            }
        )

        runMode(initialMode)
    }

    /// Menu-bar action: user picked a Rewrite mode from the status-item
    /// dropdown. Mirrors the global rewrite hotkey path but uses the
    /// clicked mode as the initial selection. Falls back to a beep if no
    /// text is currently selected in the source app.
    @objc private func runRewriteMode(_ sender: NSMenuItem) {
        guard let modeID = sender.representedObject as? UUID,
              let mode = Settings.shared.rewriteModes.first(where: { $0.id == modeID })
        else { return }

        guard AccessibilityService.isTrusted() else {
            AccessibilityService.requestPermission()
            return
        }

        guard let text = AccessibilityService.shared.getSelectedText(), !text.isEmpty else {
            NSSound.beep()
            return
        }

        let rect = AccessibilityService.shared.getSelectionRect()
        runRewrite(text: text, initialMode: mode, near: rect, wasSelected: true)
    }

    // MARK: - Speech-to-Text

    private func handleSTTStart() {
        // If in hands-free mode, pressing STT shortcut again stops it
        if isHandsFreeMode {
            finishHandsFreeRecording()
            return
        }

        _ = beginSTTSession()
    }

    @discardableResult
    private func beginSTTSession() -> Bool {
        resetVoiceSessionUI()

        guard AccessibilityService.isTrusted() else {
            AccessibilityService.requestPermission()
            return false
        }

        // Capture source app PID before we do anything
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            AccessibilityService.shared.sourceAppPID = frontApp.processIdentifier
            NSLog("[voice-insert] beginSTTSession captured sourceAppPID=\(frontApp.processIdentifier) name=\(frontApp.localizedName ?? "?")")
        } else {
            NSLog("[voice-insert] beginSTTSession: no frontmostApplication; sourceAppPID=\(AccessibilityService.shared.sourceAppPID)")
        }

        // Show recording indicator
        recordingIndicator.show()
        recordingStartTime = Date()
        hasReceivedSpeech = false

        // Silence detection: warn if no speech after 6 seconds
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            guard let self, !self.hasReceivedSpeech else { return }
            self.recordingIndicator.showWarning("No voice detected. Check your mic.")
        }

        // Configure speech service callbacks
        let speech = SpeechService.shared

        speech.onAudioLevel = { [weak self] level in
            self?.recordingIndicator.updateAudioLevel(level)
        }

        speech.onPartialResult = { [weak self] text in
            guard let self else { return }
            self.hasReceivedSpeech = true
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
            self.recordingIndicator.updatePartialText(text)
        }

        speech.onError = { [weak self] error in
            self?.resetVoiceModeState()
            self?.resetVoiceSessionUI()
            NSSound.beep()
        }

        speech.startRecording()
        return true
    }

    private func handleSTTStop() {
        if isHandsFreeMode { return }
        handleSTTStopInternal()
    }

    private func handleSTTStopInternal() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Show processing immediately on button release
        recordingIndicator.showStage("Drafting…")

        let speech = SpeechService.shared

        speech.onFinalResult = { [weak self] transcribedText in
            guard let self else { return }
            NSLog("[voice-insert] onFinalResult len=\(transcribedText.count) sourceAppPID=\(AccessibilityService.shared.sourceAppPID)")
            TranscriptionHistory.shared.add(transcribedText)

            let settings = Settings.shared

            let userPrompt = settings.voicePostProcessPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip the LLM entirely for short, filler-free utterances —
            // the STT engine already produced them cleanly, and the
            // ~300–800 ms round-trip would be wasted latency.
            let needsCleanup = VoiceHeuristics.needsCleanup(transcribedText)

            if settings.voicePostProcessEnabled && !userPrompt.isEmpty && needsCleanup {
                self.recordingIndicator.showStage("Cleaning…")

                let prompt = Prompts.voicePostProcess(
                    prompt: userPrompt,
                    transcript: transcribedText
                )

                LLMService.shared.generate(prompt: prompt) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let corrected):
                            AccessibilityService.shared.insertTextInSourceApp(corrected)
                            self.recordingIndicator.close()
                        case .failure:
                            NSSound.beep()
                            self.recordingIndicator.close()
                        }
                    }
                }
            } else {
                AccessibilityService.shared.insertTextInSourceApp(transcribedText)
                self.recordingIndicator.close()
            }
        }

        speech.stopRecording()
    }

    // MARK: - Hands-Free Mode

    private func enterHandsFreeMode() {
        // If already in hands-free mode, pressing the shortcut again stops it
        if isHandsFreeMode {
            finishHandsFreeRecording()
            return
        }

        guard beginSTTSession() else { return }

        isHandsFreeMode = true
        recordingIndicator.showHandsFree { [weak self] in
            self?.finishHandsFreeRecording()
        }
        SpeechService.shared.disableSafetyTimer()
    }

    private func transitionToHandsFree() {
        isHandsFreeMode = true
        recordingIndicator.showHandsFree { [weak self] in
            self?.finishHandsFreeRecording()
        }
        SpeechService.shared.disableSafetyTimer()
    }

    private func finishHandsFreeRecording() {
        guard !isFinishingHandsFree else { return }
        isFinishingHandsFree = true
        isHandsFreeMode = false
        // Close the panel first to release key window status (clicking the
        // Finish button makes the panel key, which misdirects simulated Cmd+V).
        recordingIndicator.close()
        let pid = AccessibilityService.shared.sourceAppPID
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            usleep(100_000)
        }
        // Re-show panel with processing indicator -- it stays visible
        // until text is fully inserted into the source app.
        recordingIndicator.show()
        recordingIndicator.showStage("Drafting…")
        handleSTTStopInternal()
        isFinishingHandsFree = false
    }

    private func resetVoiceModeState() {
        isHandsFreeMode = false
        isFinishingHandsFree = false
    }

    private func resetVoiceSessionUI() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recordingIndicator.close()
    }

}

// MARK: - Meeting detection notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Show the banner even when the app is frontmost.
    @objc nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    @objc nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor in
            switch actionID {
            case MeetingWatcher.startActionID, UNNotificationDefaultActionIdentifier:
                SettingsWindow.show()
                NotificationCenter.default.post(name: .rewriteShowMeetingsTab, object: nil)
                MeetingTranscriber.shared.start()
            default:
                break
            }
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let rewriteShowMeetingsTab = Notification.Name("rewriteShowMeetingsTab")
}
