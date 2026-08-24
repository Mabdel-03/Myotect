import Foundation

/// The staircase protocol parameters in force for a session, persisted alongside the trials so a
/// recorded response can always be interpreted against the exact protocol that produced it
/// (analog of the gold app's `TestProtocolMetadata`).
struct StaircaseProtocolMetadata: Codable, Equatable {
    let trialsPerLevel: Int
    let advanceThreshold: Int
    let earlySkipCount: Int
    let lineLogMARIncrement: Double
    let logMARPerLetter: Double

    init(config: AcuityStaircaseConfig) {
        trialsPerLevel = config.trialsPerLevel
        advanceThreshold = config.advanceThreshold
        earlySkipCount = config.earlySkipCount
        lineLogMARIncrement = config.lineLogMARIncrement
        logMARPerLetter = config.logMARPerLetter
    }
}

/// One complete screening session record. Codable for JSON export.
///
/// This is a research/screening artifact, not a diagnosis. No validated threshold is stored; the
/// red-green logMAR delta is recorded raw for later analysis.
struct MyopiaScreenSession: Codable, Equatable {
    let sessionID: String
    let startedAt: Date
    var completedAt: Date?

    let appVersion: String
    let deviceModel: String
    /// Physical panel PPI derived from the session calibration (kept for export compatibility).
    /// Zero until the session actually begins.
    var ppiUsed: Double
    let targetDistanceCM: Double
    let weberContrast: Double
    let letterSet: [String]

    var highContrast: AcuityConditionResult?
    var lowContrastRed: AcuityConditionResult?
    var lowContrastGreen: AcuityConditionResult?

    /// `green.logMAR - red.logMAR`. Positive means red was read better than green, which is the
    /// pattern under investigation for subtle myopic defocus. Interpretation thresholds are not set.
    var duochromeDeltaLogMAR: Double?

    /// Free-text, research-only interpretation label (never a medical diagnosis).
    var interpretation: String

    var trials: [TrialResult]

    var aborted: Bool
    var abortReason: String?

    /// The validated screen calibration in force when the session began. Optional so pre-upgrade
    /// session JSON still decodes.
    var calibration: ScreenCalibration? = nil

    /// Mean of the readings across the operator-initiated capture hold — where the subject
    /// actually locked, as distinct from the fixed `targetDistanceCM`. Optional so pre-upgrade
    /// session JSON still decodes (and nil when the lock phase was skipped manually).
    var lockedDistanceCM: Double? = nil

    /// The staircase protocol parameters the session ran under. Optional so pre-upgrade session
    /// JSON still decodes.
    var staircaseProtocol: StaircaseProtocolMetadata? = nil

    /// Recomputes the duochrome delta from the two low-contrast results, if both are present.
    mutating func recomputeDelta() {
        if let red = lowContrastRed, let green = lowContrastGreen {
            duochromeDeltaLogMAR = green.logMAR - red.logMAR
        } else {
            duochromeDeltaLogMAR = nil
        }
    }
}
