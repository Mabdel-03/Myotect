import Foundation

/// Supplies live eye-to-screen distance with an explicit trust verdict.
///
/// The provider's only job is clean, validated samples; all test policy (target band, stability
/// window, move-closer/farther decisions) lives in ``DistanceStabilityEvaluator`` / the
/// coordinator, so providers stay reusable and the policy stays unit testable with
/// ``MockDistanceProvider``.
///
/// Consumption is dual push/pull: the throttled ``onUpdate`` push drives the coordinator's
/// reactive state machine, while the pull-side ``validity(maximumAge:now:)`` answers "can this
/// distance be trusted right now?" at decision points (answer scoring, stimulus sizing) from the
/// freshest state, never a cached callback value.
protocol DistanceProvider: AnyObject {
    /// AR session lifecycle state.
    var state: DistanceTrackingState { get }
    /// Most recent accepted sample; nil before the first face, after face loss, or when stopped.
    var latestSample: DistanceSample? { get }
    /// Invoked on the main thread. Same-kind updates are throttled to the configured interval;
    /// kind transitions (e.g. valid → outOfRange) deliver immediately.
    var onUpdate: ((DistanceValidity) -> Void)? { get set }
    /// Whether this device can provide real distance (e.g. ARKit face tracking supported).
    var isAvailable: Bool { get }
    func start()
    func stop()
    /// Fresh pull-side verdict for answer-time gating.
    func validity(maximumAge: TimeInterval, now: TimeInterval) -> DistanceValidity
}

extension DistanceProvider {
    /// The latest sample only if it can be trusted right now; nil otherwise.
    func validSample(maximumAge: TimeInterval,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> DistanceSample? {
        if case .valid(let sample) = validity(maximumAge: maximumAge, now: now) { return sample }
        return nil
    }
}
