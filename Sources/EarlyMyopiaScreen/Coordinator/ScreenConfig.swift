import CoreGraphics
import Foundation

/// All tunable parameters for the screening protocol, in one place.
///
/// Defaults follow the engineering spec. Everything here is config-driven so the clinical team can
/// adjust distances, contrast, the gate, and the letter set without touching logic.
struct ScreenConfig {
    // MARK: Distance
    var targetDistanceCM: Double = 200
    /// Band the subject must hold to lock and to keep a trial valid. The lower bound is a
    /// deliberate tightening of the reference app's 0.8× fraction (0.9× here): a too-close child
    /// inflates measured acuity, so the near side of the band is stricter.
    var validDistanceRangeCM: ClosedRange<Double> = 180...240
    /// Wider band the ARKit provider accepts as plausible readings (rejects noise outside this).
    var providerDistanceRangeCM: ClosedRange<Double> = 100...300
    /// In-trial dwell re-lock only (resume after a distance pause). The initial capture uses the
    /// operator-initiated hold below instead.
    var distanceStableWindowSeconds: TimeInterval = 0.75
    var maxDistanceSDCM: Double = 5

    // MARK: Distance capture (operator-initiated hold)
    /// How long the phone must stay put after the operator taps Capture (gold-standard: 2.0 s).
    var holdDurationSeconds: TimeInterval = 2.0
    /// Maximum deviation from the tap-instant anchor before the hold voids (gold-standard: 4 cm).
    var holdToleranceCM: Double = 4.0
    /// How long a "that didn't work — try again" notice stays up before clearing itself.
    var captureRetryNoticeSeconds: TimeInterval = 2.5

    // MARK: Distance sampling / validity
    /// A sample older than this is stale and never trusted for sizing or scoring.
    var maximumSampleAgeSeconds: TimeInterval = 0.5
    /// Minimum interval between same-kind validity pushes to the coordinator (kind changes are
    /// always delivered immediately). 0.1 s ≈ 10 Hz, matching the reference app's monitoring rate.
    var distanceUpdateIntervalSeconds: TimeInterval = 0.1
    /// Face-anchor silence longer than this (with the session still tracking) counts as face lost.
    var trackingLostTimeoutSeconds: TimeInterval = 0.5
    /// Moving-average window applied to raw ARKit readings.
    var smoothingWindowSamples: Int = 5

    // MARK: In-trial distance hysteresis
    /// A trial paused for distance resumes only after re-entering the valid band inset by
    /// `min(resumeInsetMaxCM, resumeInsetFraction × bandWidth)` per side AND re-locking (dwell),
    /// so the boundary cannot chatter.
    var resumeInsetMaxCM: Double = 3.0
    var resumeInsetFraction: Double = 0.25

    // MARK: Guidance UX
    /// How long the "distance locked" confirmation pill stays up before auto-dismissing.
    var guidanceOKDismissSeconds: TimeInterval = 1.0

    // MARK: Acuity staircase
    var acuityLevels: [Int] = [200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16]
    var startAcuity: Int = 40
    /// ETDRS five-letter protocol (gold `ETDRSProtocolConfiguration.fiveLetterV1`):
    /// 5 trials per line, ≥3 correct to advance, early-perfect pass at 3 straight correct.
    var trialsPerLevel: Int = 5
    var advanceThreshold: Int = 3
    var earlySkipCount: Int = 3
    /// The 20/25 reference level for the high-contrast condition: `reachedGate` on its result
    /// records whether the finest PASSED line reached it. Recorded for analysis only — it does
    /// not gate the flow; the low-contrast conditions always run.
    var gateAcuity: Int = 25
    /// How many ladder steps COARSER (bigger letters) than the high-contrast result the
    /// low-contrast conditions begin at. A low-contrast letter is harder to read than the
    /// same-size high-contrast one, so the run opens with headroom above the child's own
    /// demonstrated line instead of a fixed level.
    var lowContrastStartOffsetSteps: Int = 2

    // MARK: Contrast
    /// Weber contrast for the two low-contrast conditions. 20% by default; operator-selectable
    /// 5/10/15/20% in Settings. Read once when the screening flow launches — immutable
    /// mid-session (and recorded on the session as `weberContrast`). Nominal sRGB-channel
    /// contrast, not photometric (see `ContrastPalette`).
    var lowContrastWeber: Double = 0.20
    var backgroundBrightness: Double = 1.0

    // MARK: Display
    var testBrightness: CGFloat = 1.0

    /// Inter-stimulus interval: the colored square renders black (letter hidden, blue frame
    /// steady) for this long before every optotype appears, so one letter never swaps straight
    /// into the next. Zero presents synchronously — the coordinator tests set it to 0 to keep
    /// trial flow deterministic, exactly as they already do for `listenResumeAfterSpeechSeconds`.
    var interstimulusBlankSeconds: TimeInterval = 0.25

    /// Clearance (points) between the largest permitted glyph and the colored square's edge.
    var optotypeSquareInnerMargin: Double = 12
    /// Gap (points) between the colored square and the surrounding blue border square on each side.
    var optotypeBorderGap: Double = 14
    /// Line width (points) of the blue border square.
    var optotypeBorderWidth: Double = 8

    // MARK: Stimuli
    var letterSet: [String] = SloanLetter.all
    var warmupLetterCount: Int = 5
    var warmupAcuity: Int = 80

    // MARK: Speech
    /// The no-input window (SOFT, 10 s): how long the microphone listens for the child's answer,
    /// timed from the first microphone audio after the letter is revealed — after the
    /// inter-stimulus blank and any spoken prompt plus `listenResumeAfterSpeechSeconds`, never
    /// from a blank field or the app's own speech. Soft: the deadline never fires while voice is
    /// in the newest `utteranceEndQuietSeconds` of audio or a transcription is in flight; the
    /// service defers it in `deadlineDeferralStepSeconds` steps up to `deadlineDeferralCapSeconds`,
    /// then flushes (worst case ≈ window + cap + the inference drain + one decode, ~15 s). A late
    /// answer is scored for THIS letter. Only a window with no speech-length sound AND no usable
    /// text is delivered as `.unrecognized(.silence)`, which the scored voice path records as a
    /// "no input registered" row that does NOT count toward the staircase — a fresh letter
    /// replaces it (PROTOCOL §7, 2026-09-03). The coordinator only passes this value to
    /// `recognizeOneLetter(timeout:)`; the service owns the clock. Was 5 s while silence scored a
    /// miss; 8 s when it merely retried.
    var recognitionTimeoutSeconds: TimeInterval = 10
    /// Backstop for a child (or microphone) that stays silent: after this many CONSECUTIVE voice
    /// trials ended by the no-input window, the next presentation goes to the clinician keypad.
    /// Since a no-input trial is recorded but never fed to the staircase, silence alone can never
    /// move the level or end a condition — without this backstop the same level would re-present
    /// fresh letters forever with no operator signal (the operator status strip is hidden in
    /// voice mode). It is the ONLY exit from that loop. Any spoken letter, skip, or keypad entry
    /// resets the count; the hand-off counts as an escalation for sticky-manual purposes.
    var noInputTrialsBeforeEscalation: Int = 3
    /// Step by which the soft deadline is pushed back each time it lands on voice in the tail or
    /// an in-flight inference — the poll cadence that lets a late answer be scored for its letter.
    var deadlineDeferralStepSeconds: TimeInterval = 0.25
    /// Total deferral allowed past `recognitionTimeoutSeconds` before the window is flushed
    /// regardless — a television keeps the tail "voiced" forever.
    var deadlineDeferralCapSeconds: TimeInterval = 3.0
    /// A live transcription runs only once the answer has ENDED: the newest this-many seconds of
    /// audio must read as silence (Whisper completes a truncated first syllable into a
    /// non-letter word). Also exactly the tail a non-answer pass leaves unconsumed, so an
    /// utterance straddling a pass boundary keeps its onset without re-triggering on the
    /// fragment before it (the two are equal on purpose).
    var utteranceEndQuietSeconds: TimeInterval = 0.3
    /// A sound continuous for this long is transcribed anyway (a long answer, a noisy room). Also
    /// bounds how much of a voice run that began BEFORE the letter appeared is skipped as carried
    /// over from the previous letter.
    var maximumUtteranceSeconds: TimeInterval = 2.0
    /// Per-100 ms block energy, relative (0…1) to the quietest of the previous 2 s, above which a
    /// block reads as voice. Blocks below −80 dBFS never serve as the reference. WhisperKit's
    /// default; tunable for the 2 m test distance.
    var voiceSilenceThreshold: Float = 0.10
    /// Audio kept behind the session start whenever the capture buffer is trimmed (at each arm,
    /// after a cancel, at block ends): must cover the 2 s silence reference plus the block the
    /// carried-over-voice rule inspects.
    var capturePurgeKeepSeconds: TimeInterval = 3.0
    /// WhisperKit's own live buffer grows for the life of an engine; once it holds this much
    /// audio (~7.7 MB) the engine is paused for a few milliseconds, the buffer emptied, and the
    /// engine resumed — between letters or during a pause, never on a reveal.
    var captureBufferTrimAfterSeconds: TimeInterval = 120
    /// Failed attempts (ambiguous / filler / unintelligible) allowed per trial before the trial
    /// escalates to the clinician keypad. The first retry carries a spoken re-prompt.
    var maxAutoRetriesPerTrial: Int = 2
    /// Consecutive escalated trials after which manual mode becomes sticky until the clinician
    /// explicitly restores voice input.
    var stickyManualAfterConsecutiveEscalations: Int = 2

    var retryConfig: RetryEscalationPolicy.Config {
        .init(maxAutoRetriesPerTrial: maxAutoRetriesPerTrial,
              stickyManualAfterConsecutiveEscalations: stickyManualAfterConsecutiveEscalations)
    }

    // MARK: Patient-facing audio (TTS)
    var ttsEnabled: Bool = true
    var ttsRate: Float = 0.5
    /// Delay after an audio-session category switch before speaking, so the onset isn't clipped.
    var categorySettleSeconds: TimeInterval = 0.15
    /// Delay between an announcement finishing and recognition re-arming when a prompt was
    /// still playing at the reveal. The reference app used 1.5 s to cover a cold engine restart
    /// after a `.playback` category flip; here the announcer speaks UNDER the live capture
    /// session with no flip, the microphone is live throughout, the prompt's echo lies before
    /// the session start and is never inspected, and a ring-down straddling the start is
    /// skipped as carried-over voice — only the speaker's drain (~0.2 s) needs to clear. Raise to
    /// 0.75 s if device logs ever show prompt words inside a session. Known limitation: with the
    /// non-default `speakEveryTrialPrompt`, the letter is visible while the prompt plays, so an
    /// answer given during the prompt is not heard (the child repeats it).
    var listenResumeAfterSpeechSeconds: TimeInterval = 0.5
    /// Minimum interval before the SAME distance-guidance prompt repeats.
    var distancePromptMinIntervalSeconds: TimeInterval = 5
    /// When true, "Say the letter you see." is spoken before every scored trial (default: only
    /// at phase transitions and on the first retry, to keep trials fast).
    var speakEveryTrialPrompt: Bool = false

    // MARK: Privacy / data
    /// Off by default. Raw audio buffers or face geometry are not stored unless this research flag is enabled.
    var persistRawSignals: Bool = false

    init() {}

    /// The flow's config sampled from the operator's persisted settings at launch — the only
    /// settings → config seam (`ContentView.screeningConfig()`).
    init(settings: ScreeningSettings) {
        lowContrastWeber = settings.weberChoice.rawValue
        ttsEnabled = settings.audioEnabled
    }

    /// Builds a staircase config for a condition; only the high-contrast condition carries the
    /// 20/25 reference level (`gateAcuity`), which is recorded on its result, never a flow branch.
    /// `overrideStart` seeds a different starting level than the protocol default (the
    /// low-contrast conditions start from the high-contrast result — see
    /// ``acuityLevel(coarserBy:than:)``).
    func staircaseConfig(gated: Bool, startAcuity overrideStart: Int? = nil) -> AcuityStaircaseConfig {
        var config = AcuityStaircaseConfig()
        config.acuityLevels = acuityLevels
        config.startAcuity = overrideStart ?? startAcuity
        config.trialsPerLevel = trialsPerLevel
        config.advanceThreshold = advanceThreshold
        config.earlySkipCount = earlySkipCount
        config.gateAcuity = gated ? gateAcuity : nil
        return config
    }

    /// The level `steps` rungs coarser (larger letters) than `acuity` on ``acuityLevels``,
    /// clamped to the coarsest level. Falls back to ``startAcuity`` when `acuity` is not a
    /// configured level, so the result is never off-ladder: `AcuityStaircaseEngine.init`
    /// silently drops an unknown `startAcuity` to the coarsest rung.
    func acuityLevel(coarserBy steps: Int, than acuity: Int) -> Int {
        guard let index = acuityLevels.firstIndex(of: acuity) else { return startAcuity }
        return acuityLevels[max(0, index - steps)]
    }

    /// Contrast config for a low-contrast condition (high contrast ignores this).
    func contrastConfig() -> ContrastConfig {
        ContrastConfig(weber: lowContrastWeber, backgroundBrightness: backgroundBrightness)
    }

    /// The device/protocol combination is structurally invalid: the worst-case optotype cannot
    /// physically fit on this display. Surfaced as a blocking pre-flight problem at setup.
    enum DisplayFitError: Error, Equatable {
        case screenTooSmall(requiredPoints: Double, availablePoints: Double)
    }

    /// Fixed colored-square side (points) derived from the worst-case optotype: the coarsest
    /// acuity level at the far edge of the valid distance band, plus the inner margin, computed
    /// from the validated calibration. Throws when the worst case cannot fit the screen's short
    /// side once the blue frame is accounted for — a structurally invalid device/protocol combo
    /// that must block at setup, never crop a letter mid-trial.
    func optotypeSquareSide(calibration: ScreenCalibration,
                            screenShortSidePoints: Double) throws -> Double {
        guard let coarsest = acuityLevels.max() else {
            throw DisplayFitError.screenTooSmall(requiredPoints: 0, availablePoints: 0)
        }
        let worstCase = try OptotypeSizing.renderSpec(
            distanceCM: validDistanceRangeCM.upperBound,
            snellenDenominator: coarsest,
            calibration: calibration,
            font: OptotypeSizing.sloanBaseFont())
        let required = Double(worstCase.renderedHeightPoints) + 2 * optotypeSquareInnerMargin
        let available = screenShortSidePoints - 2 * (optotypeBorderGap + optotypeBorderWidth) - 8
        guard required <= available else {
            throw DisplayFitError.screenTooSmall(requiredPoints: required, availablePoints: available)
        }
        return required
    }
}
