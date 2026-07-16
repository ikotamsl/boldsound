import Foundation
@testable import MacParakeetCore
import XCTest

final class SonioxRealtimeTests: XCTestCase {
    func testConfigurationUsesSonioxWireKeysAndDiarization() throws {
        let configuration = SonioxSessionConfiguration(
            apiKey: "secret",
            languageHints: ["en", "uz"],
            enableSpeakerDiarization: true,
            enableLanguageIdentification: true,
            enableEndpointDetection: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )

        XCTAssertEqual(object["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(object["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(object["num_channels"] as? Int, 1)
        XCTAssertEqual(object["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(object["enable_language_identification"] as? Bool, true)
        XCTAssertEqual(object["enable_endpoint_detection"] as? Bool, false)
    }

    func testSourceSpeakerIDsAreNamespaced() {
        let mic = SourceSpeakerID(source: .microphone, providerID: "1")
        let system = SourceSpeakerID(source: .system, providerID: "1")

        XCTAssertNotEqual(mic, system)
        XCTAssertEqual(mic.description, "microphone:1")
        XCTAssertEqual(mic.displayName, "Mic Speaker 1")
        XCTAssertEqual(system.displayName, "System Speaker 1")
    }

    func testVADMappingRestoresOriginalTimeline() {
        let segment = VADSpeechSegment(
            source: .system,
            originalStartMs: 12_000,
            originalEndMs: 14_000,
            transmittedStartMs: 2_000,
            transmittedEndMs: 4_000
        )

        XCTAssertEqual(segment.originalTime(forTransmittedMs: 2_750), 12_750)
        XCTAssertNil(segment.originalTime(forTransmittedMs: 1_999))
    }

    func testLanguageHintsAreNormalizedAndDeduplicated() {
        XCTAssertEqual(
            SonioxLiveSettings.normalizedLanguageHints([" EN ", "pt_BR", "en", "uz_UZ", ""]),
            ["en", "pt"]
        )
        XCTAssertEqual(SonioxLiveSettings.unsupportedLanguageHints(["en", "uz_UZ"]), ["uz_UZ"])
    }

    func testPCMConversionClampsAndUsesLittleEndianInt16() {
        let data = VADGatedAudioStreamer.int16LEData([-2, 0, 2])
        let values = data.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
        XCTAssertEqual(values, [Int16.min + 1, 0, Int16.max])
    }

    func testSonioxSubwordTokensMaterializeAsNaturalCyrillicWords() {
        let speaker = SourceSpeakerID(source: .system, providerID: "1")
        let pieces = ["О", "н", " до", " ти", "па", " не", " о", "чен", "ь", ","]
            .enumerated()
            .map { index, text in
                RealtimeTranscriptWord(
                    text: text,
                    originalStartMs: index * 100,
                    originalEndMs: (index + 1) * 100,
                    confidence: 0.9,
                    speaker: speaker,
                    language: "ru",
                    isFinal: true
                )
            }

        let words = SonioxMeetingTranscriber.materializeLexicalWords(pieces)

        XCTAssertEqual(words.map(\.text), ["Он", "до", "типа", "не", "очень,"])
        XCTAssertEqual(words.last?.originalEndMs, 1_000)
    }

    func testParallelSourcesDoNotAlternateEveryOverlappingWord() {
        let words = [
            WordTimestamp(word: "System", startMs: 0, endMs: 400, confidence: 1, speakerId: "system:1"),
            WordTimestamp(word: "Mic", startMs: 100, endMs: 300, confidence: 1, speakerId: "microphone:1"),
            WordTimestamp(word: "continues.", startMs: 450, endMs: 800, confidence: 1, speakerId: "system:1"),
            WordTimestamp(word: "reply.", startMs: 350, endMs: 600, confidence: 1, speakerId: "microphone:1"),
        ]

        let segments = TranscriptSegmenter.groupParallelSpeakersIntoSegments(words: words)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.text), ["System continues.", "Mic reply."])
    }

    func testSonioxFinalizerPreservesSpeakersAndRemovesSoundHallucinations() {
        let systemOne = SourceSpeakerID(source: .system, providerID: "1")
        let systemTwo = SourceSpeakerID(source: .system, providerID: "2")
        let microphone = SourceSpeakerID(source: .microphone, providerID: "1")
        let archive = SonioxMeetingTranscriptArchive(words: [
            realtimeWord("[music]", at: 0, confidence: 0.99, speaker: systemOne),
            realtimeWord("phantom", at: 2_000, confidence: 0.1, speaker: systemOne),
            realtimeWord("Hello", at: 5_000, speaker: systemOne),
            realtimeWord(" there.", at: 5_400, speaker: systemOne),
            realtimeWord("Different", at: 6_000, speaker: systemTwo),
            realtimeWord(" speaker.", at: 6_400, speaker: systemTwo),
            realtimeWord("My", at: 7_000, speaker: microphone),
            realtimeWord(" reply.", at: 7_300, speaker: microphone),
        ])

        let finalized = SonioxMeetingTranscriptFinalizer.finalize(archive)

        XCTAssertFalse(finalized.rawTranscript.contains("music"))
        XCTAssertFalse(finalized.rawTranscript.contains("phantom"))
        XCTAssertTrue(finalized.rawTranscript.contains("System Speaker 1: Hello there."))
        XCTAssertTrue(finalized.rawTranscript.contains("System Speaker 2: Different speaker."))
        XCTAssertTrue(finalized.rawTranscript.contains("Mic Speaker 1: My reply."))
        XCTAssertEqual(
            Set(finalized.speakers.map(\.id)),
            Set(["system:1", "system:2", "microphone:1"])
        )
        XCTAssertTrue(finalized.words.allSatisfy { $0.speakerId != nil })
    }

    func testSilentSourceNeverConnects() async throws {
        let provider = FakeRealtimeProvider()
        let vad = FakeMeetingVAD(events: [nil])
        let streamer = VADGatedAudioStreamer(
            source: .microphone,
            provider: provider,
            configurationProvider: { SonioxSessionConfiguration(apiKey: "key") },
            vad: vad
        )

        try await streamer.append(Array(repeating: 0, count: 4_096))
        try await streamer.finish()

        let connectCount = await provider.connectCount
        let appendedByteCount = await provider.appendedByteCount
        let diagnostics = await streamer.diagnostics
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(appendedByteCount, 0)
        XCTAssertFalse(diagnostics.connectionOpened)
    }

    func testSpeechOpensSessionAndRegistersTimelineMapping() async throws {
        let provider = FakeRealtimeProvider()
        let vad = FakeMeetingVAD(events: [.speechStart])
        let streamer = VADGatedAudioStreamer(
            source: .system,
            provider: provider,
            configurationProvider: { SonioxSessionConfiguration(apiKey: "key") },
            vad: vad
        )

        try await streamer.append(Array(repeating: 0.25, count: 4_096))

        let connectCount = await provider.connectCount
        let appendedByteCount = await provider.appendedByteCount
        XCTAssertEqual(connectCount, 1)
        XCTAssertGreaterThan(appendedByteCount, 0)
        let mappings = await provider.mappings
        XCTAssertEqual(mappings.first?.source, .system)
        XCTAssertEqual(mappings.first?.originalStartMs, 0)
        await streamer.cancel()
    }
}

private func realtimeWord(
    _ text: String,
    at startMs: Int,
    confidence: Double = 0.95,
    speaker: SourceSpeakerID
) -> RealtimeTranscriptWord {
    RealtimeTranscriptWord(
        text: text,
        originalStartMs: startMs,
        originalEndMs: startMs + 300,
        confidence: confidence,
        speaker: speaker,
        language: "en",
        isFinal: true
    )
}

private actor FakeRealtimeProvider: RealtimeSpeechProvider {
    private var continuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var cachedEvents: AsyncStream<RealtimeTranscriptEvent>?
    var connectCount = 0
    var appendedByteCount = 0
    var mappings: [VADSpeechSegment] = []

    var events: AsyncStream<RealtimeTranscriptEvent> {
        if let cachedEvents { return cachedEvents }
        var value: AsyncStream<RealtimeTranscriptEvent>.Continuation?
        let stream = AsyncStream<RealtimeTranscriptEvent> { value = $0 }
        continuation = value
        cachedEvents = stream
        return stream
    }

    func connect(configuration: SonioxSessionConfiguration, epoch: ConnectionEpoch) async throws {
        connectCount += 1
        continuation?.yield(.connected(epoch))
    }

    func registerMappingSegment(_ segment: VADSpeechSegment) async {
        mappings.append(segment)
    }

    func appendPCM(_ data: Data) async throws { appendedByteCount += data.count }
    func keepAlive() async throws {}
    func finish() async throws { continuation?.yield(.finished) }
    func cancel() async { continuation?.finish() }
}

private actor FakeMeetingVAD: MeetingVoiceActivityDetecting {
    private var events: [MeetingVADEvent?]

    init(events: [MeetingVADEvent?]) { self.events = events }

    func makeStreamState() async -> MeetingVADStreamState { MeetingVADStreamState() }

    func processStreamingChunk(
        _ samples: [Float],
        state: MeetingVADStreamState,
        config: MeetingVADConfig
    ) async throws -> MeetingVADResult {
        let event = events.isEmpty ? nil : events.removeFirst()
        return MeetingVADResult(state: state, event: event)
    }
}
