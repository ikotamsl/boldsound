import Foundation
import GRDB

public struct MeetingAgentEventBinding: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "meeting_agent_event_bindings"
    public var id: String
    public var calendarJSON: String
    public var noteJSON: String

    public static func key(_ event: MeetingCalendarSnapshot) -> String {
        event.eventIdentifier + "@" + ISO8601DateFormatter().string(from: event.scheduledStartAt)
    }

    public init(event: MeetingCalendarSnapshot, note: MeetingAgentNote) throws {
        id = Self.key(event)
        calendarJSON = String(decoding: try MeetingAgentJSON.encoder().encode(event), as: UTF8.self)
        noteJSON = String(decoding: try MeetingAgentJSON.encoder().encode(note), as: UTF8.self)
    }
}

public protocol MeetingAgentEventBindingRepositoryProtocol: Sendable {
    func fetch(event: MeetingCalendarSnapshot) throws -> MeetingAgentEventBinding?
    func save(_ binding: MeetingAgentEventBinding) throws
}

public final class MeetingAgentEventBindingRepository: MeetingAgentEventBindingRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }
    public func fetch(event: MeetingCalendarSnapshot) throws -> MeetingAgentEventBinding? {
        try dbQueue.read { try MeetingAgentEventBinding.fetchOne($0, key: MeetingAgentEventBinding.key(event)) }
    }
    public func save(_ binding: MeetingAgentEventBinding) throws {
        try dbQueue.write { try binding.save($0) }
    }
}
