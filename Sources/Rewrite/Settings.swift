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

enum STTEngine: String, CaseIterable, Identifiable {
    case whisperKit = "whisperKit"
    case parakeet = "parakeet"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit"
        case .parakeet: return "Parakeet TDT"
        }
    }
}

enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny = "tiny"
    case small = "small"
    case largeTurbo = "large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75 MB)"
        case .small: return "Small (~220 MB)"
        case .largeTurbo: return "Large v3 Turbo (~630 MB)"
        }
    }

    var whisperKitModelName: String {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        case .small: return "openai_whisper-small"
        case .largeTurbo: return "openai_whisper-large-v3_turbo"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    static let fixGrammarModeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultFixGrammarPrompt =
        "Fix grammar, spelling, punctuation, capitalization, verb agreement, and obvious typos only. Preserve meaning, tone, sentence order, and paragraph breaks. Do not rewrite for style or clarity. Do not shorten, summarize, or add commentary. Return only the corrected text."

    let defaults: UserDefaults

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

    @Published var sttEngine: STTEngine {
        didSet { defaults.set(sttEngine.rawValue, forKey: "sttEngine") }
    }

    @Published var whisperModelSize: WhisperModelSize {
        didSet { defaults.set(whisperModelSize.rawValue, forKey: "whisperModelSize") }
    }

    @Published var autoGrammarOnSTT: Bool {
        didSet { defaults.set(autoGrammarOnSTT, forKey: "autoGrammarOnSTT") }
    }

    @Published var selectedMicDeviceID: UInt32 {
        didSet { defaults.set(selectedMicDeviceID, forKey: "selectedMicDeviceID") }
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

        // STT engine (migrate moonshine -> whisperKit)
        if let engineStr = defaults.string(forKey: "sttEngine"),
           let engine = STTEngine(rawValue: engineStr) {
            self.sttEngine = engine
        } else {
            self.sttEngine = .whisperKit
        }

        // Whisper model size
        if let whisperStr = defaults.string(forKey: "whisperModelSize"),
           let size = WhisperModelSize(rawValue: whisperStr) {
            self.whisperModelSize = size
        } else {
            self.whisperModelSize = .largeTurbo
        }

        // Auto grammar correction after STT (default: true)
        if defaults.object(forKey: "autoGrammarOnSTT") != nil {
            self.autoGrammarOnSTT = defaults.bool(forKey: "autoGrammarOnSTT")
        } else {
            self.autoGrammarOnSTT = true
        }

        // Selected mic device ID (default: 0 = system default)
        self.selectedMicDeviceID = UInt32(defaults.integer(forKey: "selectedMicDeviceID"))

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
