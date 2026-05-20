enum Prompts {
    private static let fixGrammarPrompt = """
    You are a spelling and grammar correction engine.
    Task: fix ALL spelling mistakes, grammar errors, punctuation, capitalization, and verb agreement.
    Rules:
    - Fix every misspelled word, even if it looks like a deliberate abbreviation.
    - Preserve meaning, sentence order, and paragraph breaks.
    - Do not rewrite for style or clarity.
    - Do not shorten or summarize.
    - Do not remove words, sentences, or markdown/code formatting unless they contain a clear error.
    - Do not add advice, commentary, or extra sentences.
    - Do not answer the text.
    - Keep line breaks, markdown, inline code, and quoted text.
    - Return only the corrected text, nothing else.
    Examples:
    <input>She go to the store every day.</input>
    <output>She goes to the store every day.</output>
    <input>helo i wantd to snd you a messge</input>
    <output>Hello, I wanted to send you a message</output>
    <input>Please run `swift test` before merging, because the last change werent covered.</input>
    <output>Please run `swift test` before merging, because the last change wasn't covered.</output>
    Now correct this text and return ONLY the corrected text with no XML tags, labels, or explanations:
    %@
    """

    /// Wraps the user's custom voice post-processing prompt with the raw
    /// transcript. Kept deliberately minimal — the user-supplied prompt is the
    /// whole instruction; we just append the transcript clearly separated.
    static func voicePostProcess(prompt: String, transcript: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(trimmed)

        Transcript:
        \(transcript)
        """
    }

    /// Build a refinement prompt — used when the user types an
    /// instruction in the result panel's Refine field after the initial
    /// rewrite has landed. Small models (Gemma 4 2B/4B) get confused if
    /// the original text and the user's instruction aren't visually
    /// distinct, so we use clear labelled sections + a one-shot example
    /// to anchor the structure.
    static func refine(previousOutput: String, instruction: String) -> String {
        return """
        You are a text refinement engine.
        You will be given an ORIGINAL TEXT and a USER INSTRUCTION.
        Your job: modify the ORIGINAL TEXT according to the USER INSTRUCTION.

        CRITICAL RULES:
        - The USER INSTRUCTION is NEVER text to rewrite. It tells you what to do to the ORIGINAL TEXT.
        - Always operate on the ORIGINAL TEXT, never on the instruction.
        - Preserve meaning except where the instruction asks for changes.
        - Never use em dashes. Use commas or periods instead.
        - Return ONLY the refined text — no preamble, no labels, no quotes, no markdown, no commentary.

        Example:
        ORIGINAL TEXT: The quick brown fox jumps over the lazy dog in the warm sunshine of a summer afternoon.
        USER INSTRUCTION: shorter
        REFINED TEXT: The quick brown fox jumps over the lazy dog.

        Now refine this:
        ORIGINAL TEXT:
        \(previousOutput)

        USER INSTRUCTION:
        \(instruction)

        REFINED TEXT:
        """
    }

    static func rewrite(mode: RewriteMode, text: String) -> String {
        if mode.id == Settings.fixGrammarModeId {
            return String(format: fixGrammarPrompt, text)
        }

        let instruction: String
        if mode.name == "My Tone" {
            instruction = "Rewrite the following text to match this tone: \(mode.prompt). " +
                "Fix any grammar, spelling, and punctuation errors in the process. " +
                "Preserve the original meaning and key information."
        } else {
            instruction = mode.prompt
        }

        return """
        \(instruction) \
        STRICT RULES: \
        Never add new content, ideas, examples, or sentences that were not in the original text. \
        The output must only contain words and ideas from the original, rephrased if needed. \
        The output should be the same length or shorter than the input. \
        Never use em dashes. Use commas or periods instead. \
        Return ONLY the rewritten text with no preamble. \
        Do NOT wrap output in quotes or markdown formatting. \
        Do NOT add any explanations, comments, or summary.

        \(text)
        """
    }
}
