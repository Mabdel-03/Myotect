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
    /// Gate denominator for the high-contrast condition.
    var gateAcuity: Int = 25

    // MARK: Contrast
    /// Weber contrast for the two low-contrast conditions. 10% by default; operator-selectable
    /// 5/10/15% in Settings. Read once when the screening flow launches — immutable mid-session
    /// (and recorded on the session as `weberContrast`).
    var lowContrastWeber: Double = 0.10
    var backgroundBrightness: Double = 1.0

    // MARK: Display
    var testBrightness: CGFloat = 1.0

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
    /// Per-answer listening window before the final flush ends the attempt. 8 s (up from the
    /// original 6) leaves room for a hesitant child once Whisper's ~0.5 s poll cadence and
    /// inference latency eat into the tail; the retry cap bounds the worst case.
    var recognitionTimeoutSeconds: TimeInterval = 8
    /// Failed attempts (unrecognized/ambiguous) allowed per trial before the trial escalates to
    /// the clinician keypad. The first retry carries a spoken re-prompt.
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
    /// Delay between an announcement finishing and recognition re-arming, so the tail of the
    /// prompt never bleeds into Whisper's capture window (gold-standard: 1.5 s).
    var listenResumeAfterSpeechSeconds: TimeInterval = 1.5
    /// Minimum interval before the SAME distance-guidance prompt repeats.
    var distancePromptMinIntervalSeconds: TimeInterval = 5
    /// When true, "Say the letter you see." is spoken before every scored trial (default: only
    /// at phase transitions and on the first retry, to keep trials fast).
    var speakEveryTrialPrompt: Bool = false

    // MARK: Privacy / data
    /// Off by default. Raw audio buffers or face geometry are not stored unless this research flag is enabled.
    var persistRawSignals: Bool = false

    init() {}

    /// Builds a staircase config for a condition; only the high-contrast condition is gated.
    func staircaseConfig(gated: Bool) -> AcuityStaircaseConfig {
        var config = AcuityStaircaseConfig()
        config.acuityLevels = acuityLevels
        config.startAcuity = startAcuity
        config.trialsPerLevel = trialsPerLevel
        config.advanceThreshold = advanceThreshold
        config.earlySkipCount = earlySkipCount
        config.gateAcuity = gated ? gateAcuity : nil
        return config
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
