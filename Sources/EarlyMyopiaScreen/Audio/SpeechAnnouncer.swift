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
    /// While a live capture engine holds the audio session (`.playAndRecord`), the announcer
    /// must NOT flip the category to `.playback` — that silences the microphone tap under the
    /// running engine and kills recognition for the rest of the block. Speech then plays under
    /// the capture session (`.defaultToSpeaker` keeps it audible).
    func setMicrophoneCaptureActive(_ active: Bool)
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

    /// Category we know the session to be in; nil when unknown.
    private var knownCategory: AVAudioSession.Category?
    /// True while a live capture engine owns the audio session: never flip categories then.
    private var microphoneCaptureActive = false
    /// Covers the deferred pre-speech window (gold's `isPendingSpeech`).
    private var isPendingSpeech = false
    /// Bumped by `stop()`/supersession so a deferred utterance no-ops.
    private var generation = 0
    private var activeCompletion: (() -> Void)?
    /// Identity of the utterance we are currently speaking; a stale delegate callback for a
    /// superseded utterance must never touch the new one's state.
    private var activeUtterance: AVSpeechUtterance?

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

        if microphoneCaptureActive {
            // A live capture engine owns the session: speak under it without any category
            // change — a .playback flip would silence the microphone tap and kill recognition
            // for the rest of the listening block.
            speakNow(prompt)
        } else if knownCategory != .playback {
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

    func setMicrophoneCaptureActive(_ active: Bool) {
        microphoneCaptureActive = active
        if active {
            // WhisperKit applied .playAndRecord; our cached category is no longer true.
            knownCategory = nil
        }
    }

    // MARK: - Internals

    private func speakNow(_ prompt: SpokenPrompt) {
        let utterance = AVSpeechUtterance(string: prompt.text)
        utterance.rate = rate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// Fires the pending completion exactly once and tears down any in-flight utterance.
    private func cancelInFlight() {
        generation &+= 1
        let hadWork = isPendingSpeech || synthesizer.isSpeaking
        isPendingSpeech = false
        // Detach identity FIRST: the stopSpeaking below emits a didCancel for the old utterance
        // on a later main-queue turn, which must find nothing to touch.
        activeUtterance = nil
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

    /// Delegate callbacks act only on the CURRENT utterance: a stale didStart/didFinish/didCancel
    /// from a superseded one (they arrive a main-queue turn late) must never clear the pending
    /// flag or fire the new utterance's completion.
    private func utteranceDidStart(_ utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        isPendingSpeech = false
        eventsSubject.send(.started)
    }

    private func utteranceDidEnd(_ utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
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
            MainActor.assumeIsolated { self?.utteranceDidStart(utterance) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceDidEnd(utterance) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceDidEnd(utterance) }
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

    func setMicrophoneCaptureActive(_ active: Bool) {}

    /// Test hook: emit an event as the real announcer would.
    func send(_ event: SpeechEvent) { eventsSubject.send(event) }
}
