import AppKit
import ApplicationServices

/// After a voice insertion, watch the focused text element for ~60 s and
/// surface proper-noun corrections the user makes — e.g. typing the
/// transcribed "candies" over to "Candis". Clean substitutions get
/// suggested to the user via `HotwordSuggestionPanel`, and on accept
/// land in `Settings.voiceHotwords`.
///
/// Pure poll-based — no AXObserver C-callback ceremony. Polls at 500 ms
/// so we catch corrections even when the user immediately submits (Enter
/// clears the field). The candidateFor word-boundary check stops us
/// firing mid-typing without needing multi-poll stability.
/// Always called on the main thread (timers fire on main, callers dispatch
/// onto main). No internal synchronisation.
final class HotwordsLearner {
    static let shared = HotwordsLearner()
    private init() {}

    private let pollInterval: TimeInterval = 0.5
    private let pollWindow: TimeInterval = 60.0

    private var watchedElement: AXUIElement?
    private var baselineValue: String = ""
    /// Most recent non-empty current-value observation. Lets us run a
    /// final diff when the field suddenly clears (Enter / submit) so the
    /// user's last keystroke before sending still counts.
    private var lastSeenValue: String = ""
    private var insertedText: String = ""
    private var startTime: Date = .distantPast
    private var pollTimer: Timer?
    private var fired = false

    /// Call right after `AccessibilityService.shared.insertTextInSourceApp`.
    /// Records a baseline value for the focused element and begins
    /// polling. Cheap; bails immediately if auto-learn is off or the
    /// focused element doesn't expose its text.
    func watch(insertedText: String) {
        guard Settings.shared.voiceHotwordsAutoLearn else { return }
        let trimmed = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }

        // Ask Electron / Chrome / etc. to expose their full a11y tree so
        // kAXValueAttribute returns the field text. No-op for native apps.
        if let pid = Self.focusedElementPid() {
            Self.enableEnhancedUI(for: pid)
        }

        guard let element = Self.systemFocusedElement(),
              let baseline = Self.readValue(of: element),
              baseline.contains(trimmed)
        else {
            stop()
            return
        }

        stop()
        watchedElement = element
        baselineValue = baseline
        lastSeenValue = baseline
        self.insertedText = trimmed
        startTime = Date()
        fired = false

        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        watchedElement = nil
        baselineValue = ""
        lastSeenValue = ""
        insertedText = ""
        fired = false
    }

    private func poll() {
        if fired { stop(); return }
        if Date().timeIntervalSince(startTime) > pollWindow { stop(); return }
        guard let element = watchedElement else { stop(); return }

        let current = Self.readValue(of: element)

        // Field-clear detection: AX read failed or value shrank a lot
        // since the last poll (user pressed Enter / Send). Run a final
        // diff using the last seen value so a fast Enter still counts.
        let cleared: Bool
        if let current {
            cleared = current.count + 5 < lastSeenValue.count
                && lastSeenValue != baselineValue
        } else {
            cleared = true
        }

        if cleared {
            _ = tryPropose(against: lastSeenValue)
            stop()
            return
        }

        guard let current else { return }
        if current != baselineValue {
            _ = tryPropose(against: current)
        }
        lastSeenValue = current
    }

    @discardableResult
    private func tryPropose(against text: String) -> Bool {
        guard let candidate = Self.findHotwordCandidate(
            baseline: baselineValue,
            current: text,
            insertedText: insertedText
        ) else { return false }

        if Self.isAlreadyHotword(candidate) { return false }

        // Require the candidate to be followed by a word boundary in the
        // text — keeps us from firing while the user is still typing the
        // letters ("Ca" → "Cand" → "Candis"). The completed word will be
        // followed by space/punct or sit at end-of-string.
        guard Self.hasWordBoundaryAfter(candidate, in: text) else { return false }

        fired = true
        propose(candidate)
        return true
    }

    private func propose(_ word: String) {
        HotwordSuggestionPanel.shared.show(word: word) { accepted in
            guard accepted else { return }
            HotwordsLearner.append(word)
        }
    }

    static func append(_ word: String) {
        let existing = Settings.shared.voiceHotwords
        if existing.isEmpty {
            Settings.shared.voiceHotwords = word
        } else if existing.hasSuffix("\n") {
            Settings.shared.voiceHotwords = existing + word
        } else {
            Settings.shared.voiceHotwords = existing + "\n" + word
        }
    }

    private static func isAlreadyHotword(_ word: String) -> Bool {
        let existing = Settings.shared.voiceHotwords
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return existing.contains(word.lowercased())
    }

    // MARK: - AX helpers

    private static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success else { return nil }
        return (raw as! AXUIElement)
    }

    private static func readValue(of element: AXUIElement) -> String? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? String
    }

    private static func focusedElementPid() -> pid_t? {
        guard let element = systemFocusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// Mirror of `AccessibilityService.enableEnhancedUI`. Tells Electron /
    /// Chrome apps to expose their full a11y tree so we can read text
    /// values from web-based input fields. Cheap, idempotent at the OS
    /// level — Apple's API tolerates repeated sets.
    private static func enableEnhancedUI(for pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            axApp, "AXEnhancedUserInterface" as CFString, true as CFTypeRef
        )
        AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, true as CFTypeRef
        )
    }

    private static func hasWordBoundaryAfter(_ word: String, in text: String) -> Bool {
        guard let range = text.range(of: word) else { return false }
        if range.upperBound == text.endIndex { return true }
        let next = text[range.upperBound]
        return !next.isLetter
    }

    // MARK: - Diff

    /// Walk a word-level diff of baseline vs current. Return the first
    /// clean substitution that looks like a proper-noun correction —
    /// nil if there's nothing actionable.
    static func findHotwordCandidate(
        baseline: String,
        current: String,
        insertedText: String
    ) -> String? {
        let baselineWords = baseline.split(whereSeparator: \.isWhitespace).map(String.init)
        let currentWords = current.split(whereSeparator: \.isWhitespace).map(String.init)
        let ops = diffWords(baselineWords, currentWords)

        var i = 0
        while i < ops.count {
            if case .delete(let oldWord) = ops[i],
               i + 1 < ops.count,
               case .insert(let newWord) = ops[i + 1] {
                if let candidate = candidateFor(oldWord: oldWord, newWord: newWord) {
                    return candidate
                }
                i += 2
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func candidateFor(oldWord: String, newWord: String) -> String? {
        let strip = CharacterSet.punctuationCharacters.union(.whitespaces)
        let oldClean = oldWord.trimmingCharacters(in: strip)
        let newClean = newWord.trimmingCharacters(in: strip)

        guard newClean.count >= 2 else { return nil }
        guard let first = newClean.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return nil }
        guard oldClean.lowercased() != newClean.lowercased() else { return nil }

        // Cheap proper-noun filter. Either:
        //  * The new word has interior uppercase or a digit (acronym / brand
        //    like "PostgreSQL", "iOS", "3M") — accept unconditionally.
        //  * It's a normal-looking word — only accept if it's a phonetic
        //    edit of the old word (shares a 2-char prefix), so we don't
        //    pick up sentence-start capitalisations like "the" → "The".
        let interiorUpperOrDigit = newClean.dropFirst().contains { c in
            c.isUppercase || c.isNumber
        }
        if !interiorUpperOrDigit {
            guard oldClean.count >= 3, newClean.count >= 3 else { return nil }
            let oldPrefix = oldClean.prefix(2).lowercased()
            let newPrefix = newClean.prefix(2).lowercased()
            guard oldPrefix == newPrefix else { return nil }
        }

        return newClean
    }
}

// MARK: - Word-level LCS diff

enum WordDiffOp {
    case keep(String)
    case insert(String)
    case delete(String)
}

func diffWords(_ a: [String], _ b: [String]) -> [WordDiffOp] {
    let n = a.count, m = b.count
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0..<n {
        for j in 0..<m {
            dp[i + 1][j + 1] = a[i] == b[j]
                ? dp[i][j] + 1
                : max(dp[i][j + 1], dp[i + 1][j])
        }
    }
    var ops: [WordDiffOp] = []
    var i = n, j = m
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            ops.append(.keep(a[i - 1])); i -= 1; j -= 1
        } else if dp[i][j - 1] >= dp[i - 1][j] {
            ops.append(.insert(b[j - 1])); j -= 1
        } else {
            ops.append(.delete(a[i - 1])); i -= 1
        }
    }
    while i > 0 { ops.append(.delete(a[i - 1])); i -= 1 }
    while j > 0 { ops.append(.insert(b[j - 1])); j -= 1 }
    return ops.reversed()
}
