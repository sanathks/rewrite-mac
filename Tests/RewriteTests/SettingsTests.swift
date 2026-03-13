import XCTest
@testable import Rewrite

final class SettingsTests: XCTestCase {
    var suiteName: String!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Default Values

    func testDefaultServerURL() {
        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.serverURL, "http://localhost:11434")
    }

    func testDefaultModelName() {
        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.modelName, "gemma3")
    }

    func testDefaultModeIdIsFixGrammar() {
        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.defaultModeId, Settings.fixGrammarModeId)
    }

    func testDefaultRewriteModesCount() {
        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.rewriteModes.count, Settings.defaultRewriteModes.count)
    }

    // MARK: - Persistence Round Trips

    func testServerURLPersistence() {
        let settings = Settings(defaults: testDefaults)
        settings.serverURL = "http://example.com:5000"

        let settings2 = Settings(defaults: testDefaults)
        XCTAssertEqual(settings2.serverURL, "http://example.com:5000")
    }

    func testModelNamePersistence() {
        let settings = Settings(defaults: testDefaults)
        settings.modelName = "llama3"

        let settings2 = Settings(defaults: testDefaults)
        XCTAssertEqual(settings2.modelName, "llama3")
    }

    func testDefaultModeIdPersistence() {
        let id = UUID()
        let settings = Settings(defaults: testDefaults)
        settings.defaultModeId = id

        let settings2 = Settings(defaults: testDefaults)
        XCTAssertEqual(settings2.defaultModeId, id)
    }

    func testDefaultModeIdClearPersistence() {
        let settings = Settings(defaults: testDefaults)
        settings.defaultModeId = UUID()
        settings.defaultModeId = nil

        let settings2 = Settings(defaults: testDefaults)
        XCTAssertEqual(settings2.defaultModeId, Settings.fixGrammarModeId)
    }

    // MARK: - Pre-populated Defaults

    func testPrePopulatedServerURL() {
        testDefaults.set("http://custom:9999", forKey: "ollamaURL")
        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.serverURL, "http://custom:9999")
    }

    func testPrePopulatedModelName() {
        testDefaults.set("custom-model", forKey: "modelName")
        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.modelName, "custom-model")
    }

    // MARK: - RewriteMode Codable

    func testRewriteModeCodableRoundTrip() {
        let mode = RewriteMode(id: UUID(), name: "Test", prompt: "Test prompt")
        let data = try! JSONEncoder().encode(mode)
        let decoded = try! JSONDecoder().decode(RewriteMode.self, from: data)
        XCTAssertEqual(mode, decoded)
    }

    func testRewriteModesPersistence() {
        let modes = [
            RewriteMode(id: UUID(), name: "Mode1", prompt: "Prompt1"),
            RewriteMode(id: UUID(), name: "Mode2", prompt: "Prompt2")
        ]
        let settings = Settings(defaults: testDefaults)
        settings.rewriteModes = modes

        // Reload: migration should prepend Fix Grammar since it's missing
        let settings2 = Settings(defaults: testDefaults)
        XCTAssertEqual(settings2.rewriteModes.count, 3)
        XCTAssertEqual(settings2.rewriteModes[0].id, Settings.fixGrammarModeId)
        XCTAssertEqual(settings2.rewriteModes[1], modes[0])
        XCTAssertEqual(settings2.rewriteModes[2], modes[1])
    }

    func testMigrationAddsFixGrammarToExistingModes() {
        // Simulate existing user who has custom modes but no Fix Grammar
        let existingModes = [
            RewriteMode(id: UUID(), name: "Custom", prompt: "Custom prompt"),
        ]
        let data = try! JSONEncoder().encode(existingModes)
        testDefaults.set(data, forKey: "rewriteModes")

        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.rewriteModes.count, 2)
        XCTAssertEqual(settings.rewriteModes[0].id, Settings.fixGrammarModeId)
        XCTAssertEqual(settings.rewriteModes[0].name, "Fix Grammar")
        XCTAssertEqual(settings.rewriteModes[1], existingModes[0])
    }

    func testMigrationPreservesCustomizedFixGrammarPrompt() {
        let customPrompt = "Custom grammar prompt"
        let existingModes = [
            RewriteMode(
                id: Settings.fixGrammarModeId,
                name: "Fix Grammar",
                prompt: customPrompt
            ),
        ]
        let data = try! JSONEncoder().encode(existingModes)
        testDefaults.set(data, forKey: "rewriteModes")

        let settings = Settings(defaults: testDefaults)
        XCTAssertEqual(settings.rewriteModes[0].prompt, customPrompt)
    }
}
