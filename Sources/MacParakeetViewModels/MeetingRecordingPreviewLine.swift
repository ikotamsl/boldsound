import MacParakeetCore

public struct MeetingRecordingPreviewLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: String
    public let speakerID: String?
    public let speakerLabel: String
    public let text: String
    public let source: AudioSource?

    public init(
        id: String,
        timestamp: String,
        speakerID: String? = nil,
        speakerLabel: String,
        text: String,
        source: AudioSource?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.text = text
        self.source = source
    }

    public var speakerIdentity: String {
        speakerID ?? source?.rawValue ?? speakerLabel
    }
}
