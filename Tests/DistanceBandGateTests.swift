import XCTest
@testable import Myotect

final class DistanceBandGateTests: XCTestCase {

    /// Myotect's protocol band with the gold-standard tolerance parameters: the fractional inset
    /// (0.25 x 60 = 15) is capped at 3 cm per side.
    private let gate = DistanceBandGate(band: 180...240, maxInsetCM: 3, insetFraction: 0.25)

    func testStandardBandInsetIsCapped() {
        XCTAssertEqual(gate.band, 180...240)
        XCTAssertEqual(gate.resumeBand, 183...237)
    }

    func testNarrowBandUsesFractionalInset() {
        // Width 10 -> 0.25 x 10 = 2.5, under the 3 cm cap.
        let narrow = DistanceBandGate(band: 195...205, maxInsetCM: 3, insetFraction: 0.25)
        XCTAssertEqual(narrow.resumeBand, 197.5...202.5)
    }

    func testShouldPauseJustOutsideRawBounds() {
        XCTAssertTrue(gate.shouldPause(distanceCM: 179.99))
        XCTAssertTrue(gate.shouldPause(distanceCM: 240.01))
    }

    func testShouldNotPauseAtRawBounds() {
        XCTAssertFalse(gate.shouldPause(distanceCM: 180))
        XCTAssertFalse(gate.shouldPause(distanceCM: 240))
    }

    func testShouldNotPauseInsideBand() {
        XCTAssertFalse(gate.shouldPause(distanceCM: 200))
    }

    func testResumeBandRejectsShallowReentry() {
        // Back inside the raw band but not past the inset — a pause must not lift here.
        XCTAssertFalse(gate.isWithinResumeBand(distanceCM: 181))
        XCTAssertFalse(gate.isWithinResumeBand(distanceCM: 239))
    }

    func testResumeBandAcceptsInsetBoundary() {
        XCTAssertTrue(gate.isWithinResumeBand(distanceCM: 183))
        XCTAssertTrue(gate.isWithinResumeBand(distanceCM: 237))
    }

    func testDegenerateTinyBandDoesNotInvert() {
        // Width 1 -> per-side inset 0.5, so the insets meet: collapses to the midpoint.
        let tiny = DistanceBandGate(band: 200...201, maxInsetCM: 3, insetFraction: 0.5)
        XCTAssertLessThanOrEqual(tiny.resumeBand.lowerBound, tiny.resumeBand.upperBound)
        XCTAssertEqual(tiny.resumeBand, 200.5...200.5)
        XCTAssertTrue(tiny.isWithinResumeBand(distanceCM: 200.5))
        XCTAssertFalse(tiny.isWithinResumeBand(distanceCM: 200.4))
    }

    func testZeroWidthBandCollapsesToItself() {
        let point = DistanceBandGate(band: 200...200, maxInsetCM: 3, insetFraction: 0.25)
        XCTAssertEqual(point.resumeBand, 200...200)
        XCTAssertFalse(point.shouldPause(distanceCM: 200))
        XCTAssertTrue(point.shouldPause(distanceCM: 200.01))
    }

    func testZeroInsetKeepsResumeBandEqualToBand() {
        let flat = DistanceBandGate(band: 180...240, maxInsetCM: 0, insetFraction: 0.25)
        XCTAssertEqual(flat.resumeBand, 180...240)
    }
}
