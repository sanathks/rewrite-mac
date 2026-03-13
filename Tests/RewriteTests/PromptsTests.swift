import XCTest
@testable import Rewrite

final class PromptsTests: XCTestCase {

    // MARK: - Rewrite Prompt

    func testRewritePromptUsesModePrompt() {
        let mode = RewriteMode(id: UUID(), name: "Clarity", prompt: "Make it clear")
        let prompt = Prompts.rewrite(mode: mode, text: "test input")
        XCTAssertTrue(prompt.contains("Make it clear"))
    }

    func testRewritePromptContainsInputText() {
        let mode = RewriteMode(id: UUID(), name: "Clarity", prompt: "Make it clear")
        let prompt = Prompts.rewrite(mode: mode, text: "test input")
        XCTAssertTrue(prompt.contains("test input"))
    }

    func testRewriteMyToneUsesSpecialHandling() {
        let mode = RewriteMode(id: UUID(), name: "My Tone", prompt: "casual and friendly")
        let prompt = Prompts.rewrite(mode: mode, text: "test")
        XCTAssertTrue(prompt.contains("match this tone"))
        XCTAssertTrue(prompt.contains("casual and friendly"))
    }

    func testRewriteMyToneContainsGrammarFix() {
        let mode = RewriteMode(id: UUID(), name: "My Tone", prompt: "casual")
        let prompt = Prompts.rewrite(mode: mode, text: "test")
        XCTAssertTrue(prompt.contains("Fix any grammar, spelling, and punctuation errors"))
    }

    func testRewriteNonMyToneDoesNotContainMatchTone() {
        let mode = RewriteMode(id: UUID(), name: "Professional", prompt: "Be professional")
        let prompt = Prompts.rewrite(mode: mode, text: "test")
        XCTAssertFalse(prompt.contains("match this tone"))
    }

    func testRewritePromptContainsNoDashesInstruction() {
        let mode = RewriteMode(id: UUID(), name: "Clarity", prompt: "Make it clear")
        let prompt = Prompts.rewrite(mode: mode, text: "test")
        XCTAssertTrue(prompt.contains("Never use em dashes or semicolons"))
    }

    func testRewritePromptContainsReturnOnlyInstruction() {
        let mode = RewriteMode(id: UUID(), name: "Clarity", prompt: "Make it clear")
        let prompt = Prompts.rewrite(mode: mode, text: "test")
        XCTAssertTrue(prompt.contains("Return ONLY the rewritten text"))
    }

    func testFixGrammarModeWorksThroughRewrite() {
        let mode = RewriteMode(
            id: Settings.fixGrammarModeId,
            name: "Fix Grammar",
            prompt: Settings.defaultFixGrammarPrompt
        )
        let prompt = Prompts.rewrite(mode: mode, text: "she dont like it")
        XCTAssertTrue(prompt.contains("You are a grammar correction engine."))
        XCTAssertTrue(prompt.contains("<input>she dont like it</input>"))
        XCTAssertTrue(prompt.contains("<output>She goes to the store every day.</output>"))
    }

    func testFixGrammarPromptDoesNotUseGenericRewriteRules() {
        let mode = RewriteMode(
            id: Settings.fixGrammarModeId,
            name: "Fix Grammar",
            prompt: Settings.defaultFixGrammarPrompt
        )
        let prompt = Prompts.rewrite(mode: mode, text: "test")
        XCTAssertFalse(prompt.contains("The output must only contain words and ideas from the original, rephrased if needed."))
        XCTAssertFalse(prompt.contains("Return ONLY the rewritten text with no preamble."))
    }
}
