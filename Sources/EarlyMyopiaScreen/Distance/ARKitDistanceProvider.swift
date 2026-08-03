import ARKit
import simd

/// Measures eye-to-screen distance using ARKit front-camera face tracking with a HEADLESS
/// `ARSession` — no `ARSCNView`, no SceneKit, no view dependency.
///
/// Ported from the sibling Distance Measure Test app's `EyeDistanceProvider` (bare session +
/// `ARSessionDelegate`, session-lifecycle state machine, interruption auto-restart), adapted to
/// Myotect's protocol: binocular (both eyes averaged, that app selects one eye per test), the
/// plausible band is the configurable 100–300 cm provider range (not its near-vision 10–100 cm),
/// and the session is owned by the coordinator for the WHOLE screening flow — starting at
/// `beginAfterSetup()` and stopping at teardown — so live distance keeps flowing during warm-up
/// and trials, not just on the distance-lock screen.
///
/// 2 m is near ARKit's ~3 m face-tracking envelope, so readings may be noisier than at near range.
final class ARKitDistanceProvider: NSObject, DistanceProvider, ARSessionDelegate {
    var onUpdate: ((DistanceValidity) -> Void)?
    var isAvailable: Bool { ARFaceTrackingConfiguration.isSupported }

    private(set) var state: DistanceTrackingState = .idle
    private(set) var latestSample: DistanceSample?

    private let session = ARSession()
    private let plausibleRange: ClosedRange<Double>
    private let maxReadings: Int
    private let trackingLostTimeout: TimeInterval
    private let updateInterval: TimeInterval

    // Moving-average smoothing over accepted raw readings.
    private var recentReadings: [Double] = []
    /// The raw value of the last reading rejected as implausible; cleared by the next accepted one.
    private var lastRawOutOfRangeCM: Double?

    // Tracking-lost detection: ARKit goes silent (no anchor updates) when the face leaves the
    // frame while the session stays `.tracking`; the watchdog converts that silence into an
    // explicit `.missing` for push consumers. Pull consumers are covered by staleness regardless.
    private var lastFaceUpdate: TimeInterval = 0
    private var watchdog: Timer?

    /// Same-kind pushes are rate-limited; kind changes always deliver immediately.
    private var emissionThrottle = ValidityEmissionThrottle()

    /// True between `start()` and `stop()`; decides whether an ended interruption auto-restarts.
    private var isStarted = false

    init(config: ScreenConfig) {
        self.plausibleRange = config.providerDistanceRangeCM
        self.maxReadings = config.smoothingWindowSamples
        self.trackingLostTimeout = config.trackingLostTimeoutSeconds
        self.updateInterval = config.distanceUpdateIntervalSeconds
        super.init()
        session.delegate = self
        // All delegate callbacks, state mutation, and emission stay on the main thread.
        session.delegateQueue = .main
    }

    func start() {
        isStarted = true
        resetMeasurementState()
        emissionThrottle.reset()
        lastFaceUpdate = now()
        guard isAvailable else {
            state = .unsupported
            onUpdate?(.unsupported)
            return
        }
        state = .tracking
        session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        startWatchdog()
    }

    func stop() {
        isStarted = false
        watchdog?.invalidate()
        watchdog = nil
        session.pause()
        state = .idle
        resetMeasurementState()
    }

    func validity(maximumAge: TimeInterval,
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> DistanceValidity {
        DistanceValidityResolver.resolve(
            state: state,
            latestSample: latestSample,
            lastRawOutOfRangeCM: lastRawOutOfRangeCM,
            plausibleRange: plausibleRange,
            maximumAge: maximumAge,
            now: now)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard state == .tracking,
              let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              let frame = session.currentFrame else { return }

        // Binocular: compose each eye transform into world space, measure eye-to-camera for both,
        // and average. (Eye-to-camera approximates eye-to-optotype-center; the small offset is a
        // documented approximation carried over from the reference app.)
        let cameraColumn = frame.camera.transform.columns.3
        let camera = SIMD3<Float>(cameraColumn.x, cameraColumn.y, cameraColumn.z)
        let leftCM = distanceCM(from: faceAnchor.leftEyeTransform, anchor: faceAnchor, to: camera)
        let rightCM = distanceCM(from: faceAnchor.rightEyeTransform, anchor: faceAnchor, to: camera)
        let rawCM = (leftCM + rightCM) / 2

        lastFaceUpdate = now()
        emitThrottled(ingest(rawDistanceCM: rawCM, timestamp: now()))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        state = .interrupted
        resetMeasurementState()
        onUpdate?(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard isStarted else {
            state = .idle
            return
        }
        state = .tracking
        resetMeasurementState()
        lastFaceUpdate = now()
        session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        state = .failed
        resetMeasurementState()
        onUpdate?(.failed)
    }

    // MARK: - Ingestion

    /// Pure ingestion step, exposed for unit tests. A reading outside the plausible band clears
    /// the smoothing buffer and the sample — an implausible value is never delivered as
    /// trustworthy, only reported as `.outOfRange`. Accepted readings are smoothed and become
    /// the new `latestSample`.
    func ingest(rawDistanceCM: Double, timestamp: TimeInterval) -> DistanceValidity {
        guard rawDistanceCM.isFinite, plausibleRange.contains(rawDistanceCM) else {
            recentReadings.removeAll()
            latestSample = nil
            lastRawOutOfRangeCM = rawDistanceCM
            return .outOfRange(rawCM: rawDistanceCM)
        }
        recentReadings.append(rawDistanceCM)
        if recentReadings.count > maxReadings { recentReadings.removeFirst() }
        let sample = DistanceSample(
            distanceCM: recentReadings.reduce(0, +) / Double(recentReadings.count),
            timestamp: timestamp)
        latestSample = sample
        lastRawOutOfRangeCM = nil
        return .valid(sample)
    }

    // MARK: - Tracking-lost watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, state == .tracking else { return }
            if now() - lastFaceUpdate > trackingLostTimeout {
                recentReadings.removeAll()
                latestSample = nil
                lastRawOutOfRangeCM = nil
                emitThrottled(.missing)
            }
        }
    }

    // MARK: - Helpers

    private func resetMeasurementState() {
        recentReadings.removeAll()
        latestSample = nil
        lastRawOutOfRangeCM = nil
    }

    private func emitThrottled(_ validity: DistanceValidity) {
        guard emissionThrottle.shouldEmit(validity, now: now(), minInterval: updateInterval) else { return }
        onUpdate?(validity)
    }

    private func distanceCM(from eyeTransform: simd_float4x4,
                            anchor: ARFaceAnchor,
                            to camera: SIMD3<Float>) -> Double {
        let world = simd_mul(anchor.transform, eyeTransform)
        let eye = SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        return Double(simd_distance(eye, camera)) * 100
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
