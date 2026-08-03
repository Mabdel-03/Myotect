import Combine
import Foundation

/// A fallback recognition service where a clinician taps the letter the child said.
///
/// Requires no microphone or speech permission. The view observes ``isAwaitingInput`` to show the
/// Sloan-letter keypad, and calls ``submit(letter:)`` when the clinician taps. Useful in noisy
/// clinics and as a fallback path when ASR fails.
final class ManualClinicianService: LetterRecognitionService, ObservableObject {
    let isAvailable = true

    /// True while a trial is waiting for the clinician to tap a letter.
    @Published private(set) var isAwaitingInput = false

    private var pending: ((RecognitionOutcome) -> Void)?

    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        pending = onOutcome
        isAwaitingInput = true
    }

    /// Called by the view when the clinician taps a Sloan letter.
    func submit(letter: String) {
        guard let pending else { return }
        let upper = letter.uppercased()
        let outcome: RecognitionOutcome = SloanLetter.all.contains(upper)
            ? .letter(upper)
            : .unrecognized(.unintelligible)
        finish(outcome)
        _ = pending
    }

    /// Called by the view when the clinician indicates the child couldn't answer.
    func submitNoResponse() {
        finish(.unrecognized(.silence))
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ outcome: RecognitionOutcome?) {
        let handler = pending
        pending = nil
        isAwaitingInput = false
        if let outcome { handler?(outcome) }
    }
}
