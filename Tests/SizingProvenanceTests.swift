import UIKit
import XCTest
@testable import Myotect

final class SizingProvenanceTests: XCTestCase {
    private let calibration = ScreenCalibration(
        pointsPerMillimeter: 6.05,
        nativeScale: 3,
        source: .manual,
        screenSignature: "test-screen",
        schemaVersion: ScreenCalibration.schemaVersion
    )

    // MARK: - matches(_:)

    func testMatchesPassesOnIdentity() throws {
        let spec = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 40,
            calibration: calibration,
            font: UIFont.systemFont(ofSize: 100)
        )
        XCTAssertTrue(spec.provenance.matches(calibration))
        XCTAssertTrue(makeProvenance().matches(calibration))
    }

    func testMatchesFailsOnSizingVersionMismatch() {
        XCTAssertFalse(makeProvenance(sizingVersion: SizingProvenance.currentVersion - 1)
            .matches(calibration))
        XCTAssertFalse(makeProvenance(sizingVersion: SizingProvenance.currentVersion + 1)
            .matches(calibration))
    }

    func testMatchesFailsOnCalibrationSourceMismatch() {
        XCTAssertFalse(makeProvenance(calibrationSource: .deviceDatabase).matches(calibration))
    }

    func testMatchesFailsOnPointsPerMillimeterMismatch() {
        XCTAssertFalse(makeProvenance(pointsPerMillimeter: 6.06).matches(calibration))
    }

    func testMatchesFailsOnScreenSignatureMismatch() {
        XCTAssertFalse(makeProvenance(screenSignature: "different-screen").matches(calibration))
    }

    func testMatchesFailsWhenCalibrationIsNotValidated() {
        // Identity fields all agree, but the calibration itself is stale — it must still fail.
        let staleSchema = ScreenCalibration(
            pointsPerMillimeter: calibration.pointsPerMillimeter,
            nativeScale: calibration.nativeScale,
            source: calibration.source,
            screenSignature: calibration.screenSignature,
            schemaVersion: ScreenCalibration.schemaVersion + 1
        )
        XCTAssertFalse(staleSchema.isValidated)
        XCTAssertFalse(makeProvenance().matches(staleSchema))
    }

    // MARK: - Codable

    func testProvenanceCodableRoundTripPreservesEquality() throws {
        let original = makeProvenance()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SizingProvenance.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.matches(calibration))
    }

    func testCalibrationCodableRoundTripPreservesEquality() throws {
        let data = try JSONEncoder().encode(calibration)
        let decoded = try JSONDecoder().decode(ScreenCalibration.self, from: data)

        XCTAssertEqual(decoded, calibration)
        XCTAssertTrue(decoded.isValidated)
    }

    // MARK: - Helpers

    private func makeProvenance(
        sizingVersion: Int = SizingProvenance.currentVersion,
        calibrationSource: CalibrationSource = .manual,
        pointsPerMillimeter: Double = 6.05,
        screenSignature: String = "test-screen"
    ) -> SizingProvenance {
        SizingProvenance(
            sizingVersion: sizingVersion,
            calibrationSource: calibrationSource,
            pointsPerMillimeter: pointsPerMillimeter,
            screenSignature: screenSignature,
            targetHeightMillimeters: 5.818,
            renderedHeightPoints: 35.2
        )
    }
}
