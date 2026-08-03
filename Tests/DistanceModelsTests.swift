import XCTest
@testable import Myotect

final class DistanceModelsTests: XCTestCase {

    /// Injected range deliberately unlike the gold app's 10...100 so any hard-coded band fails.
    private let range: ClosedRange<Double> = 100...300
    private let maxAge: TimeInterval = 0.5

    private func sample(_ distanceCM: Double, at timestamp: TimeInterval = 100) -> DistanceSample {
        DistanceSample(distanceCM: distanceCM, timestamp: timestamp)
    }

    // MARK: - DistanceSample.isValid

    func testFreshInRangeSampleIsValid() {
        XCTAssertTrue(sample(200).isValid(at: 100.1, maximumAge: maxAge, plausibleRange: range))
    }

    func testAgeExactlyAtMaximumIsValid() {
        XCTAssertTrue(sample(200).isValid(at: 100 + maxAge, maximumAge: maxAge, plausibleRange: range))
    }

    func testAgeJustOverMaximumIsInvalid() {
        XCTAssertFalse(sample(200).isValid(at: 100 + maxAge + 0.001, maximumAge: maxAge, plausibleRange: range))
    }

    func testNegativeAgeIsInvalid() {
        // Timestamp in the future relative to `now` — garbage, never valid.
        XCTAssertFalse(sample(200, at: 100.5).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
    }

    func testNaNDistanceIsInvalid() {
        XCTAssertFalse(sample(.nan).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
    }

    func testInfiniteDistanceIsInvalid() {
        XCTAssertFalse(sample(.infinity).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
        XCTAssertFalse(sample(-.infinity).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
    }

    func testBoundaryDistancesAreValid() {
        XCTAssertTrue(sample(100).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
        XCTAssertTrue(sample(300).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
    }

    func testJustOutsideRangeIsInvalid() {
        XCTAssertFalse(sample(99.99).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
        XCTAssertFalse(sample(300.01).isValid(at: 100, maximumAge: maxAge, plausibleRange: range))
    }

    func testNegativeMaximumAgeIsInvalid() {
        XCTAssertFalse(sample(200).isValid(at: 100, maximumAge: -0.5, plausibleRange: range))
    }

    // MARK: - DistanceValidityResolver

    private func resolve(state: DistanceTrackingState,
                         latestSample: DistanceSample? = nil,
                         lastRawOutOfRangeCM: Double? = nil,
                         now: TimeInterval = 100) -> DistanceValidity {
        DistanceValidityResolver.resolve(
            state: state,
            latestSample: latestSample,
            lastRawOutOfRangeCM: lastRawOutOfRangeCM,
            plausibleRange: range,
            maximumAge: maxAge,
            now: now)
    }

    func testIdleResolvesMissing() {
        XCTAssertEqual(resolve(state: .idle, latestSample: sample(200)), .missing)
    }

    func testUnsupportedResolvesUnsupported() {
        XCTAssertEqual(resolve(state: .unsupported), .unsupported)
    }

    func testInterruptedResolvesInterrupted() {
        XCTAssertEqual(resolve(state: .interrupted), .interrupted)
    }

    func testFailedResolvesFailed() {
        XCTAssertEqual(resolve(state: .failed), .failed)
    }

    func testTrackingWithNoSampleResolvesMissing() {
        XCTAssertEqual(resolve(state: .tracking), .missing)
    }

    func testTrackingWithRawOutOfRangeResolvesOutOfRangeWithPayload() {
        XCTAssertEqual(resolve(state: .tracking, lastRawOutOfRangeCM: 350),
                       .outOfRange(rawCM: 350))
    }

    func testRawOutOfRangeWinsOverStoredSample() {
        // The raw reading is fresher truth than any lingering sample.
        XCTAssertEqual(resolve(state: .tracking, latestSample: sample(200), lastRawOutOfRangeCM: 90),
                       .outOfRange(rawCM: 90))
    }

    func testTrackingWithFreshSampleResolvesValidWithPayload() {
        let fresh = sample(200)
        XCTAssertEqual(resolve(state: .tracking, latestSample: fresh, now: 100.1), .valid(fresh))
    }

    func testAgeExactlyAtMaximumResolvesValid() {
        let fresh = sample(200)
        XCTAssertEqual(resolve(state: .tracking, latestSample: fresh, now: 100 + maxAge), .valid(fresh))
    }

    func testTrackingWithOldSampleResolvesStale() {
        let old = sample(200)
        XCTAssertEqual(resolve(state: .tracking, latestSample: old, now: 100 + maxAge + 0.001),
                       .stale(old))
    }

    func testTrackingWithFutureSampleResolvesStale() {
        let future = sample(200, at: 101)
        XCTAssertEqual(resolve(state: .tracking, latestSample: future, now: 100), .stale(future))
    }

    func testResolverHonorsInjectedRange() {
        // 250 cm is outside the gold app's 10...100 band but inside the injected one.
        let far = sample(250)
        XCTAssertEqual(resolve(state: .tracking, latestSample: far), .valid(far))
        // 50 cm is inside the gold band but outside the injected one — out of range, not stale.
        XCTAssertEqual(resolve(state: .tracking, latestSample: sample(50)),
                       .outOfRange(rawCM: 50))
    }

    func testValiditySampleAccessorReturnsOnlyValidPayload() {
        let fresh = sample(200)
        XCTAssertEqual(DistanceValidity.valid(fresh).sample, fresh)
        XCTAssertNil(DistanceValidity.stale(fresh).sample)
        XCTAssertNil(DistanceValidity.outOfRange(rawCM: 350).sample)
        XCTAssertNil(DistanceValidity.missing.sample)
    }

    // MARK: - ValidityEmissionThrottle

    /// Binary-exact interval and offsets so the exact-boundary expectation is not at the mercy of
    /// floating-point representation (100.1 - 100 < 0.1 in Double).
    private let interval: TimeInterval = 0.25

    func testFirstEmissionAlwaysEmits() {
        var throttle = ValidityEmissionThrottle()
        XCTAssertTrue(throttle.shouldEmit(.missing, now: 100, minInterval: interval))
    }

    func testSameKindWithinIntervalSuppressed() {
        var throttle = ValidityEmissionThrottle()
        _ = throttle.shouldEmit(.valid(sample(200)), now: 100, minInterval: interval)
        XCTAssertFalse(throttle.shouldEmit(.valid(sample(201)), now: 100.125, minInterval: interval))
    }

    func testSameKindAtIntervalEmits() {
        var throttle = ValidityEmissionThrottle()
        _ = throttle.shouldEmit(.valid(sample(200)), now: 100, minInterval: interval)
        XCTAssertTrue(throttle.shouldEmit(.valid(sample(201)), now: 100.25, minInterval: interval))
    }

    func testKindChangeEmitsImmediatelyWithinInterval() {
        var throttle = ValidityEmissionThrottle()
        _ = throttle.shouldEmit(.valid(sample(200)), now: 100, minInterval: interval)
        XCTAssertTrue(throttle.shouldEmit(.outOfRange(rawCM: 350), now: 100.0625, minInterval: interval))
        // And the change back also emits immediately.
        XCTAssertTrue(throttle.shouldEmit(.valid(sample(200)), now: 100.125, minInterval: interval))
    }

    func testSuppressedRepeatDoesNotExtendThrottleWindow() {
        var throttle = ValidityEmissionThrottle()
        _ = throttle.shouldEmit(.missing, now: 100, minInterval: interval)
        _ = throttle.shouldEmit(.missing, now: 100.125, minInterval: interval) // suppressed
        // Window is measured from the last *emission*, not the last attempt.
        XCTAssertTrue(throttle.shouldEmit(.missing, now: 100.25, minInterval: interval))
    }

    func testResetClearsHistory() {
        var throttle = ValidityEmissionThrottle()
        _ = throttle.shouldEmit(.missing, now: 100, minInterval: interval)
        throttle.reset()
        XCTAssertTrue(throttle.shouldEmit(.missing, now: 100.0625, minInterval: interval))
    }
}
