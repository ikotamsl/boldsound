import Foundation

/// Account credentials stay with the official CLI. Never falls back to HTTP/API billing.
public final class SubscriptionLLMClient: LLMClientProtocol, Sendable {
    private let executor: LocalCLIExecutor

    public init(executor: LocalCLIExecutor = LocalCLIExecutor()) {
        self.executor = executor
    }

    public func chatCompletion(
        messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        try await complete(messages: messages, config: context.providerConfig, timeout: LocalCLIConfig.defaultTimeout)
    }

    public func chatCompletionStream(
        messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await chatCompletion(messages: messages, context: context, options: options)
                    continuation.yield(response.content)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        _ = try await complete(
            messages: [ChatMessage(role: .user, content: "Reply with OK.")],
            config: context.providerConfig, timeout: LocalCLIExecutor.testConnectionTimeoutCap)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] { [] }

    static func environment(from source: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var result = source.filter { allowed.contains($0.key) }
        let home = result["HOME"].map { "\($0)/.local/bin:\($0)/.npm-global/bin:" } ?? ""
        result["PATH"] = home + "/opt/homebrew/bin:/usr/local/bin:" + (result["PATH"] ?? "/usr/bin:/bin")
        return result
    }

    static func arguments(for config: LLMProviderConfig) throws -> [String] {
        guard config.authenticationMode == .subscription, config.id.supportsSubscription else {
            throw LLMError.cliError("Subscription access is not supported for this provider.")
        }
        guard !config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.cliError("Choose a model to test with your account.")
        }
        if config.id == .gemini {
            return [
                "gemini", "--model", config.modelName, "--extensions", "none", "--output-format", "json",
                "--prompt", "Answer the request supplied on stdin. Do not use tools.",
            ]
        }
        var arguments = [
            "codex", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
            "--skip-git-repo-check", "--sandbox", "read-only", "--model", config.modelName,
        ]
        for setting in [
            "forced_login_method=\"chatgpt\"", "model_provider=\"openai\"", "approval_policy=\"never\"",
            "web_search=\"disabled\"", "project_doc_max_bytes=0", "features.shell_tool=false",
            "features.unified_exec=false", "tools.view_image=false", "features.apply_patch_freeform=false",
            "features.multi_agent=false", "features.apps=false", "features.plugins=false", "features.hooks=false",
            "features.skill_search=false", "features.skill_mcp_dependency_install=false", "mcp_servers={}",
        ] {
            arguments += ["-c", setting]
        }
        return arguments + ["-"]
    }

    static func response(from output: String, provider: LLMProviderID, requestedModel: String) throws -> String {
        if provider == .gemini {
            struct ModelStats: Decodable { let api: APIStats? }
            struct APIStats: Decodable { let totalRequests: Int? }
            struct Stats: Decodable { let models: [String: ModelStats]? }
            struct Envelope: Decodable { let response: String?; let error: ErrorEnvelope?; let stats: Stats? }
            struct ErrorEnvelope: Decodable { let message: String? }
            guard let data = output.data(using: .utf8),
                let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                envelope.error == nil, let response = envelope.response,
                !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw LLMError.cliError(
                    "Google account could not use the selected model. Check your Gemini CLI login, plan and model access, then test again."
                )
            }
            let usedModels = envelope.stats?.models?.filter { ($0.value.api?.totalRequests ?? 0) > 0 }.map(\.key) ?? []
            guard usedModels == [requestedModel] else {
                throw LLMError.cliError(
                    "Gemini could not verify access to the selected model. A different model may have been used. Choose an exact model ID available to your account and test again."
                )
            }
            return response
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.cliError(
                "Your ChatGPT account returned no response for the selected model. Check Codex login and model access.")
        }
        return output
    }

    private func complete(messages: [ChatMessage], config: LLMProviderConfig, timeout: Double) async throws
        -> ChatCompletionResponse
    {
        let arguments = try Self.arguments(for: config)
        let prompts = LocalCLILLMClient.extractPrompts(from: messages)
        let prompt = LocalCLIExecutor.formatFullPrompt(system: prompts.system, user: prompts.user)
        // File preparation and cleanup run off the main actor along with the CLI call.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "boldsound-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = Self.environment(from: ProcessInfo.processInfo.environment)
        if config.id == .gemini {
            try Self.prepareGeminiEnvironmentDirectory(directory)
            let settings: [String: Any] = [
                "tools": ["core": ["__boldsound_no_tools__"], "discoveryCommand": "", "callCommand": ""],
                "mcp": ["allowed": ["__boldsound_no_mcp__"], "serverCommand": ""], "mcpServers": [String: String](),
                "hooksConfig": ["enabled": false], "context": ["fileName": [String]()],
                "security": ["auth": ["selectedType": "oauth-personal", "enforcedType": "oauth-personal"]],
                "telemetry": ["enabled": false], "advanced": ["ignoreLocalEnv": false],
                "experimental": ["enableAgents": false],
            ]
            let settingsURL = directory.appendingPathComponent("settings.json")
            try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
            environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = settingsURL.path
        }
        do {
            let output = try await executor.executeInvocation(
                arguments: arguments, environment: environment,
                workingDirectory: directory, prompt: prompt, timeout: timeout)
            return ChatCompletionResponse(
                content: try Self.response(from: output, provider: config.id, requestedModel: config.modelName),
                model: config.modelName)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            throw error
        } catch {
            // CLI stderr may contain prompt text or account information; do not expose it.
            throw Self.accessError(error, provider: config.id, model: config.modelName)
        }
    }

    /// Stop Gemini's upward .env search before it can reload global credentials,
    /// endpoints or telemetry overrides after our environment was sanitized.
    static func prepareGeminiEnvironmentDirectory(_ directory: URL) throws {
        let geminiDirectory = directory.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent(".env"))
        try Data().write(to: geminiDirectory.appendingPathComponent(".env"))
    }

    static func accessError(_ error: Error, provider: LLMProviderID, model: String) -> LLMError {
        let tool = provider == .openai ? "Codex" : "Gemini"
        if let error = error as? LocalCLIError {
            switch error {
            case .commandNotFound:
                return .cliError("Install the official \(tool) CLI and sign in to use subscription access.")
            case .timeout:
                return .cliError(
                    "\(tool) account check timed out. Sign in using the official CLI in Terminal, check your connection, then retry."
                )
            case .nonZeroExit(_, let stderr):
                let text = stderr.lowercased()
                if ["unauthorized", "not logged in", "authentication", "login", "sign in", "oauth", "401"].contains(
                    where: text.contains)
                {
                    return .cliError(
                        "No usable \(tool) account login was found. Sign in using the official CLI in Terminal, then test again. API billing was not used."
                    )
                }
                if ["model", "permission", "403", "subscription"].contains(where: text.contains) {
                    return .cliError(
                        "Your \(tool) account could not access model \(model). Check your plan or choose an available model. API billing was not used."
                    )
                }
                if ["quota", "rate limit", "429"].contains(where: text.contains) {
                    return .cliError(
                        "Your \(tool) account usage limit was reached. Wait for it to reset or check your plan. API billing was not used."
                    )
                }
            default: break
            }
        }
        return LLMError.cliError(
            "\(tool) account access failed for model \(model). Install or update the official CLI and sign in. Check that your account/plan allows this model and has remaining quota, then test again. API billing was not used."
        )
    }
}
