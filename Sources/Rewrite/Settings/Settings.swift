import AppKit
import Carbon
import Foundation
import Combine

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags

    /// Whether this shortcut uses only modifier keys (no letter/number key).
    var isModifierOnly: Bool { keyCode == 0 && modifiers != 0 }

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        if !isModifierOnly {
            parts.append(keyCodeToString(keyCode))
        }
        return parts.joined()
    }
}

struct RewriteMode: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case embedded
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .embedded: return "On-device (Gemma 4)"
        case .remote: return "Remote server (Ollama / LM Studio)"
        }
    }
}

/// Locally-runnable Gemma 4 variants exposed in Settings.
/// Each case maps to a HuggingFace GGUF repo + filename for the llama.cpp backend.
enum EmbeddedLLMModel: String, CaseIterable, Identifiable {
    case e2b4bit
    case e4b4bit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .e2b4bit: return "Gemma 4 E2B (Q4_K_M, ~3 GB)"
        case .e4b4bit: return "Gemma 4 E4B (Q4_K_M, ~5 GB)"
        }
    }

    var huggingFaceRepo: String {
        switch self {
        case .e2b4bit: return "unsloth/gemma-4-E2B-it-GGUF"
        case .e4b4bit: return "ggml-org/gemma-4-E4B-it-GGUF"
        }
    }

    var ggufFilename: String {
        switch self {
        case .e2b4bit: return "gemma-4-E2B-it-Q4_K_M.gguf"
        case .e4b4bit: return "gemma-4-E4B-it-Q4_K_M.gguf"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    static let fixGrammarModeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultFixGrammarPrompt =
        "Fix grammar, spelling, punctuation, capitalization, verb agreement, and obvious typos only. Preserve meaning, tone, sentence order, and paragraph breaks. Do not rewrite for style or clarity. Do not shorten, summarize, or add commentary. Return only the corrected text."

    let defaults: UserDefaults

    @Published var llmProvider: LLMProvider {
        didSet { defaults.set(llmProvider.rawValue, forKey: "llmProvider") }
    }

    @Published var embeddedModel: EmbeddedLLMModel {
        didSet { defaults.set(embeddedModel.rawValue, forKey: "embeddedModel") }
    }

    /// When true, the embedded model is loaded into memory at app launch
    /// (and re-prewarmed after a download or provider switch) so the first
    /// rewrite doesn't pay the ~10 s cold-start cost. Off keeps ~5 GB free.
    @Published var keepModelLoaded: Bool {
        didSet { defaults.set(keepModelLoaded, forKey: "keepModelLoaded") }
    }

    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: "ollamaURL") }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: "modelName") }
    }

    @Published var grammarShortcut: Shortcut {
        didSet {
            defaults.set(grammarShortcut.keyCode, forKey: "grammarKeyCode")
            defaults.set(grammarShortcut.modifiers, forKey: "grammarModifiers")
        }
    }

    @Published var rewriteShortcut: Shortcut {
        didSet {
            defaults.set(rewriteShortcut.keyCode, forKey: "rewriteKeyCode")
            defaults.set(rewriteShortcut.modifiers, forKey: "rewriteModifiers")
        }
    }

    @Published var sttShortcut: Shortcut {
        didSet {
            defaults.set(sttShortcut.keyCode, forKey: "sttKeyCode")
            defaults.set(sttShortcut.modifiers, forKey: "sttModifiers")
        }
    }

    @Published var handsFreeShortcut: Shortcut {
        didSet {
            defaults.set(handsFreeShortcut.keyCode, forKey: "handsFreeKeyCode")
            defaults.set(handsFreeShortcut.modifiers, forKey: "handsFreeModifiers")
        }
    }

    @Published var voicePostProcessEnabled: Bool {
        didSet { defaults.set(voicePostProcessEnabled, forKey: "autoGrammarOnSTT") }
    }

    // MARK: - Quick launcher

    @Published var launcherEnabled: Bool {
        didSet { defaults.set(launcherEnabled, forKey: "launcherEnabled") }
    }

    @Published var launcherPrefixKey: LauncherPrefixKey {
        didSet { defaults.set(launcherPrefixKey.rawValue, forKey: "launcherPrefixKey") }
    }

    @Published var launcherBindings: [LauncherBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(launcherBindings) {
                defaults.set(data, forKey: "launcherBindings")
            }
        }
    }

    @Published var voicePostProcessPrompt: String {
        didSet { defaults.set(voicePostProcessPrompt, forKey: "voicePostProcessPrompt") }
    }

    static let defaultVoicePostProcessPrompt =
        "Clean up the following voice transcription. Fix grammar, punctuation, and capitalization. Remove filler words (um, uh, like, you know, sort of). Preserve the speaker's meaning and intent — do not paraphrase, summarize, or add information. Return only the cleaned text with no preamble or commentary."

    /// Stable UID of the selected input device (e.g. "AppleUSBAudioEngine:..."),
    /// or empty string for "System Default". Stored as UID rather than AudioDeviceID
    /// because AudioDeviceID is reassigned on every unplug/replug.
    @Published var selectedMicUID: String {
        didSet { defaults.set(selectedMicUID, forKey: "selectedMicUID") }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    @Published var defaultModeId: UUID? {
        didSet {
            if let id = defaultModeId {
                defaults.set(id.uuidString, forKey: "defaultModeId")
            } else {
                defaults.removeObject(forKey: "defaultModeId")
            }
        }
    }

    @Published var rewriteModes: [RewriteMode] {
        didSet {
            if let data = try? JSONEncoder().encode(rewriteModes) {
                defaults.set(data, forKey: "rewriteModes")
            }
        }
    }

    static let defaultRewriteModes: [RewriteMode] = [
        RewriteMode(
            id: fixGrammarModeId,
            name: "Fix Grammar",
            prompt: defaultFixGrammarPrompt
        ),
        RewriteMode(
            id: UUID(),
            name: "Clarity",
            prompt: "Rewrite the following text for clarity and readability. Simplify wording and shorten long sentences. Prefer active voice. Remove filler words and redundant phrases. Do NOT add new ideas, examples, or information that was not in the original. The output must be the same length or shorter than the input. Fix any grammar or spelling errors."
        ),
        RewriteMode(
            id: UUID(),
            name: "My Tone",
            prompt: "casual and friendly, like texting a close colleague"
        ),
        RewriteMode(
            id: UUID(),
            name: "Humanize",
            prompt: """
            Rewrite the following text to sound natural and human-written. \
            Use contractions (don't, isn't, can't). Vary sentence length, mix short punchy sentences with longer ones. Prefer active voice. Be direct, lead with the point. \
            NEVER use these words/phrases: delve, tapestry, leverage, utilize, moreover, furthermore, additionally, notably, it is worth noting, in conclusion, overall, testament, beacon, realm, landscape, foster, underscore, paramount, groundbreaking, game-changing, synergy, embark, cutting-edge, at the forefront, pave the way, harness, unlock the potential, navigate the complexities, spearhead, bridging the gap, robust, streamline, empower, crucial, vital, revolutionize, comprehensive, bespoke, endeavor, consequently, subsequently. \
            NEVER use the construction "not just X, but also Y." \
            NEVER use em dashes. \
            Do NOT add new ideas, examples, sentences, or information that was not in the original. Only rephrase what already exists. Fix any grammar or spelling errors.
            """
        ),
    ]

    init(defaults: UserDefaults) {
        self.defaults = defaults

        // LLM provider — default to embedded for new installs.
        if let raw = defaults.string(forKey: "llmProvider"),
           let provider = LLMProvider(rawValue: raw) {
            self.llmProvider = provider
        } else {
            self.llmProvider = .embedded
        }

        // Embedded model — default to E4B 4-bit (best quality/size tradeoff).
        if let raw = defaults.string(forKey: "embeddedModel"),
           let model = EmbeddedLLMModel(rawValue: raw) {
            self.embeddedModel = model
        } else {
            self.embeddedModel = .e4b4bit
        }

        // Keep model loaded at launch (default true).
        if defaults.object(forKey: "keepModelLoaded") != nil {
            self.keepModelLoaded = defaults.bool(forKey: "keepModelLoaded")
        } else {
            self.keepModelLoaded = true
        }

        self.serverURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        self.modelName = defaults.string(forKey: "modelName") ?? "gemma3:4b"

        // Default: Ctrl+Shift+G for grammar
        let gCode = defaults.object(forKey: "grammarKeyCode") as? UInt32
            ?? UInt32(kVK_ANSI_G)
        let gMods = defaults.object(forKey: "grammarModifiers") as? UInt32
            ?? UInt32(controlKey | shiftKey)
        self.grammarShortcut = Shortcut(keyCode: gCode, modifiers: gMods)

        // Default: Ctrl+Shift+T for rewrite (migrate from old toneKeyCode/toneModifiers)
        let rCode = defaults.object(forKey: "rewriteKeyCode") as? UInt32
            ?? defaults.object(forKey: "toneKeyCode") as? UInt32
            ?? UInt32(kVK_ANSI_T)
        let rMods = defaults.object(forKey: "rewriteModifiers") as? UInt32
            ?? defaults.object(forKey: "toneModifiers") as? UInt32
            ?? UInt32(controlKey | shiftKey)
        self.rewriteShortcut = Shortcut(keyCode: rCode, modifiers: rMods)

        // Default: Ctrl+Option+S for speech-to-text
        let sCode = defaults.object(forKey: "sttKeyCode") as? UInt32
            ?? UInt32(kVK_ANSI_S)
        let sMods = defaults.object(forKey: "sttModifiers") as? UInt32
            ?? UInt32(controlKey | optionKey)
        self.sttShortcut = Shortcut(keyCode: sCode, modifiers: sMods)

        // Default: Ctrl+Option+H for hands-free voice
        let hfCode = defaults.object(forKey: "handsFreeKeyCode") as? UInt32
            ?? UInt32(kVK_ANSI_H)
        let hfMods = defaults.object(forKey: "handsFreeModifiers") as? UInt32
            ?? UInt32(controlKey | optionKey)
        self.handsFreeShortcut = Shortcut(keyCode: hfCode, modifiers: hfMods)

        // Post-process voice transcript through the LLM (default: true).
        // UserDefaults key is the legacy "autoGrammarOnSTT" for back-compat.
        if defaults.object(forKey: "autoGrammarOnSTT") != nil {
            self.voicePostProcessEnabled = defaults.bool(forKey: "autoGrammarOnSTT")
        } else {
            self.voicePostProcessEnabled = true
        }

        self.voicePostProcessPrompt = defaults.string(forKey: "voicePostProcessPrompt")
            ?? Settings.defaultVoicePostProcessPrompt

        // Launcher — default off; user opts in from Settings → Launcher.
        self.launcherEnabled = defaults.bool(forKey: "launcherEnabled")

        if let raw = defaults.string(forKey: "launcherPrefixKey"),
           let prefix = LauncherPrefixKey(rawValue: raw) {
            self.launcherPrefixKey = prefix
        } else {
            self.launcherPrefixKey = .space
        }

        if let data = defaults.data(forKey: "launcherBindings"),
           let bindings = try? JSONDecoder().decode([LauncherBinding].self, from: data) {
            self.launcherBindings = bindings
        } else {
            self.launcherBindings = []
        }

        // Selected mic UID (default: "" = system default).
        // Migrate from legacy "selectedMicDeviceID": discard the old numeric ID
        // since it would not match the device after a reconnect anyway.
        if let uid = defaults.string(forKey: "selectedMicUID") {
            self.selectedMicUID = uid
        } else {
            self.selectedMicUID = ""
            if defaults.object(forKey: "selectedMicDeviceID") != nil {
                defaults.removeObject(forKey: "selectedMicDeviceID")
            }
        }

        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")

        // Load default mode
        if let idString = defaults.string(forKey: "defaultModeId"),
           let uuid = UUID(uuidString: idString) {
            self.defaultModeId = uuid
        } else {
            self.defaultModeId = Settings.fixGrammarModeId
        }

        // Load rewrite modes from UserDefaults or use defaults
        if let data = defaults.data(forKey: "rewriteModes"),
           var modes = try? JSONDecoder().decode([RewriteMode].self, from: data) {
            // Migration: ensure Fix Grammar mode exists for existing users
            if !modes.contains(where: { $0.id == Settings.fixGrammarModeId }) {
                modes.insert(Settings.defaultRewriteModes[0], at: 0)
            }
            self.rewriteModes = modes
        } else {
            self.rewriteModes = Settings.defaultRewriteModes
        }
    }

    private convenience init() {
        self.init(defaults: .standard)
    }
}

// Map virtual key codes to display strings
func keyCodeToString(_ keyCode: UInt32) -> String {
    let map: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Escape): "Esc",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
    ]
    return map[keyCode] ?? "?"
}

// Convert NSEvent modifier flags to Carbon modifier flags
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    return mods
}
