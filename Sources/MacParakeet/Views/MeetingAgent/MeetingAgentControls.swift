import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

struct MeetingAgentControls: View {
    var transcription: Transcription? = nil
    @Bindable private var agent = MeetingAgentViewModel.shared
    @State private var showingBindings = false
    @State private var profileID = ""
    @State private var showingConflict = false

    private var bindingID: String {
        (transcription?.id ?? agent.activeRecordingID).map(MeetingAgentBinding.recordingKey)
            ?? MeetingAgentService.draftID
    }
    private var job: MeetingAgentJSON? { transcription.flatMap { agent.latestJob(for: $0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Obsidian", systemImage: "doc.text")
                Spacer()
                if let job { Text(MeetingAgentViewModel.statusLabel(job["state"].string)).foregroundStyle(.secondary) }
                Button("Событие и заметка") { showingBindings = true }
                    .parakeetAction(.secondary)
            }
            if let transcription, transcription.status == .completed {
                HStack {
                    Picker("Профиль", selection: $profileID) {
                        Text("По умолчанию").tag("")
                        ForEach(Array(agent.profiles.enumerated()), id: \.offset) { _, profile in
                            Text(
                                (profile["name"].string ?? "")
                                    + (profile["execution"].string == "local" ? " · локально" : " · облако")
                            )
                            .tag(profile["id"].string ?? "")
                        }
                    }
                    .frame(maxWidth: 280)
                    Button(job == nil ? "Обработать" : "Обработать заново") {
                        Task { await agent.process(transcription.id, profileID: profileID.isEmpty ? nil : profileID) }
                    }
                    .parakeetAction(.secondary)
                    if let job, ["queued", "processing"].contains(job["state"].string ?? "") {
                        Button("Отменить") { jobAction("cancel", job: job) }.parakeetAction(.secondary)
                    }
                    if let job, ["error", "needs_action", "cancelled"].contains(job["state"].string ?? "") {
                        Button("Повторить") { jobAction("retry", job: job) }.parakeetAction(.secondary)
                    }
                    if let note = job?["note"], let path = note["path"].string, let vault = note["vault"].string {
                        Button("Открыть заметку") {
                            var components = URLComponents()
                            components.scheme = "obsidian"
                            components.host = "open"
                            components.queryItems = [
                                URLQueryItem(
                                    name: "path", value: URL(fileURLWithPath: vault).appendingPathComponent(path).path)
                            ]
                            if let url = components.url { NSWorkspace.shared.open(url) }
                        }.parakeetAction(.secondary)
                    }
                }
                if let error = agent.pendingItems.first(where: {
                    $0.transcriptionID == transcription.id.uuidString.lowercased()
                })?.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if let error = job?["error"].string { Text(error).font(.caption).foregroundStyle(.secondary) }
                if job?["details"]["code"].string == "note_conflict" {
                    Button("Посмотреть конфликт") { showingConflict = true }.parakeetAction(.secondary)
                }
            } else {
                Text("Событие и заметку можно выбрать независимо — до записи и во время встречи.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if agent.pendingCount > 0 { Text("Ожидают отправки: \(agent.pendingCount)").font(.caption) }
            if let message = agent.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingBindings) {
            MeetingAgentBindingSheet(bindingID: bindingID, originalCalendar: transcription?.calendarEventSnapshot)
        }
        .sheet(isPresented: $showingConflict) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Изменён блок агента").font(.headline)
                Text("Замена затронет только блоки агента. Ручные разделы заметки сохранятся.")
                ScrollView {
                    Text(job?["details"]["detail"].string ?? "Проверьте текущую заметку перед заменой.").font(
                        .system(.body, design: .monospaced)
                    ).textSelection(.enabled)
                }
                HStack {
                    Button("Закрыть") { showingConflict = false }.parakeetAction(.secondary)
                    Spacer()
                    Button("Пересчитать и заменить блоки") {
                        if let transcription {
                            Task {
                                await agent.process(
                                    transcription.id, profileID: profileID.isEmpty ? nil : profileID, force: true)
                            }
                        }
                        showingConflict = false
                    }.parakeetAction(.secondary)
                }
            }.padding(24).frame(width: 700, height: 460)
        }
        .task { try? await agent.loadProfiles() }
    }

    private func jobAction(_ command: String, job: MeetingAgentJSON) {
        Task {
            do {
                _ = try await agent.command(command, payload: .object(["id": job["id"]]))
                await agent.refresh()
            } catch { agent.errorMessage = error.localizedDescription }
        }
    }
}

private struct MeetingAgentBindingSheet: View {
    let bindingID: String
    let originalCalendar: MeetingCalendarSnapshot?
    @Environment(\.dismiss) private var dismiss
    @Bindable private var agent = MeetingAgentViewModel.shared
    @State private var selectedCalendar: MeetingCalendarSnapshot?
    @State private var selectedNote: MeetingAgentNote?
    @State private var calendarWasSelected = false
    @State private var date = Date()
    @State private var query = ""
    @State private var events: [CalendarEvent] = []
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Привязки встречи").font(.title2)
            Text("Выберите событие, заметку или оба объекта. Для будущего события связь сохранится заранее.")
                .foregroundStyle(.secondary)
            HStack {
                DatePicker("Дата", selection: $date, displayedComponents: .date)
                TextField("Название события", text: $query)
                Button("Найти") { search() }.parakeetAction(.secondary)
            }
            List(events, id: \.dedupeKey) { event in
                Button {
                    selectedCalendar = MeetingCalendarSnapshot(event: event, confidence: .confirmed)
                    calendarWasSelected = true
                } label: {
                    HStack {
                        Text(event.title); Spacer(); Text(event.formattedTimeRange).foregroundStyle(.secondary)
                    }
                }.parakeetAction(.secondary)
            }.frame(height: 150)
            HStack {
                Text(selectedCalendar?.title ?? "Событие не выбрано")
                Spacer()
                Button("Очистить событие") {
                    selectedCalendar = nil; calendarWasSelected = true
                }.parakeetAction(.secondary)
                Button("Доступ к календарю") {
                    Task {
                        _ = await agent.requestCalendarPermission(); search()
                    }
                }.parakeetAction(.secondary)
            }
            Divider()
            HStack {
                Text(selectedNote?.path ?? "Заметка будет найдена автоматически")
                Spacer()
                Button("Выбрать .md") { chooseNote() }.parakeetAction(.secondary)
                Button("Очистить заметку") { selectedNote = nil }.parakeetAction(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }.parakeetAction(.secondary)
                Spacer()
                Button("Сохранить") { save() }.parakeetAction(.secondary).disabled(busy)
            }
        }.padding(24).frame(width: 730)
            .task {
                do {
                    let binding = try await agent.service?.binding(id: bindingID)
                    selectedCalendar = binding?.calendarWasSelected == true ? binding?.calendar : originalCalendar
                    calendarWasSelected = binding?.calendarWasSelected ?? false
                    selectedNote = binding?.note
                } catch { message = error.localizedDescription }
                search()
            }
    }

    private func search() {
        Task {
            do { events = try await agent.searchEvents(on: date, query: query); message = nil } catch {
                message = error.localizedDescription
            }
        }
    }
    private func chooseNote() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = URL(fileURLWithPath: MeetingAgentConfiguration.current().vaultPath)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let vault = URL(fileURLWithPath: MeetingAgentConfiguration.current().vaultPath).standardizedFileURL
                    let prefix = vault.path + "/"
                    guard url.standardizedFileURL.path.hasPrefix(prefix) else {
                        throw MeetingAgentError.agent("Выберите заметку внутри настроенного vault.")
                    }
                    let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                    let result = try await agent.command(
                        "notes", payload: .object(["vault": .string(vault.path), "path": .string(path)]))
                    selectedNote = try result["note"].decoded(MeetingAgentNote.self)
                } catch { message = error.localizedDescription }
            }
        }
    }
    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let service = agent.service else { throw MeetingAgentError.unavailable }
                try await service.saveBinding(
                    id: bindingID, calendar: selectedCalendar, note: selectedNote,
                    calendarWasSelected: calendarWasSelected)
                await agent.refresh()
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}
