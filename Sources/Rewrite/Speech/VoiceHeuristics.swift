import Foundation

/// Cheap heuristics that decide whether a voice transcript needs LLM cleanup.
/// Skipping the LLM for short, clean utterances cuts latency from
/// ~300–800 ms (round-trip through Gemma 4) down to ~5 ms.
enum VoiceHeuristics {

    /// Transcripts at or below this word count skip the LLM unless a filler
    /// is present. Tuned by feel — short utterances like "okay it is working"
    /// or "can you do this next" pass through raw.
    static let shortUtteranceWordCount = 6

    /// Filler / disfluency tokens that strongly suggest the speaker wants
    /// cleanup, regardless of transcript length. Matched as whole words,
    /// case-insensitive, so "like" matches but "alike" doesn't.
    static let fillerTokens: [String] = [
        "um", "uh", "umm", "uhh", "hmm", "hmmm", "er", "erm",
        "like", "you know", "i mean", "sort of", "kind of",
        "kinda", "sorta", "basically", "literally", "actually",
        "right"
    ]

    /// Returns true if the transcript should be piped through the LLM for
    /// cleanup. Returns false for short, filler-free utterances that the
    /// STT engine already produced cleanly.
    static func needsCleanup(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if containsFiller(trimmed) { return true }
        return wordCount(of: trimmed) > shortUtteranceWordCount
    }

    /// Word count from a sentence — splits on whitespace and punctuation,
    /// ignores empty fragments.
    static func wordCount(of text: String) -> Int {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .filter { !$0.isEmpty }
            .count
    }

    /// Case-insensitive whole-word search for any filler in `fillerTokens`.
    private static func containsFiller(_ text: String) -> Bool {
        let lower = text.lowercased()
        for filler in fillerTokens {
            // Build a quick word-boundary check. NSRegularExpression-free to
            // keep this cheap on the STT critical path.
            if matchesWord(filler, in: lower) { return true }
        }
        return false
    }

    /// Returns true if `needle` appears in `haystack` as a whole word.
    /// `haystack` is assumed already lowercased.
    private static func matchesWord(_ needle: String, in haystack: String) -> Bool {
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex
                ? nil
                : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex
                ? nil
                : haystack[range.upperBound]
            let leftOK = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let rightOK = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if leftOK && rightOK { return true }
            start = haystack.index(after: range.lowerBound)
        }
        return false
    }
}
