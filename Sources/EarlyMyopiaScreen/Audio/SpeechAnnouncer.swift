import AVFoundation
import Combine
import Foundation

/// What the app can say to the child/operator. A closed catalog so the coordinator, throttle,
/// and tests share one vocabulary.
struct SpokenPrompt: Equatable, Hashable {
    let text: String

    static let sayTheLetter = SpokenPrompt(text: "Say the letter you see.")
    static let tryAgain = SpokenPrompt(text: "Say the letter you see out loud.")
    static let warmupIntro = SpokenPrompt(text: "Let's practice. Say each letter out loud.")
    static let testBegins = SpokenPrompt(text: "Here we go. Say the letter you see.")
    static let moveCloser = SpokenPrompt(text: "Move closer.")
    static let moveFarther = SpokenPrompt(text: "Move farther away.")
    static let stepIntoView = SpokenPrompt(text: "I can't see you. Step back into view.")
    static let holdStill = SpokenPrompt(text: "Hold still.")
    static let allDone = SpokenPrompt(text: "All done. Great job!")
}

enum SpeechEvent: Equatable {
    case started
    /// Also fires when an utterance is cancelled or superseded.
    case finished
}

/// Patient-facing audio prompting. Recognition must never run while `isSpeaking` — the
/// coordinator gates `listen()` on it and resumes after `.finished`.
@MainActor
protocol PatientAudioPrompting: AnyObject {
    /// True from the `speak` call until the utterance ends — INCLUDING the pre-speech window
    /// while the audio session switches category and settles.
    var isSpeaking: Bool { get }
    var events: AnyPublisher<SpeechEvent, Never> { get }
    /// Speaks, superseding any in-flight utterance (whose completion fires exactly once).
    func speak(_ prompt: SpokenPrompt, completion: (() -> Void)?)
    func stop()
    /// The recognition side calls this after WhisperKit reconfigures the session
    /// (`.playAndRecord`), so the next `speak` knows a real category switch + settle is needed.
    func noteMicrophoneCaptureActive()
}

extension PatientAudioPrompting {
    func speak(_ prompt: SpokenPrompt) { speak(prompt, completion: nil) }
}

/// AVSpeechSynthesizer announcer, ported from the sibling app's `SharedAudioManager`:
/// category tracking with a `.playback` flip for loud, clean speech; a short settle delay after
/// a category switch so the utterance onset is not clipped; pending-speech accounting so
/// `isSpeaking` covers the settle window; generation-bumped cancellation.
@MainActor
final class SpeechAnnouncer: NSObject, ObservableObject, PatientAudioPrompting {
    private let synthesizer = AVSpeechSynthesizer()
    private let enabled: Bool
    private let rate: Float
    private let settleSeconds: TimeInterval

    /// Category we know the session to be in; nil when unknown (e.g. after mic capture).
    private var knownCategory: AVAudioSession.Category?
    /// Covers the deferred pre-speech window (gold's `isPendingSpeech`).
    private var isPendingSpeech = false
    /// Bumped by `stop()`/supersession so a deferred utterance no-ops.
    private var generation = 0
    private var activeCompletion: (() -> Void)?

    private let eventsSubject = PassthroughSubject<SpeechEvent, Never>()
    var events: AnyPublisher<SpeechEvent, Never> { eventsSubject.eraseToAnyPublisher() }

    var isSpeaking: Bool { isPendingSpeech || synthesizer.isSpeaking }

    init(config: ScreenConfig) {
        self.enabled = config.ttsEnabled
        self.rate = config.ttsRate
        self.settleSeconds = config.categorySettleSeconds
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ prompt: SpokenPrompt, completion: (() -> Void)?) {
        guard enabled else {
            completion?()
            return
        }
        // Supersede: the earlier utterance's completion fires exactly once, now.
        cancelInFlight()

        generation &+= 1
        let myGeneration = generation
        isPendingSpeech = true
        activeCompletion = completion

        if knownCategory != .playback {
            configurePlaybackSession()
            knownCategory = .playback
            // Give the route a moment to settle so the utterance onset is not clipped
            // (gold: 0.15 s after a category switch).
            DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) { [weak self] in
                guard let self, self.generation == myGeneration else { return }
                self.speakNow(prompt)
            }
        } else {
            speakNow(prompt)
        }
    }

    func stop() {
        guard enabled else { return }
        cancelInFlight()
    }

    func noteMicrophoneCaptureActive() {
        knownCategory = nil
    }

    // MARK: - Internals

    private func speakNow(_ prompt: SpokenPrompt) {
        let utterance = AVSpeechUtterance(string: prompt.text)
        utterance.rate = rate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    /// Fires the pending completion exactly once and tears down any in-flight utterance.
    private func cancelInFlight() {
        generation &+= 1
        let hadWork = isPendingSpeech || synthesizer.isSpeaking
        isPendingSpeech = false
        let completion = activeCompletion
        activeCompletion = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if hadWork {
            completion?()
            eventsSubject.send(.finished)
        }
    }

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func utteranceDidStart() {
        isPendingSpeech = false
        eventsSubject.send(.started)
    }

    private func utteranceDidEnd() {
        isPendingSpeech = false
        let completion = activeCompletion
        activeCompletion = nil
        completion?()
        eventsSubject.send(.finished)
    }
}

extension SpeechAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceDidStart() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceDidEnd() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceDidEnd() }
        }
    }
}

/// Synchronous no-audio announcer: the default for tests and previews so coordinator flows stay
/// deterministic. Records what would have been spoken.
@MainActor
final class SilentAnnouncer: PatientAudioPrompting {
    private(set) var spoken: [SpokenPrompt] = []
    var isSpeaking = false
    private let eventsSubject = PassthroughSubject<SpeechEvent, Never>()
    var events: AnyPublisher<SpeechEvent, Never> { eventsSubject.eraseToAnyPublisher() }

    init() {}

    func speak(_ prompt: SpokenPrompt, completion: (() -> Void)?) {
        spoken.append(prompt)
        completion?()
    }

    func stop() {}

    func noteMicrophoneCaptureActive() {}

    /// Test hook: emit an event as the real announcer would.
    func send(_ event: SpeechEvent) { eventsSubject.send(event) }
}
