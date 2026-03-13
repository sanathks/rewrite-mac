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
