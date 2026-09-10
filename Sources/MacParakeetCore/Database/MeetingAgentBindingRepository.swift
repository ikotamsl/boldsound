import Foundation
import GRDB

public struct MeetingAgentBinding: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "meeting_agent_bindings"
    public var id: String
    public var version: Int
    public var calendarJSON: String?
    public var noteJSON: String?
    public var calendarWasSelected: Bool

    public init(
        id: String, version: Int = 0, calendar: MeetingCalendarSnapshot? = nil, note: MeetingAgentNote? = nil,
        calendarWasSelected: Bool = false
    ) throws {
        self.id = id
        self.version = version
        self.calendarJSON = try calendar.map {
            String(decoding: try MeetingAgentJSON.encoder().encode($0), as: UTF8.self)
        }
        self.noteJSON = try note.map { String(decoding: try MeetingAgentJSON.encoder().encode($0), as: UTF8.self) }
        self.calendarWasSelected = calendarWasSelected
    }

    public var calendar: MeetingCalendarSnapshot? {
        guard let calendarJSON else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingCalendarSnapshot.self, from: Data(calendarJSON.utf8))
    }
    public var note: MeetingAgentNote? {
        noteJSON.flatMap { try? JSONDecoder().decode(MeetingAgentNote.self, from: Data($0.utf8)) }
    }
    public static func recordingKey(_ id: UUID) -> String { id.uuidString.lowercased() }
}

public protocol MeetingAgentBindingRepositoryProtocol: Sendable {
    func fetch(id: String) throws -> MeetingAgentBinding?
    func save(_ binding: MeetingAgentBinding) throws
}

public final class MeetingAgentBindingRepository: MeetingAgentBindingRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }
    public func fetch(id: String) throws -> MeetingAgentBinding? {
        try dbQueue.read { try MeetingAgentBinding.fetchOne($0, key: id) }
    }
    public func save(_ binding: MeetingAgentBinding) throws {
        try dbQueue.write { try binding.save($0) }
    }

    /// Recording sessions and transcription rows have different UUIDs. Transfer
    /// the durable live selection in the transaction that first publishes the row.
    static func adoptSessionBinding(for transcription: Transcription, db: Database) throws {
        guard transcription.sourceType == .meeting,
            let folder = MeetingArtifactStore.sessionFolderURL(for: transcription),
            let sessionID = UUID(uuidString: folder.lastPathComponent)
        else { return }
        let sessionKey = MeetingAgentBinding.recordingKey(sessionID)
        let transcriptKey = MeetingAgentBinding.recordingKey(transcription.id)
        guard sessionKey != transcriptKey,
            try MeetingAgentBinding.fetchOne(db, key: transcriptKey) == nil,
            var binding = try MeetingAgentBinding.fetchOne(db, key: sessionKey)
        else { return }
        binding.id = transcriptKey
        try binding.insert(db)
        try MeetingAgentBinding.deleteOne(db, key: sessionKey)
    }
}
