import Foundation

/// Per-trial retry/escalation state machine for failed recognition attempts. Pure value type;
/// the coordinator owns one instance.
///
/// A non-answer (`.unrecognized` / `.ambiguous`) earns a bounded number of same-letter retries
/// (the first with a spoken re-prompt), then escalates the trial to the clinician keypad — a dead
/// microphone must never produce a silent infinite re-present loop. Structural failures
/// (`.serviceFailure`) escalate immediately. After enough consecutive escalated trials the manual
/// mode becomes sticky until the clinician explicitly restores voice input.
struct RetryEscalationPolicy: Equatable {
    struct Config: Equatable {
        var maxAutoRetriesPerTrial: Int = 2
        var stickyManualAfterConsecutiveEscalations: Int = 2
    }

    enum Action: Equatable {
        /// Re-listen for the same letter; `withPrompt` is true on the first retry of a trial so
        /// the announcer can speak a re-prompt (later retries stay silent).
        case retry(withPrompt: Bool)
        /// Hand this trial to the clinician keypad.
        case escalateToManual
    }

    let config: Config
    private(set) var attemptsThisTrial = 0
    private(set) var consecutiveEscalatedTrials = 0
    private(set) var isStickyManual = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// Call when a NEW letter is presented. Distance-pause repeats deliberately do not reset the
    /// count: a pause is not an answer attempt and must not grant extra retries.
    mutating func beginTrial() {
        attemptsThisTrial = 0
    }

    /// Call on `.unrecognized` / `.ambiguous`.
    mutating func actionForFailedAttempt() -> Action {
        attemptsThisTrial += 1
        if isStickyManual || attemptsThisTrial > config.maxAutoRetriesPerTrial {
            noteEscalation()
            return .escalateToManual
        }
        return .retry(withPrompt: attemptsThisTrial == 1)
    }

    /// Call on `.serviceFailure`: structural — never retry-loop.
    mutating func actionForServiceFailure() -> Action {
        noteEscalation()
        return .escalateToManual
    }

    /// Call when a trial actually resolves (a letter was scored, by voice or keypad).
    mutating func trialResolved(byVoice: Bool) {
        if byVoice { consecutiveEscalatedTrials = 0 }
        attemptsThisTrial = 0
    }

    /// Clinician explicitly restored voice input.
    mutating func clinicianRestoredVoice() {
        isStickyManual = false
        consecutiveEscalatedTrials = 0
        attemptsThisTrial = 0
    }

    private mutating func noteEscalation() {
        consecutiveEscalatedTrials += 1
        if consecutiveEscalatedTrials >= config.stickyManualAfterConsecutiveEscalations {
            isStickyManual = true
        }
    }
}
