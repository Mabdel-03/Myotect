import Foundation

/// Per-trial retry/escalation state machine for failed recognition attempts. Pure value type;
/// the coordinator owns one instance.
///
/// A non-answer (`.ambiguous`, `.unrecognized(.filler)`, `.unrecognized(.unintelligible)`) earns a
/// bounded number of same-letter retries (the first with a spoken re-prompt), then escalates the
/// trial to the clinician keypad — a dead microphone must never produce a silent infinite
/// re-present loop. Structural failures (`.serviceFailure`) escalate immediately. Voice-path
/// `.unrecognized(.silence)` is NOT a retry: the coordinator records it as an uncounted "no input
/// registered" row, presents a fresh letter and, after `ScreenConfig.noInputTrialsBeforeEscalation`
/// in a row, escalates the next letter via ``noteNoInputEscalation()``. After enough consecutive escalated trials the manual
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

    /// Call on `.ambiguous` / `.unrecognized(.filler | .unintelligible)` — voice silence is
    /// recorded (uncounted), not retried.
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

    /// Call when the coordinator's no-input backstop hands the NEXT letter to the keypad after
    /// `ScreenConfig.noInputTrialsBeforeEscalation` consecutive silent voice trials. Counts as an
    /// escalation for sticky-manual purposes: a child (or microphone) that stays silent block
    /// after block should not keep bouncing back to voice.
    mutating func noteNoInputEscalation() {
        noteEscalation()
    }

    /// Call when a trial resolves: a voice letter, a spoken skip, a voice no-input row, a keypad
    /// entry, or a completed warm-up letter. `byVoice` must be true only when a voice answer was
    /// actually HEARD — a voice-mode no-input row passes false so the consecutive-escalation
    /// streak survives silence (see ``noteNoInputEscalation()``).
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

    /// Keypad-only start from the setup screen: manual mode is sticky from the first trial and
    /// survives resolved letters until the clinician explicitly restores voice.
    mutating func forceStickyManual() {
        isStickyManual = true
    }

    private mutating func noteEscalation() {
        consecutiveEscalatedTrials += 1
        if consecutiveEscalatedTrials >= config.stickyManualAfterConsecutiveEscalations {
            isStickyManual = true
        }
    }
}
