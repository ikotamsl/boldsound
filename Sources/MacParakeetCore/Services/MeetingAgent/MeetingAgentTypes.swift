import Foundation

public struct MeetingAgentConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var executablePath: String
    public var vaultPath: String
    public var profileID: String?
    public var profileFingerprints: [String: String]

    public init(
        enabled: Bool = false, executablePath: String = "", vaultPath: String = "/Users/user/obsidian/gtd",
        profileID: String? = nil, profileFingerprints: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.executablePath = executablePath
        self.vaultPath = vaultPath
        self.profileID = profileID
        self.profileFingerprints = profileFingerprints
    }

    public static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            enabled: defaults.bool(forKey: "meetingAgentEnabled"),
            executablePath: defaults.string(forKey: "meetingAgentExecutablePath") ?? "",
            vaultPath: defaults.string(forKey: "meetingAgentVaultPath") ?? "/Users/user/obsidian/gtd",
            profileID: defaults.string(forKey: "meetingAgentProfileID"),
            profileFingerprints: defaults.dictionary(forKey: "meetingAgentProfileFingerprints") as? [String: String]
                ?? [:]
        )
    }
}

public struct MeetingAgentNote: Codable, Sendable, Equatable, Identifiable {
    public var vault: String
    public var path: String
    public var id: String?

    public init(vault: String, path: String, id: String? = nil) {
        self.vault = vault
        self.path = path
        self.id = id
    }
}

/// A small JSON value for the versioned agent protocol. Never log its contents.
public enum MeetingAgentJSON: Codable, Sendable, Equatable {
    case object([String: MeetingAgentJSON])
    case array([MeetingAgentJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let v = try? value.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? value.decode(Double.self) {
            self = .number(v)
        } else if let v = try? value.decode(String.self) {
            self = .string(v)
        } else if let v = try? value.decode([Self].self) {
            self = .array(v)
        } else {
            self = .object(try value.decode([String: Self].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> Self {
        if case .object(let value) = self { return value[key] ?? .null }
        return .null
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var array: [Self] { if case .array(let v) = self { return v }; return [] }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public static func value<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: encoder().encode(value))
    }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Self.encoder().encode(self))
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum MeetingAgentError: LocalizedError, Sendable {
    case unavailable
    case timeout
    case invalidResponse
    case agent(String)
    case notMeeting

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Укажите установленный meeting-agent в настройках интеграции."
        case .timeout: "Агент не ответил вовремя. Задание сохранено для повторной отправки."
        case .invalidResponse: "Агент вернул неверный ответ протокола."
        case .agent(let message): message
        case .notMeeting: "Обрабатывать можно только завершённые записи встреч."
        }
    }
}
