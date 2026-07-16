import Foundation

struct SonioxMeetingTranscriptFinalizer {
    struct Result: Sendable, Equatable {
        let rawTranscript: String
        let words: [WordTimestamp]
        let speakers: [SpeakerInfo]
        let diarizationSegments: [DiarizationSegmentRecord]
        let language: String?
        let durationMs: Int?
    }

    static func finalize(_ archive: SonioxMeetingTranscriptArchive) -> Result {
        let speechWords = removeLikelySoundHallucinations(
            from: removeNonSpeechAnnotations(from: archive.words)
        )
        let words = speechWords.map {
            WordTimestamp(
                word: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startMs: $0.originalStartMs,
                endMs: $0.originalEndMs,
                confidence: $0.confidence,
                speakerId: $0.speaker.description
            )
        }.filter { !$0.word.isEmpty }
            .sorted {
                if $0.startMs == $1.startMs {
                    return ($0.speakerId ?? "") < ($1.speakerId ?? "")
                }
                return $0.startMs < $1.startMs
            }

        let activeSpeakerIDs = Set(words.compactMap(\.speakerId))
        var seenSpeakerIDs = Set<String>()
        let speakers = speechWords.compactMap { word -> SpeakerInfo? in
            let id = word.speaker.description
            guard activeSpeakerIDs.contains(id), seenSpeakerIDs.insert(id).inserted else {
                return nil
            }
            return SpeakerInfo(id: id, label: word.speaker.displayName)
        }

        let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
        let rawTranscript: String = TranscriptSegmenter.groupParallelSpeakersIntoSegments(words: words)
            .map { segment -> String in
                let label = labels[segment.speakerId ?? ""] ?? "Speaker"
                return "\(label): \(segment.text)"
            }
            .joined(separator: "\n\n")

        return Result(
            rawTranscript: rawTranscript,
            words: words,
            speakers: speakers,
            diarizationSegments: buildDiarizationSegments(from: words),
            language: mostCommonLanguage(in: speechWords),
            durationMs: words.map(\.endMs).max()
        )
    }

    private static func removeNonSpeechAnnotations(
        from words: [RealtimeTranscriptWord]
    ) -> [RealtimeTranscriptWord] {
        var output: [RealtimeTranscriptWord] = []

        for source in RealtimeAudioSource.allCases {
            let sourceWords = words.filter { $0.speaker.source == source }
                .sorted { $0.originalStartMs < $1.originalStartMs }
            var insideAnnotation = false

            for word in sourceWords {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let opensAnnotation = text.contains("[") || text.contains("<")
                let closesAnnotation = text.contains("]") || text.contains(">")

                if insideAnnotation || opensAnnotation {
                    insideAnnotation = !closesAnnotation
                    continue
                }
                if text.contains("♪") || text.contains("♫") || isNamedSoundAnnotation(text) {
                    continue
                }
                output.append(word)
            }
        }
        return output
    }

    private static func isNamedSoundAnnotation(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
        return [
            "music", "noise", "sound", "silence", "static", "beep", "applause", "laughter",
            "музыка", "шум", "звук", "тишина", "помехи", "сигнал", "аплодисменты", "смех",
        ].contains(value)
    }

    /// Drop only short, isolated, very-low-confidence runs. Longer utterances
    /// are preserved even at low confidence so difficult speech is not erased.
    private static func removeLikelySoundHallucinations(
        from words: [RealtimeTranscriptWord]
    ) -> [RealtimeTranscriptWord] {
        var output: [RealtimeTranscriptWord] = []
        let grouped = Dictionary(grouping: words, by: \.speaker)

        for speakerWords in grouped.values {
            let sorted = speakerWords.sorted { $0.originalStartMs < $1.originalStartMs }
            var run: [RealtimeTranscriptWord] = []

            func flush() {
                guard !run.isEmpty else { return }
                let averageConfidence = run.map(\.confidence).reduce(0, +) / Double(run.count)
                let isShortUncertainRun = run.count <= 3 && averageConfidence < 0.35
                if !isShortUncertainRun { output.append(contentsOf: run) }
                run = []
            }

            for word in sorted {
                if let previous = run.last, word.originalStartMs - previous.originalEndMs > 1_500 {
                    flush()
                }
                run.append(word)
            }
            flush()
        }
        return output.sorted {
            if $0.originalStartMs == $1.originalStartMs {
                return $0.speaker.description < $1.speaker.description
            }
            return $0.originalStartMs < $1.originalStartMs
        }
    }

    private static func mostCommonLanguage(in words: [RealtimeTranscriptWord]) -> String? {
        let counts = Dictionary(grouping: words.compactMap(\.language), by: { $0 }).mapValues(\.count)
        return counts.max { lhs, rhs in lhs.value < rhs.value }?.key
    }

    private static func buildDiarizationSegments(
        from words: [WordTimestamp]
    ) -> [DiarizationSegmentRecord] {
        var segments: [DiarizationSegmentRecord] = []
        for (speakerID, speakerWords) in Dictionary(grouping: words, by: { $0.speakerId ?? "" }) {
            guard !speakerID.isEmpty else { continue }
            let sorted = speakerWords.sorted { $0.startMs < $1.startMs }
            guard let first = sorted.first else { continue }
            var start = first.startMs
            var end = first.endMs
            for word in sorted.dropFirst() {
                if word.startMs - end <= 1_500 {
                    end = max(end, word.endMs)
                } else {
                    segments.append(.init(speakerId: speakerID, startMs: start, endMs: end))
                    start = word.startMs
                    end = word.endMs
                }
            }
            segments.append(.init(speakerId: speakerID, startMs: start, endMs: end))
        }
        return segments.sorted { $0.startMs < $1.startMs }
    }
}
