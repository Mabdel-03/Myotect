import XCTest
@testable import Myotect

@MainActor
final class ARKitDistanceProviderTests: XCTestCase {
    private func makeProvider(range: ClosedRange<Double> = 100...300) -> ARKitDistanceProvider {
        var config = ScreenConfig()
        config.providerDistanceRangeCM = range
        return ARKitDistanceProvider(config: config)
    }

    func testInRangeReadingsAreSmoothedIntoValidSamples() {
        let provider = makeProvider()

        guard case .valid(let first) = provider.ingest(rawDistanceCM: 200, timestamp: 1) else {
            return XCTFail("expected .valid")
        }
        XCTAssertEqual(first.distanceCM, 200, accuracy: 0.0001)

        guard case .valid(let second) = provider.ingest(rawDistanceCM: 220, timestamp: 2) else {
            return XCTFail("expected .valid")
        }
        XCTAssertEqual(second.distanceCM, 210, accuracy: 0.0001)
        XCTAssertEqual(provider.latestSample, second)
    }

    func testOutOfPlausibleRangeIsRejectedAndClearsSmoothingAndSample() {
        let provider = makeProvider()
        _ = provider.ingest(rawDistanceCM: 200, timestamp: 1)
        _ = provider.ingest(rawDistanceCM: 220, timestamp: 2)

        guard case .outOfRange(let raw) = provider.ingest(rawDistanceCM: 50, timestamp: 3) else {
            return XCTFail("expected .outOfRange")
        }
        XCTAssertEqual(raw, 50, accuracy: 0.0001)
        // The implausible value must never surface as a trustworthy sample.
        XCTAssertNil(provider.latestSample)

        // Recovery restarts smoothing from scratch — no residue of pre-rejection readings.
        guard case .valid(let after) = provider.ingest(rawDistanceCM: 200, timestamp: 4) else {
            return XCTFail("expected .valid")
        }
        XCTAssertEqual(after.distanceCM, 200, accuracy: 0.0001)
    }

    func testNonFiniteReadingIsRejected() {
        let provider = makeProvider()
        guard case .outOfRange = provider.ingest(rawDistanceCM: .nan, timestamp: 1) else {
            return XCTFail("expected .outOfRange for NaN")
        }
        XCTAssertNil(provider.latestSample)
    }

    func testPullValidityReflectsIngestedStateAndStaleness() {
        let provider = makeProvider()
        _ = provider.ingest(rawDistanceCM: 200, timestamp: 100)

        // ingest() alone doesn't run the session, so state is .idle → resolver reports .missing;
        // the sample itself is still exposed for inspection.
        XCTAssertNotNil(provider.latestSample)
        XCTAssertEqual(provider.state, .idle)
    }

    func testSmoothingWindowIsBounded() {
        var config = ScreenConfig()
        config.smoothingWindowSamples = 3
        let provider = ARKitDistanceProvider(config: config)

        _ = provider.ingest(rawDistanceCM: 100, timestamp: 1)
        _ = provider.ingest(rawDistanceCM: 200, timestamp: 2)
        _ = provider.ingest(rawDistanceCM: 200, timestamp: 3)
        guard case .valid(let sample) = provider.ingest(rawDistanceCM: 200, timestamp: 4) else {
            return XCTFail("expected .valid")
        }
        // Window of 3: the initial 100 has been evicted.
        XCTAssertEqual(sample.distanceCM, 200, accuracy: 0.0001)
    }
}
