import Combine
import Foundation

/// Recognizes a single spoken letter per trial.
///
/// Implementations: ``WhisperKitLetterRecognitionService`` (live microphone via on-device
/// Whisper), ``MockLetterRecognitionService`` (scripted, for tests/simulator), and
/// ``ManualClinicianService`` (clinician taps the heard letter — also the escalation fallback).
protocol LetterRecognitionService: AnyObject {
    /// Whether this service can run on the current device/permissions.
    var isAvailable: Bool { get }
    /// Begins listening for one letter; `onOutcome` is called once on the main thread.
    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void)
    /// Cancels any in-flight recognition (e.g. when a trial is paused for distance).
    func cancel()
}

/// Structural events from a continuously held capture engine, outside any single trial.
enum CaptureEvent: Equatable {
    /// The engine (re)started and applied its audio-session config; the announcer uses this to
    /// know a category switch + settle is needed before the next utterance.
    case captureStarted
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    /// The route changed (e.g. AirPods connected); capture was restarted internally and the
    /// coordinator should re-arm the current trial.
    case routeChanged
    case failed(RecognitionServiceFailure)
}

/// Adopted by services that can hold a microphone engine open across trials (one engine per
/// listening block instead of a rebuild per trial). The coordinator drives it at block
/// boundaries; `recognizeOneLetter` then re-arms on the live engine with a consumed-pointer
/// reset. Services without it (the mock) keep per-call semantics — `as?` call sites no-op.
@MainActor
protocol ContinuousCaptureControlling: AnyObject {
    func beginCaptureSession()
    func endCaptureSession()
    var captureEvents: AnyPublisher<CaptureEvent, Never> { get }
}

/// One completed step of the live recognizer, for the operator-facing "Heard" line on the trial
/// screen. Diagnostics are display only — the trial is resolved solely through the
/// `recognizeOneLetter` callback — so a view can never be ahead of, or disagree with, the score.
struct RecognitionDiagnostic: Equatable {
    enum Kind: Equatable {
        /// The microphone is armed for a letter and nothing has been transcribed yet.
        case listening
        /// A transcription pass completed: what Whisper returned and how it classified.
        case heard(raw: String, outcome: RecognitionOutcome)
        /// The no-input deadline was pushed back because sound was still being collected.
        case deferredDeadline(seconds: TimeInterval)
        /// The deadline flush found no speech-length sound and ended the window as silence.
        case flushedSilent
    }

    let kind: Kind
    let at: Date
}

/// Adopted by services that can narrate what they hear (the WhisperKit service). The coordinator
/// reaches it via `as?`, exactly like ``ContinuousCaptureControlling``; the mock and the keypad
/// service do not adopt it.
@MainActor
protocol RecognitionDiagnosticsProviding: AnyObject {
    var diagnostics: AnyPublisher<RecognitionDiagnostic, Never> { get }
}
