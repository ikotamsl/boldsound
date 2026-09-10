import CryptoKit
import Foundation
import GRDB

public struct MeetingAgentOutboxItem: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "meeting_agent_outbox"
    public var id: String
    public var transcriptionID: String
    public var payload: String
    public var createdAt: Date
    public var acknowledgedAt: Date?
    public var jobID: String?
    public var error: String?
}

public protocol MeetingAgentOutboxRepositoryProtocol: Sendable {
    func pending() throws -> [MeetingAgentOutboxItem]
    func acknowledge(id: String, jobID: String) throws
    func recordError(id: String, message: String) throws
}

public final class MeetingAgentOutboxRepository: MeetingAgentOutboxRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }
    public func pending() throws -> [MeetingAgentOutboxItem] {
        try dbQueue.read {
            try MeetingAgentOutboxItem.filter(Column("acknowledgedAt") == nil).order(Column("createdAt")).fetchAll($0)
        }
    }
    public func acknowledge(id: String, jobID: String) throws {
        try dbQueue.write { db in
            guard var item = try MeetingAgentOutboxItem.fetchOne(db, key: id) else { return }
            item.acknowledgedAt = Date()
            item.jobID = jobID
            item.error = nil
            try item.update(db)
        }
    }
    public func recordError(id: String, message: String) throws {
        try dbQueue.write { db in
            guard var item = try MeetingAgentOutboxItem.fetchOne(db, key: id) else { return }
            item.error = message
            try item.update(db)
        }
    }

    /// Called by the transaction owner alongside the completed transcript save.
    public static func insertIntent(
        _ transcription: Transcription, configuration: MeetingAgentConfiguration, db: Database, force: Bool = false
    ) throws {
        guard transcription.sourceType == .meeting, transcription.status == .completed else { return }
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        guard !text.isEmpty else { return }
        let id = MeetingAgentBinding.recordingKey(transcription.id)
        let binding = try MeetingAgentBinding.fetchOne(db, key: id)
        let calendar = binding?.calendarWasSelected == true ? binding?.calendar : transcription.calendarEventSnapshot
        let note = binding?.note
        var eventNote: MeetingAgentNote?
        if let calendar,
            let eventBinding = try MeetingAgentEventBinding.fetchOne(db, key: MeetingAgentEventBinding.key(calendar))
        {
            eventNote = try JSONDecoder().decode(MeetingAgentNote.self, from: Data(eventBinding.noteJSON.utf8))
        }
        let folder = MeetingArtifactStore.sessionFolderURL(for: transcription)
        let artifactPath = folder?.appendingPathComponent(MeetingArtifactStore.transcriptFileName).path ?? ""
        let source: MeetingAgentJSON = .object([
            "id": .string(id), "title": .string(transcription.fileName),
            "created_at": try .value(transcription.createdAt), "updated_at": try .value(transcription.updatedAt),
            "text": .string(text), "artifact_path": .string(artifactPath),
            "source_type": .string("meeting"), "binding_version": .number(Double(binding?.version ?? 0)),
            "calendar": try calendar.map { try .value($0) } ?? .null,
            "original_calendar": try transcription.calendarEventSnapshot.map { try .value($0) } ?? .null,
            "note": try note.map { try .value($0) } ?? .null,
            "event_note": try eventNote.map { try .value($0) } ?? .null,
        ])
        let request: MeetingAgentJSON = .object([
            "schema_version": .number(1), "source": source,
            "profile_id": configuration.profileID.map(MeetingAgentJSON.string) ?? .null,
            "expected_profile_fingerprint": .string(
                configuration.profileID.flatMap { configuration.profileFingerprints[$0] } ?? "unverified"),
            "vault": .string(configuration.vaultPath), "force": .bool(force), "processing_version": .number(1),
        ])
        let data = try MeetingAgentJSON.encoder().encode(request)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard try MeetingAgentOutboxItem.fetchOne(db, key: hash) == nil else { return }
        // Superseded pending snapshots are acknowledged locally, never delivered later.
        try db.execute(
            sql:
                "UPDATE meeting_agent_outbox SET acknowledgedAt=?, error='superseded' WHERE transcriptionID=? AND acknowledgedAt IS NULL",
            arguments: [Date(), id])
        try MeetingAgentOutboxItem(
            id: hash, transcriptionID: id, payload: String(decoding: data, as: UTF8.self), createdAt: Date()
        ).insert(db)
    }
}
