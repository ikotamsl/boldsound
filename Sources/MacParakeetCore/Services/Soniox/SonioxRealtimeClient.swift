import Foundation
import OSLog

public enum SonioxRealtimeError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case alreadyConnected
    case notConnected
    case invalidConfiguration
    case transport(String)
    case server(code: Int?, type: String?, message: String, requestID: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The Soniox WebSocket endpoint is invalid."
        case .alreadyConnected: "A Soniox session is already connected."
        case .notConnected: "The Soniox session is not connected."
        case .invalidConfiguration: "The Soniox session configuration is invalid."
        case .transport(let message): "Soniox connection failed: \(message)"
        case .server(_, _, let message, _): "Soniox rejected the session: \(message)"
        }
    }
}

public actor SonioxRealtimeClient: RealtimeSpeechProvider {
    public static let endpoint = "wss://stt-rt.soniox.com/transcribe-websocket"

    private struct ServerResponse: Decodable {
        let tokens: [SonioxToken]?
        let finished: Bool?
        let errorCode: Int?
        let errorType: String?
        let errorMessage: String?
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case tokens, finished
            case errorCode = "error_code"
            case errorType = "error_type"
            case errorMessage = "error_message"
            case requestID = "request_id"
        }
    }

    private let logger = Logger(subsystem: "com.boldsound.prototype", category: "SonioxRealtime")
    private let session: URLSession
    private let endpointURL: URL
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var epoch: ConnectionEpoch?
    private var source: RealtimeAudioSource?
    private var finalTokens: [SonioxToken] = []
    private var mappingSegments: [VADSpeechSegment] = []
    private var terminalError: SonioxRealtimeError?
    private var continuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var cachedEvents: AsyncStream<RealtimeTranscriptEvent>?

    public init(
        session: URLSession = .shared,
        endpointURL: URL? = URL(string: SonioxRealtimeClient.endpoint)
    ) {
        self.session = session
        self.endpointURL = endpointURL ?? URL(fileURLWithPath: "/invalid-soniox-endpoint")
    }

    public var events: AsyncStream<RealtimeTranscriptEvent> {
        if let cachedEvents { return cachedEvents }
        var newContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
        let stream = AsyncStream<RealtimeTranscriptEvent>(bufferingPolicy: .bufferingNewest(64)) {
            newContinuation = $0
        }
        continuation = newContinuation
        cachedEvents = stream
        return stream
    }

    public func connect(
        configuration: SonioxSessionConfiguration,
        epoch: ConnectionEpoch
    ) async throws {
        guard task == nil else { throw SonioxRealtimeError.alreadyConnected }
        guard endpointURL.scheme == "wss" else { throw SonioxRealtimeError.invalidEndpoint }
        guard !configuration.apiKey.isEmpty,
              configuration.model == "stt-rt-v5",
              configuration.audioFormat == "pcm_s16le",
              configuration.sampleRate == 16_000,
              configuration.numChannels == 1
        else {
            throw SonioxRealtimeError.invalidConfiguration
        }

        _ = events
        let socket = session.webSocketTask(with: endpointURL)
        task = socket
        self.epoch = epoch
        source = epoch.source
        finalTokens = []
        mappingSegments = []
        terminalError = nil
        socket.resume()

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(configuration)
            guard let json = String(data: data, encoding: .utf8) else {
                throw SonioxRealtimeError.invalidConfiguration
            }
            try await socket.send(.string(json))
        } catch {
            task = nil
            socket.cancel(with: .goingAway, reason: nil)
            throw SonioxRealtimeError.transport(error.localizedDescription)
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket)
        }
        continuation?.yield(.connected(epoch))
    }

    public func registerMappingSegment(_ segment: VADSpeechSegment) {
        guard segment.source == source else { return }
        mappingSegments.append(segment)
    }

    public func appendPCM(_ data: Data) async throws {
        guard let task else { throw terminalError ?? SonioxRealtimeError.notConnected }
        guard !data.isEmpty else { return }
        do {
            try await task.send(.data(data))
        } catch {
            self.task = nil
            task.cancel(with: .goingAway, reason: nil)
            throw SonioxRealtimeError.transport(error.localizedDescription)
        }
    }

    public func keepAlive() async throws {
        guard let task else { throw SonioxRealtimeError.notConnected }
        do {
            try await task.send(.string("{\"type\":\"keepalive\"}"))
        } catch {
            self.task = nil
            task.cancel(with: .goingAway, reason: nil)
            throw SonioxRealtimeError.transport(error.localizedDescription)
        }
    }

    public func finish() async throws {
        guard let task else { return }
        do {
            try await task.send(.data(Data()))
        } catch {
            throw SonioxRealtimeError.transport(error.localizedDescription)
        }
    }

    public func cancel() async {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
        cachedEvents = nil
        epoch = nil
        source = nil
        finalTokens = []
        mappingSegments = []
        terminalError = nil
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let received): data = received
                @unknown default: continue
                }
                try handleResponse(data)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("soniox_receive_failed error=\(error.localizedDescription, privacy: .public)")
                if let source {
                    continuation?.yield(
                        .disconnected(
                            TranscriptGap(
                                source: source,
                                originalStartMs: latestOriginalEndMs()
                            )
                        )
                    )
                }
                task = nil
                return
            }
        }
    }

    private func handleResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(ServerResponse.self, from: data)
        if let message = response.errorMessage {
            let error = SonioxRealtimeError.server(
                code: response.errorCode,
                type: response.errorType,
                message: message,
                requestID: response.requestID
            )
            terminalError = error
            continuation?.yield(
                .failed(
                    code: response.errorCode,
                    type: response.errorType,
                    message: message,
                    requestID: response.requestID
                )
            )
            throw error
        }

        let tokens = response.tokens ?? []
        let newlyFinal = tokens.filter(\.isFinal)
        finalTokens.append(contentsOf: newlyFinal)
        let provisional = tokens.filter { !$0.isFinal }
        continuation?.yield(
            .transcript(
                final: newlyFinal.compactMap(mapToken),
                provisional: provisional.compactMap(mapToken)
            )
        )

        if response.finished == true {
            continuation?.yield(.finished)
            continuation?.finish()
            task = nil
            receiveTask = nil
        }
    }

    private func mapToken(_ token: SonioxToken) -> RealtimeTranscriptWord? {
        guard let source,
              let transmittedStart = token.startMs,
              let transmittedEnd = token.endMs
        else { return nil }
        let start = originalTime(forTransmittedMs: transmittedStart)
        let end = originalTime(forTransmittedMs: transmittedEnd)
        let speaker = SourceSpeakerID(source: source, providerID: token.speaker ?? "1")
        return RealtimeTranscriptWord(
            text: token.text,
            originalStartMs: start,
            originalEndMs: max(start, end),
            confidence: token.confidence ?? 0,
            speaker: speaker,
            language: token.language,
            isFinal: token.isFinal
        )
    }

    private func originalTime(forTransmittedMs value: Int) -> Int {
        if let segment = mappingSegments.first(where: {
            $0.transmittedStartMs <= value && value <= $0.transmittedEndMs
        }), let mapped = segment.originalTime(forTransmittedMs: value) {
            return mapped
        }
        return (epoch?.originalStartMs ?? 0) + value
    }

    private func latestOriginalEndMs() -> Int {
        mappingSegments.last?.originalEndMs ?? epoch?.originalStartMs ?? 0
    }
}
