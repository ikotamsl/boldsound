import Foundation

public enum RealtimeAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case system

    public init(_ source: AudioSource) {
        switch source {
        case .microphone: self = .microphone
        case .system: self = .system
        }
    }

    public var displayName: String {
        switch self {
        case .microphone: "Mic"
        case .system: "System"
        }
    }
}

public struct SourceSpeakerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let source: RealtimeAudioSource
    public let providerID: String

    public init(source: RealtimeAudioSource, providerID: String) {
        self.source = source
        self.providerID = providerID
    }

    public var description: String { "\(source.rawValue):\(providerID)" }
    public var displayName: String { "\(source.displayName) Speaker \(providerID)" }
}

public struct SonioxSessionConfiguration: Codable, Equatable, Sendable {
    public var apiKey: String
    public var model: String
    public var audioFormat: String
    public var sampleRate: Int
    public var numChannels: Int
    public var languageHints: [String]
    public var enableSpeakerDiarization: Bool
    public var enableLanguageIdentification: Bool
    public var enableEndpointDetection: Bool

    public init(
        apiKey: String,
        model: String = "stt-rt-v5",
        audioFormat: String = "pcm_s16le",
        sampleRate: Int = 16_000,
        numChannels: Int = 1,
        languageHints: [String] = [],
        enableSpeakerDiarization: Bool = true,
        enableLanguageIdentification: Bool = true,
        enableEndpointDetection: Bool = false
    ) {
        self.apiKey = apiKey
        self.model = model
        self.audioFormat = audioFormat
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.languageHints = languageHints
        self.enableSpeakerDiarization = enableSpeakerDiarization
        self.enableLanguageIdentification = enableLanguageIdentification
        self.enableEndpointDetection = enableEndpointDetection
    }

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case languageHints = "language_hints"
        case enableSpeakerDiarization = "enable_speaker_diarization"
        case enableLanguageIdentification = "enable_language_identification"
        case enableEndpointDetection = "enable_endpoint_detection"
    }
}

public struct SonioxToken: Codable, Equatable, Sendable {
    public let text: String
    public let startMs: Int?
    public let endMs: Int?
    public let confidence: Double?
    public let isFinal: Bool
    public let speaker: String?
    public let language: String?

    enum CodingKeys: String, CodingKey {
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
        case isFinal = "is_final"
        case speaker
        case language
    }
}

public struct RealtimeTranscriptWord: Codable, Equatable, Sendable {
    public let text: String
    public let originalStartMs: Int
    public let originalEndMs: Int
    public let confidence: Double
    public let speaker: SourceSpeakerID
    public let language: String?
    public let isFinal: Bool

    public init(
        text: String,
        originalStartMs: Int,
        originalEndMs: Int,
        confidence: Double,
        speaker: SourceSpeakerID,
        language: String?,
        isFinal: Bool
    ) {
        self.text = text
        self.originalStartMs = originalStartMs
        self.originalEndMs = originalEndMs
        self.confidence = confidence
        self.speaker = speaker
        self.language = language
        self.isFinal = isFinal
    }
}

public struct SonioxMeetingTranscriptArchive: Codable, Equatable, Sendable {
    public static let fileName = "soniox-live-transcript.json"

    public let model: String
    public let savedAt: Date
    public let words: [RealtimeTranscriptWord]

    public init(model: String = "stt-rt-v5", savedAt: Date = Date(), words: [RealtimeTranscriptWord]) {
        self.model = model
        self.savedAt = savedAt
        self.words = words
    }
}

enum SonioxMeetingTranscriptStore {
    static func save(
        _ archive: SonioxMeetingTranscriptArchive,
        folderURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = try JSONEncoder().encode(archive)
        let url = folderURL.appendingPathComponent(SonioxMeetingTranscriptArchive.fileName)
        try data.write(to: url, options: .atomic)
    }

    static func load(
        folderURL: URL,
        fileManager: FileManager = .default
    ) throws -> SonioxMeetingTranscriptArchive? {
        let url = folderURL.appendingPathComponent(SonioxMeetingTranscriptArchive.fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            SonioxMeetingTranscriptArchive.self,
            from: Data(contentsOf: url)
        )
    }
}

public struct VADSpeechSegment: Codable, Equatable, Sendable {
    public let source: RealtimeAudioSource
    public let originalStartMs: Int
    public let originalEndMs: Int
    public let transmittedStartMs: Int
    public let transmittedEndMs: Int

    public init(
        source: RealtimeAudioSource,
        originalStartMs: Int,
        originalEndMs: Int,
        transmittedStartMs: Int,
        transmittedEndMs: Int
    ) {
        self.source = source
        self.originalStartMs = originalStartMs
        self.originalEndMs = originalEndMs
        self.transmittedStartMs = transmittedStartMs
        self.transmittedEndMs = transmittedEndMs
    }

    public func originalTime(forTransmittedMs value: Int) -> Int? {
        guard transmittedStartMs <= value, value <= transmittedEndMs else { return nil }
        return originalStartMs + (value - transmittedStartMs)
    }
}

public struct ConnectionEpoch: Codable, Equatable, Sendable {
    public let id: UUID
    public let source: RealtimeAudioSource
    public let originalStartMs: Int
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        source: RealtimeAudioSource,
        originalStartMs: Int,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.originalStartMs = originalStartMs
        self.startedAt = startedAt
    }
}

public struct TranscriptGap: Codable, Equatable, Sendable {
    public let source: RealtimeAudioSource
    public let originalStartMs: Int
    public let originalEndMs: Int?

    public init(source: RealtimeAudioSource, originalStartMs: Int, originalEndMs: Int? = nil) {
        self.source = source
        self.originalStartMs = originalStartMs
        self.originalEndMs = originalEndMs
    }
}

public enum RealtimeTranscriptEvent: Equatable, Sendable {
    case connected(ConnectionEpoch)
    case transcript(final: [RealtimeTranscriptWord], provisional: [RealtimeTranscriptWord])
    case disconnected(TranscriptGap)
    case finished
    case failed(code: Int?, type: String?, message: String, requestID: String?)
}

public protocol RealtimeSpeechProvider: Sendable {
    var events: AsyncStream<RealtimeTranscriptEvent> { get async }
    func connect(configuration: SonioxSessionConfiguration, epoch: ConnectionEpoch) async throws
    func registerMappingSegment(_ segment: VADSpeechSegment) async
    func appendPCM(_ data: Data) async throws
    func keepAlive() async throws
    func finish() async throws
    func cancel() async
}

public extension RealtimeSpeechProvider {
    func registerMappingSegment(_ segment: VADSpeechSegment) async {}
}
