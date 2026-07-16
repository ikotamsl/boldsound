import AppKit
import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

final class TranscriptTextViewTests: XCTestCase {
    func testLiveTranscriptBodyTextUsesDesignSystemPrimaryColor() throws {
        let view = TranscriptTextView(lines: [], autoScroll: true)
        let line = MeetingRecordingPreviewLine(
            id: "1",
            timestamp: "0:05",
            speakerLabel: "Me",
            text: "Visible transcript body",
            source: .microphone
        )

        let rendered = view.renderedAttributedStringForTesting(lines: [line][...])
        let range = (rendered.string as NSString).range(of: line.text)

        let actual = try XCTUnwrap(
            rendered.attribute(
                NSAttributedString.Key.foregroundColor,
                at: range.location,
                effectiveRange: nil
            ) as? NSColor
        )
        let expected = NSColor(DesignSystem.Colors.textPrimary)

        assertColor(actual, matches: expected, appearance: .aqua)
        assertColor(actual, matches: expected, appearance: .darkAqua)
    }

    func testSystemDiarizationChangeRendersDistinctSpeakerHeader() {
        let view = TranscriptTextView(lines: [], autoScroll: true)
        let lines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerID: "system:1",
                speakerLabel: "System Speaker 1",
                text: "First speaker.",
                source: .system
            ),
            MeetingRecordingPreviewLine(
                id: "2",
                timestamp: "0:07",
                speakerID: "system:2",
                speakerLabel: "System Speaker 2",
                text: "Second speaker.",
                source: .system
            ),
        ]

        let rendered = view.renderedAttributedStringForTesting(lines: lines[...]).string

        XCTAssertTrue(rendered.contains("System Speaker 1  0:05"))
        XCTAssertTrue(rendered.contains("System Speaker 2  0:07"))
    }

    private func assertColor(
        _ actual: NSColor,
        matches expected: NSColor,
        appearance name: NSAppearance.Name,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = resolvedRGBColor(actual, appearance: name)
        let expected = resolvedRGBColor(expected, appearance: name)

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.01, file: file, line: line)
    }

    private func resolvedRGBColor(_ color: NSColor, appearance name: NSAppearance.Name) -> NSColor {
        let appearance = NSAppearance(named: name)!
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }
}
