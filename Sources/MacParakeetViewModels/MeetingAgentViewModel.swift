import Foundation
import Observation
import MacParakeetCore

@MainActor
@Observable
public final class MeetingAgentViewModel {
    public static let shared = MeetingAgentViewModel()
    public private(set) var service: MeetingAgentService?
    public private(set) var jobs: [MeetingAgentJSON] = []
    public private(set) var profiles: [MeetingAgentJSON] = []
    public private(set) var pendingCount = 0
    public private(set) var pendingItems: [MeetingAgentOutboxItem] = []
    public var activeRecordingID: UUID?
    public var errorMessage: String?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private let calendarService: any CalendarServicing

    public init(calendarService: any CalendarServicing = CalendarService.shared) {
        self.calendarService = calendarService
    }

    public func configure(service: MeetingAgentService) {
        pollingTask?.cancel()
        self.service = service
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    public func refresh() async {
        guard let service, !MeetingAgentConfiguration.current().executablePath.isEmpty else { return }
        await service.drain()
        do {
            pendingItems = try await service.pending()
            pendingCount = pendingItems.count
            let response = try await service.call("jobs", payload: .object([:]))
            jobs = response["jobs"].array
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadProfiles() async throws {
        guard let service else { throw MeetingAgentError.unavailable }
        let response = try await service.call("profiles", payload: .object(["action": .string("list")]))
        profiles = response["profiles"].array
        if case .object(let fingerprints) = response["fingerprints"] {
            let defaults = UserDefaults.standard
            let updated = fingerprints.compactMapValues(\.string)
            let previous = defaults.dictionary(forKey: "meetingAgentProfileFingerprints") as? [String: String] ?? [:]
            if let id = defaults.string(forKey: "meetingAgentProfileID"), previous[id] != updated[id] {
                defaults.set(false, forKey: "meetingAgentEnabled")
                defaults.set("", forKey: "meetingAgentVerifiedProfileID")
            }
            defaults.set(updated, forKey: "meetingAgentProfileFingerprints")
        }
    }

    public func command(_ command: String, payload: MeetingAgentJSON? = nil, profileID: String? = nil) async throws
        -> MeetingAgentJSON
    {
        guard let service else { throw MeetingAgentError.unavailable }
        return try await service.call(command, payload: payload, profileID: profileID)
    }

    public func searchEvents(on date: Date, query: String) async throws -> [CalendarEvent] {
        let from = Calendar.current.startOfDay(for: date)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: from)!
        return try await calendarService.searchEvents(from: from, to: to, query: query)
    }

    public func requestCalendarPermission() async -> Bool { await calendarService.requestPermission() }

    public func recordingStarted(id: UUID) async {
        do {
            try await service?.adoptDraft(recordingID: id)
            activeRecordingID = id
        } catch { errorMessage = error.localizedDescription }
    }

    public func process(_ id: UUID, profileID: String? = nil, force: Bool = false) async {
        do {
            guard let service else { throw MeetingAgentError.unavailable }
            try await service.process(id: id, profileID: profileID, force: force)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    public func latestJob(for id: UUID) -> MeetingAgentJSON? {
        jobs.first { $0["source_id"].string?.lowercased() == id.uuidString.lowercased() }
    }

    public func recordingEnded() { activeRecordingID = nil }

    public static func requiresAutomationRecheck(
        savedProfileID: String, currentDefaultProfileID: String, makeDefault: Bool
    ) -> Bool {
        savedProfileID == currentDefaultProfileID || (makeDefault && savedProfileID != currentDefaultProfileID)
    }

    public static func statusLabel(_ state: String?) -> String {
        switch state {
        case "queued": "В очереди"
        case "processing": "Обрабатывается"
        case "done": "Готово"
        case "needs_action": "Нужно действие"
        case "error": "Ошибка"
        case "cancelled": "Отменено"
        default: "Ещё не обрабатывалась"
        }
    }
}
