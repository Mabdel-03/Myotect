import Foundation

/// A scripted distance provider for the simulator, previews, and tests.
///
/// Either drives a fixed "locked" distance automatically, or replays a supplied script of events
/// on a timer. Lets the entire flow — including interruption and face-loss handling — be
/// exercised without a physical TrueDepth device. The pull side (`validity`) answers from the
/// mock's own current state so answer-time gating passes in the simulator.
final class MockDistanceProvider: DistanceProvider {
    /// One scripted emission. Distances are classified against the plausible range exactly like
    /// the real provider (in-range → `.valid`, outside → `.outOfRange`).
    enum ScriptEvent: Equatable {
        case distance(Double)
        case faceLost
        case interruption
        case interruptionEnded
        case failure
    }

    var onUpdate: ((DistanceValidity) -> Void)?
    let isAvailable = true

    private(set) var state: DistanceTrackingState = .idle
    private(set) var latestSample: DistanceSample?

    private let plausibleRange: ClosedRange<Double>
    private let steadyDistanceCM: Double
    private let interval: TimeInterval
    private var script: [ScriptEvent]
    private var scriptIndex = 0
    private var timer: Timer?
    private var tick: TimeInterval = 0
    private var lastValidity: DistanceValidity = .missing

    init(steadyDistanceCM: Double = 200,
         interval: TimeInterval = 0.1,
         script: [ScriptEvent] = [],
         config: ScreenConfig = ScreenConfig()) {
        self.steadyDistanceCM = steadyDistanceCM
        self.interval = interval
        self.script = script
        self.plausibleRange = config.providerDistanceRangeCM
    }

    func start() {
        state = .tracking
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.emitNext()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        state = .idle
        latestSample = nil
        lastValidity = .missing
    }

    func validity(maximumAge: TimeInterval, now: TimeInterval) -> DistanceValidity {
        // The mock's samples are always "fresh": it answers from its current scripted state, so
        // flows and tests exercise the coordinator's gating logic, not wall-clock timing.
        lastValidity
    }

    private func emitNext() {
        tick += interval
        let event: ScriptEvent
        if scriptIndex < script.count {
            event = script[scriptIndex]
            scriptIndex += 1
        } else {
            event = .distance(steadyDistanceCM)
        }
        emit(validity(for: event))
    }

    private func validity(for event: ScriptEvent) -> DistanceValidity {
        switch event {
        case .distance(let cm):
            guard plausibleRange.contains(cm) else {
                latestSample = nil
                return .outOfRange(rawCM: cm)
            }
            let sample = DistanceSample(distanceCM: cm, timestamp: tick)
            latestSample = sample
            state = .tracking
            return .valid(sample)
        case .faceLost:
            latestSample = nil
            return .missing
        case .interruption:
            state = .interrupted
            latestSample = nil
            return .interrupted
        case .interruptionEnded:
            state = .tracking
            return .missing
        case .failure:
            state = .failed
            latestSample = nil
            return .failed
        }
    }

    private func emit(_ validity: DistanceValidity) {
        lastValidity = validity
        onUpdate?(validity)
    }
}
