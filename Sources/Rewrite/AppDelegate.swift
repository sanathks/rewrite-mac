import AppKit
import SwiftUI
import Combine

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var currentPanel: ResultPanel?
    private let recordingIndicator = RecordingIndicatorPanel()
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

        // Show onboarding wizard on first launch
        if !Settings.shared.hasCompletedOnboarding {
            DispatchQueue.main.async {
                OnboardingWindow.show()
            }
        }
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

        // Model submenu
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

        // Microphone submenu
        let micMenu = NSMenu()
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let defaultMicItem = NSMenuItem(title: "System Default", action: #selector(selectMic(_:)), keyEquivalent: "")
        defaultMicItem.target = self
        defaultMicItem.tag = 0
        if settings.selectedMicDeviceID == 0 {
            defaultMicItem.state = .on
        }
        micMenu.addItem(defaultMicItem)
        micMenu.addItem(.separator())

        let devices = SpeechService.availableInputDevices()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(device.id)
            if device.id == settings.selectedMicDeviceID {
                item.state = .on
            }
            micMenu.addItem(item)
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(.separator())

        // Status
        let connectedText = "LLM: Connected"
        let disconnectedText = "LLM: Disconnected"
        let statusItem = NSMenuItem(title: disconnectedText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        // Update async
        LLMService.shared.fetchModels { models in
            DispatchQueue.main.async {
                statusItem.title = models.isEmpty ? disconnectedText : connectedText
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

    @objc private func selectMic(_ sender: NSMenuItem) {
        Settings.shared.selectedMicDeviceID = UInt32(sender.tag)
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

        let settings = Settings.shared
        let mode = settings.rewriteModes.first(where: { $0.id == settings.defaultModeId })
            ?? settings.rewriteModes[0]
        let prompt = Prompts.rewrite(mode: mode, text: text)

        LLMService.shared.generate(prompt: prompt) { result in
            DispatchQueue.main.async {
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

        guard let text = AccessibilityService.shared.getSelectedText(), !text.isEmpty else {
            return
        }

        let selectionRect = AccessibilityService.shared.getSelectionRect()
        let settings = Settings.shared
        let modes = settings.rewriteModes

        guard !modes.isEmpty else { return }

        // Pick default mode: use defaultModeId if it exists in modes, otherwise first mode
        let initialMode: RewriteMode
        if let modeId = settings.defaultModeId,
           let mode = modes.first(where: { $0.id == modeId }) {
            initialMode = mode
        } else {
            initialMode = modes[0]
        }

        currentPanel?.close()

        let panel = ResultPanel(modes: modes)
        currentPanel = panel

        func runMode(_ mode: RewriteMode) {
            let prompt = Prompts.rewrite(mode: mode, text: text)
            LLMService.shared.generate(prompt: prompt) { result in
                switch result {
                case .success(let rewritten):
                    panel.updateResult(rewritten)
                case .failure(let err):
                    panel.updateError(err.localizedDescription)
                }
            }
        }

        panel.show(
            near: selectionRect,
            initialMode: initialMode,
            onModeSelected: { mode in
                runMode(mode)
            },
            onReplace: { [weak self] result in
                self?.currentPanel = nil
                AccessibilityService.shared.replaceTextInSourceApp(result, originalText: text)
            },
            onCopy: { [weak self] result in
                self?.currentPanel = nil
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
        )

        // Immediately run the initial mode
        runMode(initialMode)
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
        recordingIndicator.showProcessing()

        let speech = SpeechService.shared

        speech.onFinalResult = { [weak self] transcribedText in
            guard let self else { return }

            let settings = Settings.shared

            if settings.autoGrammarOnSTT {
                self.recordingIndicator.showProcessing()

                let mode = settings.rewriteModes.first(where: { $0.id == Settings.fixGrammarModeId })
                    ?? settings.rewriteModes[0]
                let prompt = Prompts.rewrite(mode: mode, text: transcribedText)

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
        recordingIndicator.showProcessing()
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
