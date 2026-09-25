import XCTest
@testable import Myotect

/// One test per ``RecognitionDiagnostic/Kind``. The strings are what the operator reads at the
/// top of the trial screen (PROTOCOL §7, 2026-09-03), so a wording change is a deliberate edit
/// here, never a side effect.
final class HeardDiagnosticFormatterTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func text(_ kind: RecognitionDiagnostic.Kind, shown: String = "C") -> String {
        HeardDiagnosticFormatter.text(for: RecognitionDiagnostic(kind: kind, at: at), shownLetter: shown)
    }

    func testListeningIsTheArmedPlaceholder() {
        XCTAssertEqual(text(.listening), "Listening…")
        XCTAssertEqual(text(.listening, shown: ""), "Listening…", "no letter dependence")
    }

    /// Every ``RecognitionOutcome`` a `.heard` pass can carry, plus the raw-transcript rules:
    /// whitespace / newlines collapse and long hallucinations are capped with an ellipsis.
    func testHeardShowsTheRawTranscriptAndEveryOutcome() {
        XCTAssertEqual(text(.heard(raw: "C.", outcome: .letter("C"))), "Heard “C.” → C ✓")
        XCTAssertEqual(text(.heard(raw: "C.", outcome: .letter("C")), shown: "D"), "Heard “C.” → C ✗")
        XCTAssertEqual(text(.heard(raw: "skip", outcome: .skipped)), "Heard “skip” → skip")
        XCTAssertEqual(text(.heard(raw: "C D", outcome: .ambiguous)), "Heard “C D” → more than one letter")
        XCTAssertEqual(text(.heard(raw: "um", outcome: .unrecognized(.filler))), "Heard “um” → hesitation")
        XCTAssertEqual(text(.heard(raw: "seat", outcome: .unrecognized(.unintelligible))), "Heard “seat” → no letter")
        XCTAssertEqual(text(.heard(raw: "Thank you.", outcome: .unrecognized(.silence))), "Heard “Thank you.” → nothing usable")
        XCTAssertEqual(text(.heard(raw: "", outcome: .serviceFailure(.audioCaptureFailed("x")))), "Microphone unavailable")
        XCTAssertEqual(text(.heard(raw: "", outcome: .serviceFailure(.microphonePermissionDenied))), "Microphone unavailable")

        // Whisper emits newlines and runs of spaces; the line is one row, so they collapse.
        XCTAssertEqual(text(.heard(raw: "  I\n think   it's\ta C ", outcome: .letter("C"))),
                       "Heard “I think it's a C” → C ✓")
        // A hallucinated sentence is cut at 24 characters and marked as cut.
        let long = "Thank you for watching this video everyone"
        XCTAssertEqual(text(.heard(raw: long, outcome: .unrecognized(.silence))),
                       "Heard “Thank you for watching t…” → nothing usable")
        XCTAssertEqual(HeardDiagnosticFormatter.maximumRawCharacters, 24)
        XCTAssertEqual(HeardDiagnosticFormatter.condensed(String(repeating: "a", count: 24)),
                       String(repeating: "a", count: 24), "exactly the cap is not cut")
    }

    func testDeferredDeadlineShowsTheAccumulatedExtension() {
        XCTAssertEqual(text(.deferredDeadline(seconds: 0.75)), "Deadline extended +0.75 s")
        XCTAssertEqual(text(.deferredDeadline(seconds: 3)), "Deadline extended +3.00 s")
    }

    func testFlushedSilentSaysNothingWasHeard() {
        XCTAssertEqual(text(.flushedSilent), "Heard nothing (window elapsed)")
    }
}
