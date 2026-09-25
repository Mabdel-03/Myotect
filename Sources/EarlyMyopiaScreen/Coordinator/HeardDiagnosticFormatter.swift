import Foundation

/// What the operator "Heard" line shows for the letter it was shown against. Mirrored by the
/// coordinator from ``RecognitionDiagnostic`` (display only — a trial is resolved solely through
/// the `recognizeOneLetter` callback, so the line can never disagree with the score).
struct HeardDiagnostic: Equatable {
    let text: String
    /// The letter on screen when the diagnostic arrived, so a line kept across the inter-letter
    /// transition still says which letter it belongs to.
    let shownLetter: String
    let at: Date
}

/// Pure text for the operator "Heard" line (PROTOCOL §7, 2026-09-03). Kept out of the
/// coordinator so the wording is unit-testable without a session, and out of the view so the
/// same string reaches any observer of `MyopiaScreenCoordinator.lastHeard`.
enum HeardDiagnosticFormatter {
    /// The longest raw transcript shown verbatim; Whisper can hallucinate whole sentences over
    /// near-silence, and the line must stay one row at the top of the trial screen.
    static let maximumRawCharacters = 24

    static func text(for diagnostic: RecognitionDiagnostic, shownLetter: String) -> String {
        switch diagnostic.kind {
        case .listening:
            return "Listening…"
        case .heard(let raw, let outcome):
            let heard = "Heard “\(condensed(raw))” → "
            switch outcome {
            case .letter(let letter):
                return heard + letter + (letter == shownLetter ? " ✓" : " ✗")
            case .skipped:
                return heard + "skip"
            case .ambiguous:
                return heard + "more than one letter"
            case .unrecognized(.filler):
                return heard + "hesitation"
            case .unrecognized(.unintelligible):
                return heard + "no letter"
            case .unrecognized(.silence):
                return heard + "nothing usable"
            case .serviceFailure:
                return "Microphone unavailable"
            }
        case .deferredDeadline(let seconds):
            return String(format: "Deadline extended +%.2f s", seconds)
        case .flushedSilent:
            return "Heard nothing (window elapsed)"
        }
    }

    /// Collapses runs of whitespace / newlines (Whisper emits both) to single spaces and caps the
    /// result at ``maximumRawCharacters``, appending an ellipsis when it was cut.
    static func condensed(_ raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > maximumRawCharacters else { return collapsed }
        return String(collapsed.prefix(maximumRawCharacters)) + "…"
    }
}
