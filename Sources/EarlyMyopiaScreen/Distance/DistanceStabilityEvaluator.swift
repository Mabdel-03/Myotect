import Foundation

/// The user-facing status derived from recent distance samples.
enum DistanceStatus: Equatable {
    case noFace
    case tooClose
    case tooFar
    case holdSteady
    case locked

    /// Short guidance string for the distance-lock screen.
    var guidance: String {
        switch self {
        case .noFace: return "I can't see you. Step into view."
        case .tooClose: return "Move farther away"
        case .tooFar: return "Move closer"
        case .holdSteady: return "Hold still..."
        case .locked: return "Distance locked"
        }
    }
}

/// Pure policy that turns a stream of ``DistanceValidity`` verdicts into a ``DistanceStatus``.
///
/// Locking requires the distance to sit inside the valid band for a continuous window with low
/// variability (standard deviation less than or equal to a threshold). Out-of-band, implausible,
/// or lost-tracking inputs reset the window. Deterministic and unit testable.
struct DistanceStabilityEvaluator {
    var target: Double
    var validRange: ClosedRange<Double>
    var window: TimeInterval
    var maxStandardDeviation: Double

    private var buffer: [DistanceSample] = []

    init(target: Double = 200,
         validRange: ClosedRange<Double> = 180...240,
         window: TimeInterval = 0.75,
         maxStandardDeviation: Double = 5) {
        self.target = target
        self.validRange = validRange
        self.window = window
        self.maxStandardDeviation = maxStandardDeviation
    }

    /// Feeds one validity verdict and returns the resulting status.
    mutating func evaluate(_ validity: DistanceValidity) -> DistanceStatus {
        switch validity {
        case .valid(let sample):
            return evaluateInPlausibleRange(sample)
        case .outOfRange(let rawCM):
            // The plausible range strictly contains the valid band, so direction is well-defined.
            buffer.removeAll()
            return rawCM < validRange.lowerBound ? .tooClose : .tooFar
        case .missing, .stale, .unsupported, .interrupted, .failed:
            buffer.removeAll()
            return .noFace
        }
    }

    private mutating func evaluateInPlausibleRange(_ sample: DistanceSample) -> DistanceStatus {
        guard validRange.contains(sample.distanceCM) else {
            buffer.removeAll()
            return sample.distanceCM < validRange.lowerBound ? .tooClose : .tooFar
        }

        buffer.append(sample)
        // Trim to the window, but keep one sample just beyond the cutoff so the retained span can
        // actually reach the full window (otherwise the oldest in-window sample always sits just
        // under `window` and the lock can never trigger).
        let cutoff = sample.timestamp - window
        while buffer.count > 2, buffer[1].timestamp < cutoff {
            buffer.removeFirst()
        }

        // Need at least `window` of continuous in-band samples before we call it stable.
        guard let first = buffer.first,
              sample.timestamp - first.timestamp >= window,
              buffer.count >= 2 else {
            return .holdSteady
        }

        let distances = buffer.map(\.distanceCM)
        return standardDeviation(distances) <= maxStandardDeviation ? .locked : .holdSteady
    }

    /// Resets the stability window (e.g. on entering the distance-lock screen).
    mutating func reset() {
        buffer.removeAll()
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}
