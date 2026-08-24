import Foundation

/// Pure policy for the user-initiated distance capture: a tap anchors a hold to the reading the
/// operator just decided was right, and the phone then has to stay put for `durationSeconds`.
///
/// Port of the gold-standard `DistanceOptimization` hold flow ("User-initiated distance capture
/// with a 2-second steady hold"): only readings taken inside the hold window feed the captured
/// value, so a reading grabbed mid-movement can never become the recorded distance. Drifting
/// further than `toleranceCM` from the anchor — or losing face tracking — voids the hold. The
/// captured value is the mean of every timestamp-deduped reading across the steady window.
///
/// Progress is driven entirely by the samples' own monotonic timestamps (never wall clock), so
/// the tracker is deterministic and unit testable like ``DistanceStabilityEvaluator``.
struct DistanceHoldTracker {
    /// How long the phone must stay put after the tap (gold: 2.0 s).
    let durationSeconds: TimeInterval
    /// Maximum deviation from the anchor before the hold voids (gold: 4.0 cm).
    let toleranceCM: Double

    /// Why an in-progress hold was cancelled.
    enum VoidReason: Equatable {
        /// A reading drifted more than `toleranceCM` from the anchor.
        case movedTooMuch
        /// Tracking stopped delivering a valid sample mid-hold.
        case faceLost
    }

    /// What one sample did to the in-progress hold.
    enum Event: Equatable {
        /// Still holding; `remainingSeconds` is the whole-second countdown to show ("2 s" → "1 s").
        case progress(remainingSeconds: Int)
        /// The hold completed: `meanDistanceCM` is the mean of all deduped readings in the window.
        case completed(meanDistanceCM: Double, readingCount: Int)
        /// The hold was voided; the operator has to try again.
        case voided(VoidReason)
    }

    private(set) var isActive = false
    private var anchorDistanceCM: Double = 0
    private var startTimestamp: TimeInterval = 0
    private var lastRecordedTimestamp: TimeInterval = 0
    private var readings: [Double] = []

    init(durationSeconds: TimeInterval, toleranceCM: Double) {
        self.durationSeconds = durationSeconds
        self.toleranceCM = toleranceCM
    }

    /// Starts a hold anchored to `sample` — the reading at the moment of the tap.
    mutating func begin(with sample: DistanceSample) {
        isActive = true
        anchorDistanceCM = sample.distanceCM
        startTimestamp = sample.timestamp
        lastRecordedTimestamp = sample.timestamp
        readings = [sample.distanceCM]
    }

    /// Abandons an in-progress hold without any event (back navigation, backgrounding).
    mutating func cancel() {
        reset()
    }

    /// Feeds one validity verdict into the hold. Returns nil when no hold is active.
    /// A `completed`/`voided` event ends the hold; the tracker is inactive afterwards.
    mutating func update(with validity: DistanceValidity) -> Event? {
        guard isActive else { return nil }

        guard case .valid(let sample) = validity else {
            reset()
            return .voided(.faceLost)
        }
        guard abs(sample.distanceCM - anchorDistanceCM) <= toleranceCM else {
            reset()
            return .voided(.movedTooMuch)
        }

        // Providers can repeat a sample faster than it refreshes; averaging it in twice would
        // overweight it (gold dedupes by timestamp the same way).
        if sample.timestamp != lastRecordedTimestamp {
            lastRecordedTimestamp = sample.timestamp
            readings.append(sample.distanceCM)
        }

        let elapsed = sample.timestamp - startTimestamp
        guard elapsed >= durationSeconds else {
            let remaining = max(0, Int((durationSeconds - elapsed).rounded(.up)))
            return .progress(remainingSeconds: remaining)
        }

        let mean = readings.reduce(0, +) / Double(readings.count)
        let count = readings.count
        reset()
        return .completed(meanDistanceCM: mean, readingCount: count)
    }

    private mutating func reset() {
        isActive = false
        anchorDistanceCM = 0
        startTimestamp = 0
        lastRecordedTimestamp = 0
        readings.removeAll()
    }
}
