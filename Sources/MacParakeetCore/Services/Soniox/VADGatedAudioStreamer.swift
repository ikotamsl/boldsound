import Foundation

/// Per-source VAD gate for Soniox. It never runs on the audio render thread:
/// callers hand it already-copied, 16 kHz mono Float samples from the meeting
/// processing actor.
actor VADGatedAudioStreamer {
    struct Diagnostics: Equatable, Sendable {
        var receivedSamples = 0
        var transmittedSamples = 0
        var droppedSilenceSamples = 0
        var speechStarts = 0
        var speechEnds = 0
        var vadErrors = 0
        var continuousFallback = false
        var connectionOpened = false
    }

    private static let sampleRate = 16_000
    private static let vadWindow = 4_096
    private static let preRollSamples = 2_400 // 150 ms

    private let source: RealtimeAudioSource
    private let provider: any RealtimeSpeechProvider
    private let configurationProvider: @Sendable () throws -> SonioxSessionConfiguration
    private let vad: (any MeetingVoiceActivityDetecting)?
    private let vadConfig: MeetingVADConfig

    private var vadState: MeetingVADStreamState?
    private var pendingSamples: [Float] = []
    private var pendingStartSample = 0
    private var preRoll: [Float] = []
    private var preRollStartSample = 0
    private var isSpeechActive = false
    private var isConnected = false
    private var totalOriginalSamples = 0
    private var totalTransmittedSamples = 0
    private var consecutiveVADErrors = 0
    private var keepAliveTask: Task<Void, Never>?
    private var diagnosticsState = Diagnostics()
    private var reconnecting = false
    private var disabledByFatalProviderError = false

    init(
        source: RealtimeAudioSource,
        provider: any RealtimeSpeechProvider,
        configurationProvider: @escaping @Sendable () throws -> SonioxSessionConfiguration,
        vad: (any MeetingVoiceActivityDetecting)?,
        vadConfig: MeetingVADConfig = .default
    ) {
        self.source = source
        self.provider = provider
        self.configurationProvider = configurationProvider
        self.vad = vad
        self.vadConfig = vadConfig
    }

    var diagnostics: Diagnostics { diagnosticsState }
    var events: AsyncStream<RealtimeTranscriptEvent> { get async { await provider.events } }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty, !disabledByFatalProviderError else { return }
        let startSample = totalOriginalSamples
        totalOriginalSamples += samples.count
        diagnosticsState.receivedSamples += samples.count

        if vad == nil || diagnosticsState.continuousFallback {
            try await ensureConnected(originalStartSample: startSample)
            try await transmit(samples, originalStartSample: startSample)
            return
        }

        if pendingSamples.isEmpty { pendingStartSample = startSample }
        pendingSamples.append(contentsOf: samples)
        if vadState == nil, let vad {
            vadState = await vad.makeStreamState()
        }

        while pendingSamples.count >= Self.vadWindow {
            let window = Array(pendingSamples.prefix(Self.vadWindow))
            pendingSamples.removeFirst(Self.vadWindow)
            let windowStart = pendingStartSample
            pendingStartSample += Self.vadWindow
            try await processWindow(window, originalStartSample: windowStart)
        }
    }

    func finish() async throws {
        if !pendingSamples.isEmpty {
            let tail = pendingSamples
            let tailStart = pendingStartSample
            pendingSamples = []
            if isSpeechActive || diagnosticsState.continuousFallback {
                try await ensureConnected(originalStartSample: tailStart)
                try await transmit(tail, originalStartSample: tailStart)
            } else {
                diagnosticsState.droppedSilenceSamples += tail.count
            }
        }
        keepAliveTask?.cancel()
        keepAliveTask = nil
        if isConnected { try await provider.finish() }
    }

    func cancel() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await provider.cancel()
        reset()
    }

    private func processWindow(_ window: [Float], originalStartSample: Int) async throws {
        guard let vad, let state = vadState else {
            try await ensureConnected(originalStartSample: originalStartSample)
            try await transmit(window, originalStartSample: originalStartSample)
            return
        }

        do {
            let result = try await vad.processStreamingChunk(window, state: state, config: vadConfig)
            vadState = result.state
            consecutiveVADErrors = 0

            switch result.event {
            case .speechStart:
                diagnosticsState.speechStarts += 1
                if !isSpeechActive {
                    isSpeechActive = true
                    let openingStart = preRoll.isEmpty ? originalStartSample : preRollStartSample
                    try await ensureConnected(originalStartSample: openingStart)
                    if !preRoll.isEmpty {
                        try await transmit(preRoll, originalStartSample: preRollStartSample)
                        preRoll = []
                    }
                }
                try await transmit(window, originalStartSample: originalStartSample)
            case .speechEnd:
                diagnosticsState.speechEnds += 1
                if isSpeechActive {
                    try await transmit(window, originalStartSample: originalStartSample)
                    isSpeechActive = false
                } else {
                    retainPreRoll(window, originalStartSample: originalStartSample)
                }
            case .none:
                if isSpeechActive {
                    try await transmit(window, originalStartSample: originalStartSample)
                } else {
                    diagnosticsState.droppedSilenceSamples += window.count
                    retainPreRoll(window, originalStartSample: originalStartSample)
                }
            }
        } catch {
            diagnosticsState.vadErrors += 1
            consecutiveVADErrors += 1
            if consecutiveVADErrors >= 3 {
                diagnosticsState.continuousFallback = true
                let fallbackStart = preRoll.isEmpty ? originalStartSample : preRollStartSample
                try await ensureConnected(originalStartSample: fallbackStart)
                if !preRoll.isEmpty {
                    try await transmit(preRoll, originalStartSample: preRollStartSample)
                    preRoll = []
                }
                try await transmit(window, originalStartSample: originalStartSample)
            } else {
                // Bias toward preserving speech on transient VAD errors.
                try await ensureConnected(originalStartSample: originalStartSample)
                try await transmit(window, originalStartSample: originalStartSample)
            }
        }
    }

    private func ensureConnected(originalStartSample: Int) async throws {
        guard !isConnected else { return }
        let configuration = try configurationProvider()
        let epoch = ConnectionEpoch(
            source: source,
            originalStartMs: milliseconds(forSamples: originalStartSample)
        )
        try await provider.connect(configuration: configuration, epoch: epoch)
        isConnected = true
        diagnosticsState.connectionOpened = true
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                try? await self?.sendKeepAliveIfIdle()
            }
        }
    }

    private func sendKeepAliveIfIdle() async throws {
        guard isConnected, !isSpeechActive else { return }
        try await provider.keepAlive()
    }

    private func transmit(_ samples: [Float], originalStartSample: Int) async throws {
        guard !samples.isEmpty else { return }
        let transmittedStart = totalTransmittedSamples
        let transmittedEnd = transmittedStart + samples.count
        let segment = VADSpeechSegment(
            source: source,
            originalStartMs: milliseconds(forSamples: originalStartSample),
            originalEndMs: milliseconds(forSamples: originalStartSample + samples.count),
            transmittedStartMs: milliseconds(forSamples: transmittedStart),
            transmittedEndMs: milliseconds(forSamples: transmittedEnd)
        )
        await provider.registerMappingSegment(segment)
        do {
            try await provider.appendPCM(Self.int16LEData(samples))
        } catch {
            if Self.isNonRetryableProviderError(error) {
                disabledByFatalProviderError = true
                isConnected = false
                throw error
            }
            try await reconnectAndResume(samples, originalStartSample: originalStartSample, underlying: error)
            return
        }
        totalTransmittedSamples = transmittedEnd
        diagnosticsState.transmittedSamples += samples.count
    }

    private func reconnectAndResume(
        _ samples: [Float],
        originalStartSample: Int,
        underlying: Error
    ) async throws {
        guard !reconnecting else { throw underlying }
        reconnecting = true
        defer { reconnecting = false }
        isConnected = false
        totalTransmittedSamples = 0

        let delays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)]
        var lastError: Error = underlying
        for delay in delays {
            do {
                try await Task.sleep(for: delay)
                try await ensureConnected(originalStartSample: originalStartSample)
                let segment = VADSpeechSegment(
                    source: source,
                    originalStartMs: milliseconds(forSamples: originalStartSample),
                    originalEndMs: milliseconds(forSamples: originalStartSample + samples.count),
                    transmittedStartMs: 0,
                    transmittedEndMs: milliseconds(forSamples: samples.count)
                )
                await provider.registerMappingSegment(segment)
                try await provider.appendPCM(Self.int16LEData(samples))
                totalTransmittedSamples = samples.count
                diagnosticsState.transmittedSamples += samples.count
                return
            } catch {
                isConnected = false
                lastError = error
            }
        }
        throw lastError
    }

    private func retainPreRoll(_ samples: [Float], originalStartSample: Int) {
        if preRoll.isEmpty { preRollStartSample = originalStartSample }
        preRoll.append(contentsOf: samples)
        if preRoll.count > Self.preRollSamples {
            let excess = preRoll.count - Self.preRollSamples
            preRoll.removeFirst(excess)
            preRollStartSample += excess
        }
    }

    private func reset() {
        vadState = nil
        pendingSamples = []
        preRoll = []
        isSpeechActive = false
        isConnected = false
        totalOriginalSamples = 0
        totalTransmittedSamples = 0
        consecutiveVADErrors = 0
        reconnecting = false
        disabledByFatalProviderError = false
    }

    private static func isNonRetryableProviderError(_ error: Error) -> Bool {
        guard let realtimeError = error as? SonioxRealtimeError,
              case .server(let code, let type, _, _) = realtimeError
        else {
            return false
        }
        return code == 400 || type == "invalid_request" || type == "authentication_error"
    }

    private func milliseconds(forSamples samples: Int) -> Int {
        samples * 1_000 / Self.sampleRate
    }

    static func int16LEData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
