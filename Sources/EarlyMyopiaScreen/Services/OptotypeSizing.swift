import UIKit

/// How a `ScreenCalibration` was obtained.
enum CalibrationSource: String, Codable {
    /// Verified PPI from the DevicePpi database.
    case deviceDatabase
    /// Operator-measured via the on-screen ruler.
    case manual
    /// Pre-calibration data with no recorded source; never valid for sizing.
    case legacyUnknown
}

/// Locale-stable numeric formatting for calibration identity strings.
enum SizingMetadataFormat {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.*f", locale: locale, places, value)
    }
}

/// The points-to-physical-millimeters conversion for one exact display, plus the identity needed
/// to detect when it no longer applies.
///
/// Ported from the sibling Distance Measure Test app (`Core/OptotypeSizing.swift`).
struct ScreenCalibration: Codable, Equatable {
    static let schemaVersion = 1

    let pointsPerMillimeter: Double
    /// `UIScreen.main.nativeScale` — physical pixels per point. Distinct from the logical `scale`
    /// on downsampled Plus-class displays, where using the logical scale undersizes optotypes ~13%.
    let nativeScale: Double
    let source: CalibrationSource
    let screenSignature: String
    let schemaVersion: Int

    var isValidated: Bool {
        pointsPerMillimeter.isFinite
            && pointsPerMillimeter > 0
            && nativeScale.isFinite
            && nativeScale > 0
            && source != .legacyUnknown
            && schemaVersion == Self.schemaVersion
    }

    /// Half of one physical pixel expressed in points — the smallest height change worth
    /// re-rendering for during live re-sizing.
    var halfPhysicalPixelInPoints: CGFloat {
        CGFloat(0.5 / nativeScale)
    }
}

/// A per-trial record of exactly how a scored optotype was sized, re-validated against the current
/// calibration before scoring so a stimulus rendered under stale assumptions is never counted.
struct SizingProvenance: Codable, Equatable {
    static let currentVersion = 2

    let sizingVersion: Int
    let calibrationSource: CalibrationSource
    let pointsPerMillimeter: Double
    let screenSignature: String
    let targetHeightMillimeters: Double
    let renderedHeightPoints: Double

    func matches(_ calibration: ScreenCalibration) -> Bool {
        sizingVersion == Self.currentVersion
            && calibrationSource == calibration.source
            && pointsPerMillimeter == calibration.pointsPerMillimeter
            && screenSignature == calibration.screenSignature
            && calibration.isValidated
    }
}

/// Everything the view layer needs to draw one optotype at a true physical size, plus the
/// provenance recorded when the presentation is scored.
struct OptotypeRenderSpec: Equatable {
    let targetAngleArcMinutes: Double
    let targetAngleRadians: Double
    let targetHeightMillimeters: Double
    let renderedHeightPoints: CGFloat
    let fontPointSize: CGFloat
    let calibration: ScreenCalibration

    var provenance: SizingProvenance {
        SizingProvenance(
            sizingVersion: SizingProvenance.currentVersion,
            calibrationSource: calibration.source,
            pointsPerMillimeter: calibration.pointsPerMillimeter,
            screenSignature: calibration.screenSignature,
            targetHeightMillimeters: targetHeightMillimeters,
            renderedHeightPoints: Double(renderedHeightPoints)
        )
    }

    /// Whether the glyph fits inside a square of `side` points with `innerMargin` points of
    /// clearance on every edge. Sloan glyphs are drawn on a square 5×5 grid (width equals
    /// cap height), so a single height check covers both axes.
    func fitsSquare(side: Double, innerMargin: Double) -> Bool {
        Double(renderedHeightPoints) + 2.0 * innerMargin <= side
    }
}

enum OptotypeSizingError: LocalizedError, Equatable {
    case invalidDistance
    case invalidAcuity
    case invalidCalibration
    case invalidFontMetrics
    case sloanFontUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDistance:
            return "A current positive viewing distance is required."
        case .invalidAcuity:
            return "A positive Snellen denominator is required."
        case .invalidCalibration:
            return "A validated screen calibration is required."
        case .invalidFontMetrics:
            return "The optotype font does not expose valid cap-height metrics."
        case .sloanFontUnavailable:
            return "The Sloan optotype font is unavailable."
        }
    }
}

/// Computes optotype render specs from a measured distance using the standard ETDRS definition:
/// a 20/20 optotype subtends 5 arcminutes of visual angle at the viewing distance.
///
/// Ported from the sibling Distance Measure Test app (`Core/OptotypeSizing.swift`), with the
/// UIKit label/button appliers dropped — Myotect renders in SwiftUI directly from the spec.
enum OptotypeSizing {
    static let snellenNumerator = 20.0
    static let arcMinutesPerTwentyTwentyLetter = 5.0

    static func renderSpec(
        distanceCM: Double,
        snellenDenominator: Int,
        calibration: ScreenCalibration,
        font: UIFont
    ) throws -> OptotypeRenderSpec {
        guard distanceCM.isFinite, distanceCM > 0 else {
            throw OptotypeSizingError.invalidDistance
        }
        guard snellenDenominator > 0 else { throw OptotypeSizingError.invalidAcuity }
        guard calibration.isValidated else { throw OptotypeSizingError.invalidCalibration }
        guard font.pointSize.isFinite,
              font.pointSize > 0,
              font.capHeight.isFinite,
              font.capHeight > 0 else {
            throw OptotypeSizingError.invalidFontMetrics
        }

        let angleArcMinutes = (Double(snellenDenominator) / snellenNumerator)
            * arcMinutesPerTwentyTwentyLetter
        let angleRadians = angleArcMinutes / 60.0 * .pi / 180.0
        let distanceMillimeters = distanceCM * 10.0
        // Exact chord height for the subtended angle, not the small-angle single-tangent
        // approximation (they differ only in the 7th decimal at screening distances).
        let targetHeightMillimeters = 2.0 * distanceMillimeters * tan(angleRadians / 2.0)
        let renderedHeightPoints = CGFloat(
            targetHeightMillimeters * calibration.pointsPerMillimeter
        )
        // Measured from the live font rather than a hand-tuned multiplier, so the rendered cap
        // height equals the target height regardless of the font's internal metrics.
        let capHeightRatio = font.capHeight / font.pointSize
        let fontPointSize = renderedHeightPoints / capHeightRatio

        return OptotypeRenderSpec(
            targetAngleArcMinutes: angleArcMinutes,
            targetAngleRadians: angleRadians,
            targetHeightMillimeters: targetHeightMillimeters,
            renderedHeightPoints: renderedHeightPoints,
            fontPointSize: fontPointSize,
            calibration: calibration
        )
    }

    /// The registered Sloan font at an arbitrary reference size; callers derive the final point
    /// size from `renderSpec`. Throws when registration failed (see `FontRegistrar`) — a
    /// system-font fallback would invalidate the test, so sizing must fail loudly instead.
    static func sloanBaseFont() throws -> UIFont {
        guard let font = UIFont(name: FontRegistrar.sloanName, size: 100) else {
            throw OptotypeSizingError.sloanFontUnavailable
        }
        return font
    }

    /// Half-physical-pixel damping for live re-sizing: re-render only when the candidate height
    /// moved at least half a physical pixel from what is on screen, or when the calibration
    /// changed in ANY field — a stale calibration must never keep damping a stimulus sized under
    /// new assumptions. Full-equality comparison and the CANDIDATE's half-pixel threshold, exactly
    /// as in the gold `OptotypeSizing.needsRender`.
    static func needsRender(
        previousSpec: OptotypeRenderSpec?,
        candidateSpec: OptotypeRenderSpec,
        force: Bool = false
    ) -> Bool {
        guard !force, let previousSpec else { return true }
        guard previousSpec.calibration == candidateSpec.calibration else { return true }
        return abs(candidateSpec.renderedHeightPoints - previousSpec.renderedHeightPoints)
            >= candidateSpec.calibration.halfPhysicalPixelInPoints
    }
}
