import Foundation

/// A single smoothed eye-to-screen distance reading.
///
/// Timestamps are monotonic (`ProcessInfo.processInfo.systemUptime`), not wall-clock dates, so age
/// math is immune to clock changes and matches the timestamps ARKit providers already use.
struct DistanceSample: Equatable {
    /// Smoothed eye-to-screen distance in centimeters.
    let distanceCM: Double
    /// Monotonic timestamp of the reading (`ProcessInfo.systemUptime`).
    let timestamp: TimeInterval

    /// Whether this sample can be trusted at `now`.
    ///
    /// Rejects non-finite distances, distances outside `plausibleRange`, samples older than
    /// `maximumAge`, and samples with a negative age (future/garbage timestamps). Port of the
    /// gold-standard `EyeDistanceSample.isValid`, with the range injected instead of fixed.
    func isValid(at now: TimeInterval, maximumAge: TimeInterval, plausibleRange: ClosedRange<Double>) -> Bool {
        let age = now - timestamp
        return distanceCM.isFinite
            && maximumAge.isFinite
            && maximumAge >= 0
            && plausibleRange.contains(distanceCM)
            && age.isFinite
            && age >= 0
            && age <= maximumAge
    }
}

/// Lifecycle state of a distance provider's underlying tracking session.
enum DistanceTrackingState: Equatable {
    /// Not started, or stopped.
    case idle
    /// Session running; readings are being delivered.
    case tracking
    /// Device cannot track faces (no TrueDepth camera).
    case unsupported
    /// Session interrupted (backgrounding, camera contention); may auto-resume.
    case interrupted
    /// Session failed with an unrecoverable error.
    case failed
}

/// The trustworthiness of the current distance reading, resolved from provider state plus the
/// latest sample. Only `.valid` carries a usable sample; everything else explains why there is
/// none, so the coordinator can pause, guide, or gate scoring accordingly.
enum DistanceValidity: Equatable {
    case valid(DistanceSample)
    /// Tracking has produced no reading yet (or the provider is idle).
    case missing
    /// A reading exists but is too old (or has a garbage future timestamp) to trust.
    case stale(DistanceSample)
    /// The most recent raw reading fell outside the plausible band; the raw value enables
    /// directional guidance without ever being treated as a measurement.
    case outOfRange(rawCM: Double)
    case unsupported
    case interrupted
    case failed

    /// The usable sample — the `.valid` payload only. A stale sample is never surfaced here.
    var sample: DistanceSample? {
        if case .valid(let sample) = self { return sample }
        return nil
    }

    /// Payload-free case discriminator, used by ``ValidityEmissionThrottle`` to distinguish
    /// state changes (emit immediately) from same-state repeats (throttled).
    var kind: Kind {
        switch self {
        case .valid: return .valid
        case .missing: return .missing
        case .stale: return .stale
        case .outOfRange: return .outOfRange
        case .unsupported: return .unsupported
        case .interrupted: return .interrupted
        case .failed: return .failed
        }
    }

    /// Discriminator for ``DistanceValidity`` cases, ignoring payloads.
    enum Kind: Equatable {
        case valid
        case missing
        case stale
        case outOfRange
        case unsupported
        case interrupted
        case failed
    }
}

/// Pure port of the gold-standard validity resolver (`EyeDistanceProvider.validity`), adapted to
/// carry payloads and an injected plausible range — never the gold app's hard-coded 10–100 cm.
enum DistanceValidityResolver {
    /// Resolves what the current reading is worth.
    ///
    /// Decision order mirrors the gold resolver:
    /// 1. Non-tracking states map straight through (`idle` reports `.missing` — a stopped
    ///    provider simply has nothing, it is not an error).
    /// 2. While tracking, a raw out-of-plausible reading wins: the provider cleared its sample
    ///    when it saw one, so the raw value is the freshest truth and drives directional guidance.
    /// 3. No sample yet means `.missing` (tracking has not produced a reading).
    /// 4. A stored sample that is non-finite or outside `plausibleRange` is `.outOfRange`
    ///    (defensive; providers should never store one).
    /// 5. With distance plausibility already established, the only remaining failure
    ///    ``DistanceSample/isValid(at:maximumAge:plausibleRange:)`` can report is age — too old
    ///    or timestamped in the future — which is `.stale`.
    static func resolve(
        state: DistanceTrackingState,
        latestSample: DistanceSample?,
        lastRawOutOfRangeCM: Double?,
        plausibleRange: ClosedRange<Double>,
        maximumAge: TimeInterval,
        now: TimeInterval
    ) -> DistanceValidity {
        switch state {
        case .idle:
            return .missing
        case .unsupported:
            return .unsupported
        case .interrupted:
            return .interrupted
        case .failed:
            return .failed
        case .tracking:
            if let rawCM = lastRawOutOfRangeCM { return .outOfRange(rawCM: rawCM) }
            guard let sample = latestSample else { return .missing }
            guard sample.distanceCM.isFinite, plausibleRange.contains(sample.distanceCM) else {
                return .outOfRange(rawCM: sample.distanceCM)
            }
            guard sample.isValid(at: now, maximumAge: maximumAge, plausibleRange: plausibleRange) else {
                return .stale(sample)
            }
            return .valid(sample)
        }
    }
}

/// Pure rate limiter for validity updates pushed to the coordinator.
///
/// A change of validity ``DistanceValidity/kind`` always emits immediately — state transitions
/// must never wait out a throttle window. Same-kind repeats are limited to one per `minInterval`,
/// turning ~60 Hz ARKit callbacks into a monitoring cadence instead of thrashing SwiftUI.
struct ValidityEmissionThrottle {
    private var lastEmittedKind: DistanceValidity.Kind?
    private var lastEmittedAt: TimeInterval?

    /// Returns whether `validity` should be emitted at `now`, recording the emission if so.
    mutating func shouldEmit(_ validity: DistanceValidity, now: TimeInterval, minInterval: TimeInterval) -> Bool {
        if let kind = lastEmittedKind, let emittedAt = lastEmittedAt,
           kind == validity.kind, now - emittedAt < minInterval {
            return false
        }
        lastEmittedKind = validity.kind
        lastEmittedAt = now
        return true
    }

    /// Forgets emission history (e.g. on provider restart) so the next update emits immediately.
    mutating func reset() {
        lastEmittedKind = nil
        lastEmittedAt = nil
    }
}
