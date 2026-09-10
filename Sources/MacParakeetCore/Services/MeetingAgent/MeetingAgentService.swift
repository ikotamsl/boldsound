import Foundation
import GRDB

public actor MeetingAgentService {
    public static let draftID = "next-recording"
    private let dbQueue: DatabaseQueue
    private let client: any MeetingAgentClientProtocol
    private let configuration: @Sendable () -> MeetingAgentConfiguration
    private let outbox: MeetingAgentOutboxRepository
    private let bindings: MeetingAgentBindingRepository
    private var isDraining = false
    private var isMutating = false

    public init(
        dbQueue: DatabaseQueue, client: any MeetingAgentClientProtocol = MeetingAgentClient(),
        configuration: @escaping @Sendable () -> MeetingAgentConfiguration = { .current() }
    ) {
        self.dbQueue = dbQueue
        self.client = client
        self.configuration = configuration
        self.outbox = MeetingAgentOutboxRepository(dbQueue: dbQueue)
        self.bindings = MeetingAgentBindingRepository(dbQueue: dbQueue)
    }

    public func call(_ command: String, payload: MeetingAgentJSON? = nil, profileID: String? = nil) async throws
        -> MeetingAgentJSON
    {
        var config = configuration()
        if let profileID { config.profileID = profileID }
        return try await client.call(command, payload: payload, configuration: config)
    }

    public func binding(id: String) throws -> MeetingAgentBinding? { try bindings.fetch(id: id) }

    public func adoptDraft(recordingID: UUID) throws {
        try dbQueue.write { db in
            guard var draft = try MeetingAgentBinding.fetchOne(db, key: Self.draftID) else { return }
            let key = MeetingAgentBinding.recordingKey(recordingID)
            guard try MeetingAgentBinding.fetchOne(db, key: key) == nil else { return }
            draft.id = key
            try draft.insert(db)
            try MeetingAgentBinding.deleteOne(db, key: Self.draftID)
        }
    }

    public func saveBinding(
        id: String, calendar: MeetingCalendarSnapshot?, note: MeetingAgentNote?, calendarWasSelected: Bool
    ) async throws {
        try await acquireMutation()
        defer { isMutating = false }
        let config = configuration()
        // Invalidate the worker first. A failed handshake leaves the old binding
        // selected, so the UI cannot promise a change while an old job can commit.
        let previousIntent = try await dbQueue.read { db in
            try MeetingAgentOutboxItem.filter(Column("transcriptionID") == id).order(Column("createdAt").desc).fetchOne(
                db)
        }
        var deliveryConfig = config
        if let previousIntent {
            let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(previousIntent.payload.utf8))
            deliveryConfig.profileID = payload["profile_id"].string
            deliveryConfig.profileFingerprints = [:]
            if let profileID = deliveryConfig.profileID,
                let fingerprint = payload["expected_profile_fingerprint"].string
            {
                deliveryConfig.profileFingerprints[profileID] = fingerprint
            }
        }
        let bindingConfiguration = deliveryConfig
        if !config.executablePath.isEmpty, id != Self.draftID {
            _ = try await client.call("invalidate", payload: .object(["source_id": .string(id)]), configuration: config)
        }
        if !config.executablePath.isEmpty, let calendar, let note {
            _ = try await client.call(
                "bind",
                payload: .object([
                    "event_only": .bool(true), "calendar": try .value(calendar), "note": try .value(note),
                ]), configuration: config)
        }
        try await dbQueue.write { db in
            let previous = try MeetingAgentBinding.fetchOne(db, key: id)
            let binding = try MeetingAgentBinding(
                id: id, version: (previous?.version ?? 0) + 1, calendar: calendar, note: note,
                calendarWasSelected: calendarWasSelected)
            try binding.save(db)
            if let calendar, let note { try MeetingAgentEventBinding(event: calendar, note: note).save(db) }
            if let uuid = UUID(uuidString: id), let transcription = try Transcription.fetchOne(db, key: uuid),
                config.enabled || previousIntent != nil
            {
                try MeetingAgentOutboxRepository.insertIntent(
                    transcription, configuration: bindingConfiguration, db: db)
            }
        }
    }

    public func process(id: UUID, profileID: String? = nil, force: Bool = false) async throws {
        try await acquireMutation()
        defer { isMutating = false }
        var config = configuration()
        if let profileID { config.profileID = profileID }
        let key = MeetingAgentBinding.recordingKey(id)
        let hasExistingIntent = try await dbQueue.read { db in
            try MeetingAgentOutboxItem.filter(Column("transcriptionID") == key).fetchCount(db) > 0
        }
        if hasExistingIntent, !config.executablePath.isEmpty {
            _ = try await client.call(
                "invalidate", payload: .object(["source_id": .string(MeetingAgentBinding.recordingKey(id))]),
                configuration: config)
        }
        let snapshot = config
        try await dbQueue.write { db in
            guard let transcription = try Transcription.fetchOne(db, key: id), transcription.sourceType == .meeting,
                transcription.status == .completed
            else {
                throw MeetingAgentError.notMeeting
            }
            // A manual rerun is a new processing revision, even with unchanged text.
            var binding =
                try MeetingAgentBinding.fetchOne(db, key: MeetingAgentBinding.recordingKey(id))
                ?? MeetingAgentBinding(id: MeetingAgentBinding.recordingKey(id))
            binding.version += 1
            try binding.save(db)
            try MeetingAgentOutboxRepository.insertIntent(transcription, configuration: snapshot, db: db, force: force)
        }
    }

    private func acquireMutation() async throws {
        while isMutating || isDraining { try await Task.sleep(for: .milliseconds(30)) }
        isMutating = true
    }

    public func pending() throws -> [MeetingAgentOutboxItem] { try outbox.pending() }

    public func drain() async {
        guard !isDraining, !isMutating, !configuration().executablePath.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }
        guard let items = try? outbox.pending() else { return }
        for item in items {
            do {
                try Task.checkCancellation()
                // Wait for the artifact owner without rewriting its files.
                let transcription = try await dbQueue.read { db -> Transcription? in
                    guard let id = UUID(uuidString: item.transcriptionID) else { return nil }
                    return try Transcription.fetchOne(db, key: id)
                }
                guard let transcription, transcription.status == .completed, transcription.sourceType == .meeting else {
                    try outbox.recordError(id: item.id, message: "Исходная встреча недоступна или ещё обрабатывается.")
                    continue
                }
                let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(item.payload.utf8))
                guard
                    payload["source"]["text"].string
                        == (transcription.cleanTranscript ?? transcription.rawTranscript ?? "")
                else {
                    throw MeetingAgentError.agent("Транскрипт изменился. Запустите обработку заново.")
                }
                guard let path = payload["source"]["artifact_path"].string, !path.isEmpty,
                    FileManager.default.isReadableFile(atPath: path)
                else {
                    throw MeetingAgentError.agent("Ожидаем сохранения локального артефакта встречи.")
                }
                // Delivery only reads canonical artifacts; their existing owner
                // materializes them. Retrying must never overwrite newer sidecars.
                guard try outbox.pending().contains(where: { $0.id == item.id }) else { continue }
                let response = try await client.call("enqueue", payload: payload, configuration: configuration())
                guard let jobID = response["id"].string else { throw MeetingAgentError.invalidResponse }
                try outbox.acknowledge(id: item.id, jobID: jobID)
            } catch {
                try? outbox.recordError(id: item.id, message: error.localizedDescription)
            }
        }
    }
}
