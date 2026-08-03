import Foundation

/// Pure hysteresis policy for pausing and resuming trials at the valid distance band.
///
/// Pausing triggers on the full `band` edge — the moment the live distance leaves the raw bounds
/// (matching the gold standard's `checkDistance`, ETDRSViewController.swift:943-956). Resuming is
/// stricter: the distance must re-enter the inset `resumeBand` (each edge pulled inward by
/// `min(maxInsetCM, insetFraction × bandWidth)`), and the existing dwell re-lock
/// (`DistanceStabilityEvaluator`, 0.75 s window) must then confirm stability. Myotect keeps its
/// dwell requirement and gains the gold standard's entry tolerance, so a subject hovering at a
/// band edge cannot chatter the pause state at sample rate.
struct DistanceBandGate: Equatable {
    /// Full valid band; leaving it pauses the trial.
    let band: ClosedRange<Double>
    /// Inset band the distance must re-enter before a pause can lift.
    let resumeBand: ClosedRange<Double>

    /// - Parameters:
    ///   - band: full valid band (the pause bounds).
    ///   - maxInsetCM: cap on the per-side inset, in centimeters.
    ///   - insetFraction: per-side inset as a fraction of the band width.
    init(band: ClosedRange<Double>, maxInsetCM: Double, insetFraction: Double) {
        self.band = band
        let width = band.upperBound - band.lowerBound
        let inset = max(0, min(maxInsetCM, insetFraction * width))
        if inset * 2 >= width {
            // Degenerate: insets from both sides would meet or cross. Collapse the resume band to
            // the midpoint so it can never invert; the dwell re-lock still guards resumption.
            let midpoint = band.lowerBound + width / 2
            self.resumeBand = midpoint...midpoint
        } else {
            self.resumeBand = (band.lowerBound + inset)...(band.upperBound - inset)
        }
    }

    /// Whether a live distance should pause the trial (outside the full band).
    func shouldPause(distanceCM: Double) -> Bool {
        !band.contains(distanceCM)
    }

    /// Whether the distance has re-entered the inset band required to lift a pause.
    func isWithinResumeBand(distanceCM: Double) -> Bool {
        resumeBand.contains(distanceCM)
    }
}
