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
