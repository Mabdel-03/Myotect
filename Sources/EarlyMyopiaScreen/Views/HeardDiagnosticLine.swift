import SwiftUI

/// Operator-facing "Heard" line for voice mode: the last completed transcript and how it was
/// classified (`Heard “C.” → C ✓`, `Heard nothing (window elapsed)`, …), or the live listening
/// state while nothing has been heard yet.
///
/// The operator holding the phone reads it to tell "the child said nothing" from "the recognizer
/// misheard" without waiting for the CSV. It is never scored and never drives the flow — it only
/// mirrors `coordinator.lastHeard` / `listeningStatus`. At caption size it subtends ≈2 arcmin at
/// the 200 cm test distance, well under the 20/25 gate's letter height, so the child cannot read
/// it and it cannot cue the answer (PROTOCOL: no correctness feedback during scored trials).
///
/// Rendered only in voice mode; manual/fallback mode already owns the bottom operator strip and
/// keypad, so showing both would say the same thing twice. Hidden during a distance pause: the
/// stimulus is hidden then precisely because a child who walks up to the phone must not read
/// the letter that will be re-presented after re-lock, and at 50 cm the caption is legible.
///
/// A result kept over from the previous letter (so the operator can read it across the 0.25 s
/// transition) is prefixed "Last:" and dimmed until the current letter produces its own.
struct HeardDiagnosticLine: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator

    var body: some View {
        if coordinator.inputMode == .voice, !coordinator.isPausedForDistance, !text.isEmpty {
            MyoMicPill {
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .opacity(isCarriedOver ? 0.7 : 1)
            .allowsHitTesting(false)
        } else {
            EmptyView()
        }
    }

    /// True while the line still shows the previous letter's result.
    private var isCarriedOver: Bool {
        guard let heard = coordinator.lastHeard else { return false }
        return heard.shownLetter != coordinator.currentStimulus?.letter
    }

    /// The formatter's text wins whenever a transcript has completed; otherwise the listening
    /// state fills the gap so the line never goes blank mid-trial.
    private var text: String {
        guard let heard = coordinator.lastHeard else { return fallbackText }
        return isCarriedOver ? "Last: " + heard.text : heard.text
    }

    private var fallbackText: String {
        switch coordinator.listeningStatus {
        case .listening: return "Listening…"
        case .speaking: return "Playing instructions"
        case .heardNothing: return "Heard nothing"
        case .heardFiller: return "Heard hesitation"
        case .heardUnintelligible: return "Heard speech — no letter"
        case .ambiguousAnswer: return "Heard more than one letter"
        case .micUnavailable: return "Microphone unavailable"
        case .idle, .escalatedToClinician: return ""
        }
    }
}
