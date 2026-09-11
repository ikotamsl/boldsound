import Foundation
import GRDB
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class MeetingAgentTests: XCTestCase {
    private func config(enabled: Bool = true) -> MeetingAgentConfiguration {
        MeetingAgentConfiguration(
            enabled: enabled, executablePath: "/usr/bin/true", vaultPath: "/tmp/test-vault", profileID: "local",
            profileFingerprints: ["local": "local-revision"])
    }
    private func meeting(folder: String = "/tmp/meeting-agent-tests") -> Transcription {
        Transcription(
            fileName: "Synthetic meeting", filePath: folder + "/playback.wav", meetingArtifactFolderPath: folder,
            rawTranscript: "Synthetic transcript", status: .completed, sourceType: .meeting)
    }

    func testDefaultDisabledAndNonMeetingSourcesNeverEnqueue() throws {
        let db = try DatabaseManager()
        let defaults = TranscriptionRepository(dbQueue: db.dbQueue)
        try defaults.save(meeting())
        let configuration = config()
        let enabled = TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration })
        for source in [Transcription.SourceType.file, .youtube, .podcast] {
            var record = meeting()
            record.sourceType = source
            try enabled.save(record)
        }
        var processing = meeting()
        processing.status = .processing
        try enabled.save(processing)
        XCTAssertTrue(try MeetingAgentOutboxRepository(dbQueue: db.dbQueue).pending().isEmpty)
    }

    func testCompletedSaveAndIntentAreIdempotentAndContentChangesSupersede() throws {
        let db = try DatabaseManager()
        let configuration = config()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration })
        let outbox = MeetingAgentOutboxRepository(dbQueue: db.dbQueue)
        var record = meeting()
        try repo.save(record)
        try repo.save(record)
        let first = try XCTUnwrap(outbox.pending().first)
        XCTAssertEqual(try outbox.pending().count, 1)
        record.rawTranscript = "Updated synthetic transcript"
        record.updatedAt = Date().addingTimeInterval(1)
        try repo.save(record)
        let next = try XCTUnwrap(outbox.pending().first)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertEqual(try outbox.pending().count, 1)
        let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(next.payload.utf8))
        XCTAssertEqual(payload["source"]["text"].string, record.rawTranscript)
        XCTAssertEqual(payload["source"]["id"].string, record.id.uuidString.lowercased())
        XCTAssertEqual(payload["profile_id"].string, "local")
        XCTAssertEqual(payload["expected_profile_fingerprint"].string, "local-revision")
    }

    func testInvalidBindingRollsBackCompletedTranscriptAndOutbox() throws {
        let db = try DatabaseManager()
        let configuration = config()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration })
        let record = meeting()
        let event = MeetingCalendarSnapshot(
            confidence: .confirmed, eventIdentifier: "bad-event", title: "Event", scheduledStartAt: Date(),
            scheduledEndAt: Date().addingTimeInterval(3600))
        var eventBinding = try MeetingAgentEventBinding(
            event: event, note: MeetingAgentNote(vault: "/tmp/test-vault", path: "note.md"))
        eventBinding.noteJSON = "invalid JSON"
        try MeetingAgentEventBindingRepository(dbQueue: db.dbQueue).save(eventBinding)
        var value = record
        value.calendarEventSnapshot = event
        XCTAssertThrowsError(try repo.save(value))
        XCTAssertNil(try repo.fetch(id: value.id))
        XCTAssertTrue(try MeetingAgentOutboxRepository(dbQueue: db.dbQueue).pending().isEmpty)
    }

    func testManualCalendarBindingPreservesOriginalSnapshotAndIndependentNote() throws {
        let db = try DatabaseManager()
        let configuration = config()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration })
        var record = meeting()
        let original = MeetingCalendarSnapshot(
            confidence: .probable, eventIdentifier: "original", title: "Original",
            scheduledStartAt: Date(timeIntervalSince1970: 1000), scheduledEndAt: Date(timeIntervalSince1970: 4600),
            capturedAt: Date(timeIntervalSince1970: 1000))
        var selected = original
        selected.eventIdentifier = "selected"
        record.calendarEventSnapshot = original
        let note = MeetingAgentNote(vault: "/tmp/test-vault", path: "Chosen.md", id: "stable")
        let binding = try MeetingAgentBinding(
            id: MeetingAgentBinding.recordingKey(record.id), version: 3, calendar: selected, note: note,
            calendarWasSelected: true)
        try MeetingAgentBindingRepository(dbQueue: db.dbQueue).save(binding)
        try repo.save(record)
        let item = try XCTUnwrap(MeetingAgentOutboxRepository(dbQueue: db.dbQueue).pending().first)
        let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(item.payload.utf8))
        XCTAssertEqual(payload["source"]["calendar"]["eventIdentifier"].string, "selected")
        XCTAssertEqual(payload["source"]["original_calendar"]["eventIdentifier"].string, "original")
        XCTAssertEqual(payload["source"]["note"]["id"].string, "stable")
        XCTAssertEqual(try repo.fetch(id: record.id)?.calendarEventSnapshot, original)
    }

    func testRecurringEventBindingsUseOccurrenceStart() throws {
        let db = try DatabaseManager()
        let repo = MeetingAgentEventBindingRepository(dbQueue: db.dbQueue)
        let first = MeetingCalendarSnapshot(
            confidence: .confirmed, eventIdentifier: "series", title: "Weekly", scheduledStartAt: Date(),
            scheduledEndAt: Date().addingTimeInterval(3600))
        var second = first
        second.scheduledStartAt = first.scheduledStartAt.addingTimeInterval(7 * 86400)
        let note = MeetingAgentNote(vault: "/tmp/test-vault", path: "First.md")
        try repo.save(MeetingAgentEventBinding(event: first, note: note))
        XCTAssertNotNil(try repo.fetch(event: first))
        XCTAssertNil(try repo.fetch(event: second))
    }

    func testDraftAdoptionIsDurableAndOneShot() async throws {
        let db = try DatabaseManager()
        let service = MeetingAgentService(dbQueue: db.dbQueue, configuration: { MeetingAgentConfiguration() })
        let note = MeetingAgentNote(vault: "/tmp/test-vault", path: "Prepared.md")
        try await service.saveBinding(
            id: MeetingAgentService.draftID, calendar: nil, note: note, calendarWasSelected: false)
        let recording = UUID()
        try await service.adoptDraft(recordingID: recording)
        let adopted = try await service.binding(id: MeetingAgentBinding.recordingKey(recording))
        let draft = try await service.binding(id: MeetingAgentService.draftID)
        XCTAssertEqual(adopted?.note, note)
        XCTAssertNil(draft)
    }

    func testFailedDeliveryRemainsPendingAndReplayAcknowledges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "canonical artifact".write(
            to: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName), atomically: true,
            encoding: .utf8)
        let db = try DatabaseManager()
        let configuration = config()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration })
        try repo.save(meeting(folder: folder.path))
        let client = AgentClientFixture()
        let service = MeetingAgentService(dbQueue: db.dbQueue, client: client, configuration: { configuration })
        await service.drain()
        let pending = try await service.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotNil(pending.first?.error)
        await client.allowDelivery()
        await service.drain()
        let remaining = try await service.pending()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName)),
            "canonical artifact")
        let commands = await client.commands
        XCTAssertEqual(commands, ["enqueue", "enqueue"])
    }

    func testSessionBindingTransfersToDifferentTranscriptID() throws {
        let db = try DatabaseManager()
        let sessionID = UUID()
        let configuration = config()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration })
        let note = MeetingAgentNote(vault: "/tmp/test-vault", path: "Before.md", id: "before")
        try MeetingAgentBindingRepository(dbQueue: db.dbQueue).save(
            MeetingAgentBinding(id: MeetingAgentBinding.recordingKey(sessionID), version: 4, note: note))
        var record = meeting(folder: "/tmp/" + sessionID.uuidString)
        XCTAssertNotEqual(record.id, sessionID)
        record.status = .processing
        try repo.save(record)
        let binding = try MeetingAgentBindingRepository(dbQueue: db.dbQueue).fetch(
            id: MeetingAgentBinding.recordingKey(record.id))
        XCTAssertEqual(binding?.note, note)
        record.status = .completed
        try repo.save(record)
        let item = try XCTUnwrap(MeetingAgentOutboxRepository(dbQueue: db.dbQueue).pending().first)
        let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(item.payload.utf8))
        XCTAssertEqual(payload["source"]["note"]["id"].string, "before")
        XCTAssertEqual(payload["source"]["binding_version"], .number(4))
    }

    func testPendingManualIntentIsRebuiltAfterRebindingWithAutomationOff() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "canonical artifact".write(
            to: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName), atomically: true,
            encoding: .utf8)
        let db = try DatabaseManager()
        let configuration = config(enabled: false)
        let record = meeting(folder: folder.path)
        try TranscriptionRepository(dbQueue: db.dbQueue).save(record)
        let client = AgentClientFixture()
        let service = MeetingAgentService(dbQueue: db.dbQueue, client: client, configuration: { configuration })
        try await service.process(id: record.id)
        await service.drain()
        let pending = try await service.pending()
        XCTAssertEqual(pending.count, 1)
        await client.allowDelivery()
        let note = MeetingAgentNote(vault: "/tmp/test-vault", path: "New.md", id: "new")
        try await service.saveBinding(
            id: MeetingAgentBinding.recordingKey(record.id), calendar: nil, note: note, calendarWasSelected: false)
        let rebound = try await service.pending()
        let item = try XCTUnwrap(rebound.first)
        let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(item.payload.utf8))
        XCTAssertEqual(payload["source"]["note"]["id"].string, "new")
        await service.drain()
        let remaining = try await service.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testBindingEditPreservesOriginalProcessingProfileAndConsent() async throws {
        let db = try DatabaseManager()
        let localConfig = config()
        let record = meeting()
        try TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { localConfig }).save(record)
        let cloudConfig = MeetingAgentConfiguration(
            enabled: false, executablePath: "/usr/bin/true", profileID: "cloud",
            profileFingerprints: ["cloud": "cloud-revision", "local": "changed-revision"])
        let client = AgentClientFixture()
        await client.allowDelivery()
        let service = MeetingAgentService(dbQueue: db.dbQueue, client: client, configuration: { cloudConfig })
        try await service.saveBinding(
            id: MeetingAgentBinding.recordingKey(record.id), calendar: nil,
            note: MeetingAgentNote(vault: "/tmp/test-vault", path: "Chosen.md"), calendarWasSelected: false)
        let pending = try await service.pending()
        let item = try XCTUnwrap(pending.first)
        let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(item.payload.utf8))
        XCTAssertEqual(payload["profile_id"].string, "local")
        XCTAssertEqual(payload["expected_profile_fingerprint"].string, "local-revision")
    }

    func testInheritedEventNoteIsNotEncodedAsExplicitSelection() throws {
        let db = try DatabaseManager()
        let configuration = config()
        var record = meeting()
        let event = MeetingCalendarSnapshot(
            confidence: .confirmed, eventIdentifier: "event", title: "Event", scheduledStartAt: Date(),
            scheduledEndAt: Date().addingTimeInterval(3600))
        record.calendarEventSnapshot = event
        try MeetingAgentEventBindingRepository(dbQueue: db.dbQueue).save(
            MeetingAgentEventBinding(
                event: event, note: MeetingAgentNote(vault: "/tmp/test-vault", path: "Inherited.md")))
        try TranscriptionRepository(dbQueue: db.dbQueue, meetingAgentConfiguration: { configuration }).save(record)
        let item = try XCTUnwrap(MeetingAgentOutboxRepository(dbQueue: db.dbQueue).pending().first)
        let payload = try JSONDecoder().decode(MeetingAgentJSON.self, from: Data(item.payload.utf8))
        XCTAssertEqual(payload["source"]["note"], .null)
        XCTAssertEqual(payload["source"]["event_note"]["path"].string, "Inherited.md")
    }

    @MainActor
    func testDefaultProviderChangeRequiresRecheckAndRecordingEndClearsID() {
        XCTAssertTrue(
            MeetingAgentViewModel.requiresAutomationRecheck(
                savedProfileID: "cloud", currentDefaultProfileID: "local", makeDefault: true))
        XCTAssertTrue(
            MeetingAgentViewModel.requiresAutomationRecheck(
                savedProfileID: "local", currentDefaultProfileID: "local", makeDefault: false))
        XCTAssertFalse(
            MeetingAgentViewModel.requiresAutomationRecheck(
                savedProfileID: "other", currentDefaultProfileID: "local", makeDefault: false))
        let viewModel = MeetingAgentViewModel()
        viewModel.activeRecordingID = UUID()
        viewModel.recordingEnded()
        XCTAssertNil(viewModel.activeRecordingID)
    }

    @MainActor
    func testStatusPresentationCoversAllProtocolStates() {
        XCTAssertEqual(MeetingAgentViewModel.statusLabel("needs_action"), "Нужно действие")
        for state in ["queued", "processing", "done", "needs_action", "error", "cancelled"] {
            XCTAssertNotEqual(MeetingAgentViewModel.statusLabel(state), "Ещё не обрабатывалась")
        }
    }
}

private actor AgentClientFixture: MeetingAgentClientProtocol {
    var commands: [String] = []
    private var canDeliver = false
    func allowDelivery() { canDeliver = true }
    func call(_ command: String, payload: MeetingAgentJSON?, configuration: MeetingAgentConfiguration) async throws
        -> MeetingAgentJSON
    {
        commands.append(command)
        guard canDeliver else { throw MeetingAgentError.timeout }
        return .object(["id": .string("durable-job")])
    }
}
