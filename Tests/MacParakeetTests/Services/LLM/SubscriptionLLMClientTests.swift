import XCTest
@testable import MacParakeetCore

final class SubscriptionLLMClientTests: XCTestCase {
    private func config(_ provider: LLMProviderID = .openai, model: String = "account-model") -> LLMProviderConfig {
        LLMProviderConfig(
            id: provider, baseURL: URL(string: "https://example.com")!, apiKey: "must-not-leak",
            modelName: model, isLocal: false, authenticationMode: .subscription)
    }

    func testSubscriptionNeverCarriesAPIKey() {
        XCTAssertNil(config().apiKey)
    }

    func testEnvironmentExcludesBillingOverridesAndStartupInjection() {
        let environment = SubscriptionLLMClient.environment(from: [
            "HOME": "/test", "PATH": "/bin", "OPENAI_API_KEY": "secret", "CODEX_API_KEY": "secret",
            "GEMINI_API_KEY": "secret", "GOOGLE_API_KEY": "secret", "GOOGLE_APPLICATION_CREDENTIALS": "secret",
            "GOOGLE_GENAI_USE_VERTEXAI": "true", "NODE_OPTIONS": "--require evil.js", "CODEX_HOME": "/other",
        ])
        XCTAssertEqual(Set(environment.keys), ["HOME", "PATH"])
    }

    func testModelIsOneArgumentAndCodexForcesChatGPT() throws {
        let model = "model'; touch /tmp/unsafe; $HOME"
        let arguments = try SubscriptionLLMClient.arguments(for: config(model: model))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], model)
        XCTAssertTrue(arguments.contains("forced_login_method=\"chatgpt\""))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
    }

    func testUnsupportedProviderFailsClosed() {
        for provider in LLMProviderID.allCases where !provider.supportsSubscription {
            XCTAssertThrowsError(try SubscriptionLLMClient.arguments(for: config(provider)))
        }
    }

    func testGeminiRejectsErrorsEvenWithResponse() throws {
        XCTAssertThrowsError(
            try SubscriptionLLMClient.response(
                from: #"{"response":"OK","error":{"message":"not authorized"}}"#, provider: .gemini,
                requestedModel: "selected"))
        XCTAssertThrowsError(
            try SubscriptionLLMClient.response(from: "not JSON", provider: .gemini, requestedModel: "selected"))
        XCTAssertEqual(
            try SubscriptionLLMClient.response(
                from: #"{"response":"answer","stats":{"models":{"selected":{"api":{"totalRequests":1}}}}}"#,
                provider: .gemini, requestedModel: "selected"), "answer")
    }

    func testGeminiRejectsSilentModelFallback() {
        XCTAssertThrowsError(
            try SubscriptionLLMClient.response(
                from: #"{"response":"answer","stats":{"models":{"other":{"api":{"totalRequests":1}}}}}"#,
                provider: .gemini, requestedModel: "selected"))
        XCTAssertThrowsError(
            try SubscriptionLLMClient.response(
                from: #"{"response":"answer"}"#, provider: .gemini, requestedModel: "selected"))
    }

    func testAuthAndModelFailuresAreActionableWithoutLeakingStderr() {
        let secret = "private transcript"
        let auth = SubscriptionLLMClient.accessError(
            LocalCLIError.nonZeroExit(code: 1, stderr: "401 unauthorized " + secret), provider: .openai,
            model: "selected")
        XCTAssertTrue(auth.localizedDescription.contains("No usable"))
        XCTAssertFalse(auth.localizedDescription.contains(secret))
        let model = SubscriptionLLMClient.accessError(
            LocalCLIError.nonZeroExit(code: 1, stderr: "model unavailable " + secret), provider: .gemini,
            model: "selected")
        XCTAssertTrue(model.localizedDescription.contains("could not access model selected"))
        XCTAssertFalse(model.localizedDescription.contains(secret))
    }

    func testGeminiEnvironmentDiscoveryStopsInsideOwnedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try SubscriptionLLMClient.prepareGeminiEnvironmentDirectory(directory)
        // Gemini searches these two locations before parents/home, depending on trust.
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".env")), Data())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".gemini/.env")), Data())
    }

    func testHTTPClientRejectsSubscriptionBeforeNetwork() async {
        do {
            _ = try await LLMClient().chatCompletion(
                messages: [], context: LLMExecutionContext(providerConfig: config()), options: .default)
            XCTFail("Subscription must never reach HTTP")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("official CLI"))
        }
    }

    func testDirectInvocationDoesNotInterpretShellAndUsesStdin() async throws {
        let literal = "$(echo unsafe); 'quoted'"
        let output = try await LocalCLIExecutor().executeInvocation(
            arguments: ["/usr/bin/printf", "%s", literal], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: FileManager.default.temporaryDirectory, prompt: "", timeout: 5)
        XCTAssertEqual(output, literal)
        let echoed = try await LocalCLIExecutor().executeInvocation(
            arguments: ["/bin/cat"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: FileManager.default.temporaryDirectory, prompt: "private transcript", timeout: 5)
        XCTAssertEqual(echoed, "private transcript")
    }
}
