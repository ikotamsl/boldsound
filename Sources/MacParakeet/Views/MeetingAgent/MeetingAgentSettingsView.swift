import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct MeetingAgentSettingsView: View {
    @Bindable private var agent = MeetingAgentViewModel.shared
    @AppStorage("meetingAgentEnabled") private var enabled = false
    @AppStorage("meetingAgentExecutablePath") private var executable = ""
    @AppStorage("meetingAgentVaultPath") private var vault = "/Users/user/obsidian/gtd"
    @AppStorage("meetingAgentProfileID") private var defaultProfileID = ""
    @AppStorage("meetingAgentVerifiedProfileID") private var verifiedProfileID = ""
    @State private var profileID = ""
    @State private var name = "Локальный Ollama"
    @State private var provider = "ollama"
    @State private var model = ""
    @State private var endpoint = "http://127.0.0.1:11434"
    @State private var timeout = 120.0
    @State private var apiKey = ""
    @State private var cliPath = ""
    @State private var keyRef: String?
    @State private var structuredOutput = "auto"
    @State private var cloud = false
    @State private var makeDefault = true
    @State private var busy = false
    @State private var message: String?

    private let providers = [
        "ollama", "openai", "codex", "anthropic", "gemini", "gemini_cli", "openrouter", "compatible",
    ]
    private var isCLI: Bool { ["codex", "gemini_cli"].contains(provider) }

    var body: some View {
        SettingsCard(
            title: "Агент встреч · Obsidian",
            subtitle: "Русский итог, решения и задачи. Профили независимы от остальных AI-функций.", icon: "doc.text"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Путь к meeting-agent", text: $executable)
                HStack {
                    TextField("Obsidian vault", text: $vault)
                    Button("Выбрать папку") { chooseVault() }.parakeetAction(.secondary)
                }
                HStack {
                    Picker("Профиль", selection: $profileID) {
                        Text("Новый профиль").tag("")
                        ForEach(Array(agent.profiles.enumerated()), id: \.offset) { _, profile in
                            Text(profile["name"].string ?? "").tag(profile["id"].string ?? "")
                        }
                    }
                    Button("Обновить") { perform { try await agent.loadProfiles() } }.parakeetAction(.secondary)
                }
                TextField("Название профиля", text: $name)
                Picker(
                    "Подключение",
                    selection: Binding(
                        get: { provider },
                        set: {
                            provider = $0; applyProviderDefaults($0)
                        })
                ) {
                    ForEach(providers, id: \.self) { Text(providerLabel($0)).tag($0) }
                }
                TextField("Модель", text: $model)
                if isCLI {
                    TextField("Путь к официальному CLI (необязательно)", text: $cliPath)
                    Text("Используется сохранённый вход официального CLI. Доступ и лимиты определяются аккаунтом.")
                        .font(.caption)
                } else {
                    TextField("Endpoint", text: $endpoint)
                    if provider != "ollama" { SecureField("API key → macOS Keychain", text: $apiKey) }
                }
                if ["ollama", "compatible"].contains(provider) {
                    Toggle("Облачный endpoint", isOn: $cloud)
                }
                Label(
                    cloud
                        ? "Облако: контекст встречи отправляется выбранному провайдеру"
                        : "Локально: подключение только к loopback-серверу",
                    systemImage: cloud ? "cloud" : "desktopcomputer"
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stepper("Таймаут: \(Int(timeout)) с", value: $timeout, in: 10...1800, step: 10)
                    Picker("Structured output", selection: $structuredOutput) {
                        Text("Проверять модель").tag("auto")
                        Text("Требовать схему").tag("native")
                        Text("JSON + проверка").tag("json")
                    }
                }
                Toggle("Использовать по умолчанию", isOn: $makeDefault)
                HStack {
                    Button("Сохранить профиль") { saveProfile() }.parakeetAction(.primary).disabled(
                        model.isEmpty || name.isEmpty)
                    Button("Проверить подключение") { testConnection() }.parakeetAction(.secondary).disabled(
                        profileID.isEmpty)
                    if isCLI {
                        Button("Войти через CLI") { login() }.parakeetAction(.secondary).disabled(profileID.isEmpty)
                    }
                }
                Divider()
                Toggle("Обрабатывать завершённые встречи автоматически", isOn: $enabled)
                    .disabled(
                        !enabled
                            && (defaultProfileID.isEmpty || verifiedProfileID != defaultProfileID || executable.isEmpty)
                    )
                Text(
                    "Включение разрешает последующие обработки выбранным профилем. Диктовка и импорт файлов не запускают агента; смены провайдера или способа оплаты при ошибке нет."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Установить и запустить worker") {
                    perform {
                        _ = try await agent.command("launchd");
                        message = "Worker установлен в launchd и продолжит работу после закрытия приложения."
                    }
                }.parakeetAction(.secondary).disabled(executable.isEmpty || defaultProfileID.isEmpty)
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(busy)
        }
        .task { if !executable.isEmpty { try? await agent.loadProfiles() } }
        .onChange(of: profileID) { _, value in loadProfile(value) }
        .onChange(of: executable) { _, _ in
            enabled = false; verifiedProfileID = ""
        }
        .onChange(of: vault) { _, _ in
            enabled = false; verifiedProfileID = ""
        }
    }

    private func providerLabel(_ value: String) -> String {
        switch value {
        case "codex": "OpenAI · подписка ChatGPT / Codex CLI"
        case "gemini_cli": "Google · Gemini CLI"
        case "openai": "OpenAI API · API key"
        case "anthropic": "Anthropic API · API key"
        case "gemini": "Gemini API · API key"
        case "compatible": "OpenAI-compatible endpoint"
        case "openrouter": "OpenRouter · API key"
        default: "Ollama"
        }
    }
    private func applyProviderDefaults(_ value: String) {
        cloud = !["ollama", "compatible"].contains(value)
        endpoint =
            [
                "ollama": "http://127.0.0.1:11434", "openai": "https://api.openai.com/v1",
                "anthropic": "https://api.anthropic.com/v1",
                "gemini": "https://generativelanguage.googleapis.com/v1beta",
                "openrouter": "https://openrouter.ai/api/v1", "compatible": "http://127.0.0.1:1234/v1",
            ][value] ?? ""
        keyRef = nil
        apiKey = ""
    }
    private func loadProfile(_ id: String) {
        apiKey = ""
        if id.isEmpty {
            keyRef = nil
            provider = "ollama"
            applyProviderDefaults(provider)
            name = "Новый профиль"
            model = ""
            cliPath = ""
            timeout = 120
            structuredOutput = "auto"
            makeDefault = false
            return
        }
        guard let profile = agent.profiles.first(where: { $0["id"].string == id }) else { return }
        provider = profile["provider"].string ?? "ollama"
        name = profile["name"].string ?? ""
        model = profile["model"].string ?? ""
        endpoint = profile["endpoint"].string ?? ""
        cloud = profile["execution"].string == "cloud"
        keyRef = profile["key_ref"].string
        cliPath = profile["cli_path"].string ?? ""
        structuredOutput = profile["structured_output"].string ?? "auto"
        if case .number(let value) = profile["timeout"] { timeout = value }
        makeDefault = defaultProfileID == id
    }
    private func saveProfile() {
        let id = profileID.isEmpty ? UUID().uuidString.lowercased() : profileID
        let profile: MeetingAgentJSON = .object([
            "id": .string(id), "name": .string(name), "provider": .string(provider), "model": .string(model),
            "endpoint": .string(endpoint), "timeout": .number(timeout), "execution": .string(cloud ? "cloud" : "local"),
            "structured_output": .string(structuredOutput), "key_ref": keyRef.map(MeetingAgentJSON.string) ?? .null,
            "cli_path": cliPath.isEmpty ? .null : .string(cliPath),
        ])
        let key = apiKey
        apiKey = ""
        perform {
            _ = try await agent.command(
                "profiles",
                payload: .object([
                    "action": .string("save"), "profile": profile, "default": .bool(makeDefault),
                    "api_key": .string(key),
                ]))
            if MeetingAgentViewModel.requiresAutomationRecheck(
                savedProfileID: id, currentDefaultProfileID: defaultProfileID, makeDefault: makeDefault)
            {
                verifiedProfileID = ""
                enabled = false
            }
            if makeDefault { defaultProfileID = id }
            try await agent.loadProfiles()
            profileID = id
            message = "Профиль сохранён. Проверьте подключение перед включением автоматизации."
        }
    }
    private func testConnection() {
        perform {
            _ = try await agent.command(
                "doctor",
                payload: .object(["test": .bool(true), "profile_id": .string(profileID), "vault": .string(vault)]))
            verifiedProfileID = profileID
            message = "Подключение проверено для сохранённой модели."
        }
    }
    private func login() {
        perform {
            let response = try await agent.command("login", profileID: profileID)
            guard let executable = response["executable"].string else { throw MeetingAgentError.invalidResponse }
            let arguments = [executable] + response["arguments"].array.compactMap(\.string)
            let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(
                separator: " ")
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "boldsound-login-\(UUID().uuidString).command")
            try ("#!/bin/sh\n" + command + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            NSWorkspace.shared.open(path)
            message = "Вход открыт в Terminal через официальный CLI. После входа проверьте подключение."
        }
    }
    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in if response == .OK, let url = panel.url { vault = url.path } }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { message = error.localizedDescription }
        }
    }
}
