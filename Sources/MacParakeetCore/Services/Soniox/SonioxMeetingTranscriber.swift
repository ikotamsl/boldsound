import Foundation
import OSLog

protocol MeetingRealtimeTranscribing: Sendable {
    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> { get async }
    func start(vad: (any MeetingVoiceActivityDetecting)?) async throws
    func append(_ samples: [Float], source: AudioSource) async
    func finish() async
    func cancel() async
    func archive() async -> SonioxMeetingTranscriptArchive?
}

actor SonioxMeetingTranscriber: MeetingRealtimeTranscribing {
    typealias ProviderFactory = @Sendable (RealtimeAudioSource) -> any RealtimeSpeechProvider

    private let logger = Logger(subsystem: "com.boldsound.prototype", category: "SonioxMeeting")
    private let credentialStore: any SonioxCredentialStoring
    private let languageHintsProvider: @Sendable () -> [String]
    private let providerFactory: ProviderFactory

    private var microphoneStreamer: VADGatedAudioStreamer?
    private var systemStreamer: VADGatedAudioStreamer?
    private var eventTasks: [Task<Void, Never>] = []
    private var finalWords: [RealtimeAudioSource: [RealtimeTranscriptWord]] = [:]
    private var provisionalWords: [RealtimeAudioSource: [RealtimeTranscriptWord]] = [:]
    private var continuation: AsyncStream<MeetingTranscriptUpdate>.Continuation?
    private var cachedUpdates: AsyncStream<MeetingTranscriptUpdate>?
    private var didStart = false
    private var terminalSources = Set<RealtimeAudioSource>()

    init(
        credentialStore: any SonioxCredentialStoring = SonioxCredentialStore(),
        languageHintsProvider: @escaping @Sendable () -> [String] = {
            SonioxLiveSettings.languageHints()
        },
        providerFactory: @escaping ProviderFactory = { _ in SonioxRealtimeClient() }
    ) {
        self.credentialStore = credentialStore
        self.languageHintsProvider = languageHintsProvider
        self.providerFactory = providerFactory
    }

    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> {
        if let cachedUpdates { return cachedUpdates }
        var newContinuation: AsyncStream<MeetingTranscriptUpdate>.Continuation?
        let stream = AsyncStream<MeetingTranscriptUpdate>(bufferingPolicy: .bufferingNewest(16)) {
            newContinuation = $0
        }
        continuation = newContinuation
        cachedUpdates = stream
        return stream
    }

    func start(vad: (any MeetingVoiceActivityDetecting)?) async throws {
        let key = try credentialStore.loadAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw SonioxRealtimeError.invalidConfiguration }

        _ = transcriptUpdates
        didStart = true
        terminalSources = []
        finalWords = [:]
        provisionalWords = [:]
        let hints = SonioxLiveSettings.normalizedLanguageHints(languageHintsProvider())
        let configuration: @Sendable () throws -> SonioxSessionConfiguration = {
            SonioxSessionConfiguration(
                apiKey: key,
                languageHints: hints,
                enableSpeakerDiarization: true,
                enableLanguageIdentification: true,
                enableEndpointDetection: false
            )
        }

        let micProvider = providerFactory(.microphone)
        let systemProvider = providerFactory(.system)
        let mic = VADGatedAudioStreamer(
            source: .microphone,
            provider: micProvider,
            configurationProvider: configuration,
            vad: vad
        )
        let system = VADGatedAudioStreamer(
            source: .system,
            provider: systemProvider,
            configurationProvider: configuration,
            vad: vad
        )
        microphoneStreamer = mic
        systemStreamer = system

        let micEvents = await mic.events
        eventTasks.append(Task { [weak self] in
            for await event in micEvents { await self?.handle(event, source: .microphone) }
        })
        let systemEvents = await system.events
        eventTasks.append(Task { [weak self] in
            for await event in systemEvents { await self?.handle(event, source: .system) }
        })
    }

    func append(_ samples: [Float], source: AudioSource) async {
        do {
            switch source {
            case .microphone:
                try await microphoneStreamer?.append(samples)
            case .system:
                try await systemStreamer?.append(samples)
            }
        } catch {
            logger.error(
                "soniox_append_failed source=\(source.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func finish() async {
        var openedSources = Set<RealtimeAudioSource>()
        if await microphoneStreamer?.diagnostics.connectionOpened == true {
            openedSources.insert(.microphone)
        }
        if await systemStreamer?.diagnostics.connectionOpened == true {
            openedSources.insert(.system)
        }
        do { try await microphoneStreamer?.finish() } catch {
            logger.error("soniox_mic_finish_failed error=\(error.localizedDescription, privacy: .public)")
        }
        do { try await systemStreamer?.finish() } catch {
            logger.error("soniox_system_finish_failed error=\(error.localizedDescription, privacy: .public)")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !openedSources.isSubset(of: terminalSources), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !openedSources.isSubset(of: terminalSources) {
            let missing = openedSources.subtracting(terminalSources).map(\.rawValue).sorted().joined(separator: ",")
            logger.error("soniox_finish_timeout sources=\(missing, privacy: .public)")
        }
    }

    func cancel() async {
        for task in eventTasks { task.cancel() }
        eventTasks = []
        await microphoneStreamer?.cancel()
        await systemStreamer?.cancel()
        microphoneStreamer = nil
        systemStreamer = nil
        continuation?.finish()
        continuation = nil
        cachedUpdates = nil
        finalWords = [:]
        provisionalWords = [:]
        didStart = false
        terminalSources = []
    }

    func archive() -> SonioxMeetingTranscriptArchive? {
        guard didStart else { return nil }
        let words = RealtimeAudioSource.allCases
            .flatMap { Self.materializeLexicalWords(finalWords[$0] ?? []) }
            .sorted {
                if $0.originalStartMs == $1.originalStartMs {
                    return $0.speaker.description < $1.speaker.description
                }
                return $0.originalStartMs < $1.originalStartMs
            }
        return SonioxMeetingTranscriptArchive(words: words)
    }

    private func handle(_ event: RealtimeTranscriptEvent, source: RealtimeAudioSource) {
        switch event {
        case .transcript(let final, let provisional):
            if !final.isEmpty { finalWords[source, default: []].append(contentsOf: final) }
            provisionalWords[source] = provisional
            continuation?.yield(currentUpdate())
        case .failed(_, let type, let message, let requestID):
            terminalSources.insert(source)
            logger.error(
                "soniox_session_failed source=\(source.rawValue, privacy: .public) type=\(type ?? "unknown", privacy: .public) request_id=\(requestID ?? "none", privacy: .public) message=\(message, privacy: .public)"
            )
        case .disconnected, .finished:
            terminalSources.insert(source)
        case .connected:
            break
        }
    }

    private func currentUpdate() -> MeetingTranscriptUpdate {
        let realtimeWords = RealtimeAudioSource.allCases
            .flatMap {
                Self.materializeLexicalWords(
                    (finalWords[$0] ?? []) + (provisionalWords[$0] ?? [])
                )
            }
            .sorted {
                if $0.originalStartMs == $1.originalStartMs {
                    return $0.speaker.description < $1.speaker.description
                }
                return $0.originalStartMs < $1.originalStartMs
            }
        let words = realtimeWords.map {
            WordTimestamp(
                word: $0.text,
                startMs: $0.originalStartMs,
                endMs: $0.originalEndMs,
                confidence: $0.confidence,
                speakerId: $0.speaker.description
            )
        }
        let speakers = Dictionary(grouping: realtimeWords, by: \.speaker)
            .keys
            .sorted { $0.description < $1.description }
            .map { SpeakerInfo(id: $0.description, label: $0.displayName) }
        return MeetingTranscriptUpdate(words: words, speakers: speakers)
    }

    /// Soniox emits model tokens rather than display-ready words. A leading
    /// whitespace starts a new lexical word; tokens without it continue the
    /// previous word (including punctuation). Preserve the first/last token
    /// timestamps while collapsing those pieces for transcript presentation.
    static func materializeLexicalWords(
        _ tokens: [RealtimeTranscriptWord]
    ) -> [RealtimeTranscriptWord] {
        guard !tokens.isEmpty else { return [] }

        var result: [RealtimeTranscriptWord] = []
        var current: RealtimeTranscriptWord?

        func flush() {
            guard let value = current else { return }
            let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(
                    RealtimeTranscriptWord(
                        text: text,
                        originalStartMs: value.originalStartMs,
                        originalEndMs: value.originalEndMs,
                        confidence: value.confidence,
                        speaker: value.speaker,
                        language: value.language,
                        isFinal: value.isFinal
                    )
                )
            }
            current = nil
        }

        for token in tokens {
            let startsNewWord = token.text.first?.isWhitespace == true
            guard !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            if let existing = current,
               existing.speaker == token.speaker,
               !startsNewWord
            {
                current = RealtimeTranscriptWord(
                    text: existing.text + token.text,
                    originalStartMs: existing.originalStartMs,
                    originalEndMs: max(existing.originalEndMs, token.originalEndMs),
                    confidence: min(existing.confidence, token.confidence),
                    speaker: existing.speaker,
                    language: token.language ?? existing.language,
                    isFinal: existing.isFinal && token.isFinal
                )
            } else {
                flush()
                current = token
            }
        }
        flush()
        return result
    }
}
