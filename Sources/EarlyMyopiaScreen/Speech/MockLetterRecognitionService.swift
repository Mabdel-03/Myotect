import Foundation

/// A scripted recognition service for tests, previews, and the simulator.
///
/// Two modes:
/// - `answers`: replays a fixed sequence of outcomes (drives deterministic coordinator tests).
/// - `correctLetterProvider`: answers correctly for whatever letter is currently shown (lets the
///   simulator run a clean pass without a microphone). Set via ``setCorrectLetterProvider``.
final class MockLetterRecognitionService: LetterRecognitionService {
    let isAvailable = true

    private var answers: [RecognitionOutcome]
    private var index = 0
    /// When set, the service answers with `.letter(currentLetter)` regardless of `answers`.
    private var correctLetterProvider: (() -> String?)?
    /// Optional probability (0...1) of answering correctly when using `correctLetterProvider`.
    var correctProbability: Double = 1.0
    /// Simulated delay before delivering an outcome.
    var responseDelay: TimeInterval = 0.05

    init(answers: [RecognitionOutcome] = []) {
        self.answers = answers
    }

    func setCorrectLetterProvider(_ provider: @escaping () -> String?) {
        correctLetterProvider = provider
    }

    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        let outcome = nextOutcome()
        DispatchQueue.main.asyncAfter(deadline: .now() + responseDelay) {
            onOutcome(outcome)
        }
    }

    func cancel() {}

    private func nextOutcome() -> RecognitionOutcome {
        if let provider = correctLetterProvider, let shown = provider() {
            if correctProbability >= 1.0 || Double.random(in: 0...1) <= correctProbability {
                return .letter(shown)
            }
            // Deliberately wrong: pick a different Sloan letter.
            let wrong = SloanLetter.all.first { $0 != shown } ?? shown
            return .letter(wrong)
        }
        guard index < answers.count else { return .unrecognized(.silence) }
        defer { index += 1 }
        return answers[index]
    }
}
