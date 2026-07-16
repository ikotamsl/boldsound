import Foundation

public protocol SonioxCredentialStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

public final class SonioxCredentialStore: SonioxCredentialStoring, @unchecked Sendable {
    private static let apiKeyAccount = "soniox_api_key"
    private let keychain: KeyValueStore

    public init(
        keychain: KeyValueStore = KeychainKeyValueStore(service: "com.boldsound.prototype.soniox")
    ) {
        self.keychain = keychain
    }

    public func loadAPIKey() throws -> String? {
        try keychain.getString(Self.apiKeyAccount)
    }

    public func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }
        try keychain.setString(trimmed, forKey: Self.apiKeyAccount)
    }

    public func deleteAPIKey() throws {
        try keychain.delete(Self.apiKeyAccount)
    }
}

public enum SonioxLiveSettings {
    public static let enabledKey = "boldsound.soniox.live.enabled"
    public static let languageHintsKey = "boldsound.soniox.languageHints"

    // Soniox accepts ISO 639-1 language codes, not locale identifiers. Keep
    // this list aligned with the provider's documented STT language catalog so
    // an optional hint can never prevent an otherwise valid session starting.
    public static let supportedLanguageHints: Set<String> = [
        "af", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy",
        "da", "de", "el", "en", "es", "et", "eu", "fa", "fi", "fr",
        "gl", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "kk",
        "kn", "ko", "lt", "lv", "mk", "ml", "mr", "ms", "nl", "no",
        "pa", "pl", "pt", "ro", "ru", "sk", "sl", "sq", "sr", "sv",
        "sw", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "zh",
    ]

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    public static func languageHints(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.stringArray(forKey: languageHintsKey) ?? []
        return normalizedLanguageHints(raw)
    }

    public static func setLanguageHints(_ hints: [String], defaults: UserDefaults = .standard) {
        defaults.set(normalizedLanguageHints(hints), forKey: languageHintsKey)
    }

    public static func normalizedLanguageHints(_ hints: [String]) -> [String] {
        var seen = Set<String>()
        return hints.compactMap { raw in
            let locale = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            let value = locale.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
            guard supportedLanguageHints.contains(value), seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

    public static func unsupportedLanguageHints(_ hints: [String]) -> [String] {
        hints.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let base = trimmed.replacingOccurrences(of: "_", with: "-")
                .lowercased()
                .split(separator: "-", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            return supportedLanguageHints.contains(base) ? nil : trimmed
        }
    }
}
