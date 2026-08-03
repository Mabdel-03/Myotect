import UIKit
import XCTest
@testable import Myotect

final class OptotypeSizingTests: XCTestCase {
    /// Myotect's staircase levels, coarsest first (matches `ScreenConfig.acuityLevels`).
    private let acuityLevels = [200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16]

    // MARK: - Geometry

    func testAllAcuitiesAcrossProviderDistanceRange() throws {
        let calibration = makeCalibration(pointsPerMillimeter: 6.1, nativeScale: 3)
        let font = UIFont.systemFont(ofSize: 100)

        for distance in stride(from: 100.0, through: 300.0, by: 1.0) {
            var previousHeight = Double.greatestFiniteMagnitude
            for acuity in acuityLevels {
                let spec = try OptotypeSizing.renderSpec(
                    distanceCM: distance,
                    snellenDenominator: acuity,
                    calibration: calibration,
                    font: font
                )
                XCTAssertLessThan(spec.targetHeightMillimeters, previousHeight)
                XCTAssertTrue(spec.fontPointSize.isFinite)
                let expectedArcMinutes = 5.0 * Double(acuity) / 20.0
                let expectedRadians = expectedArcMinutes / 60.0 * .pi / 180.0
                let expectedMillimeters = 2.0 * distance * 10.0 * tan(expectedRadians / 2.0)
                XCTAssertEqual(spec.targetAngleArcMinutes, expectedArcMinutes, accuracy: 0.000_001)
                XCTAssertEqual(spec.targetAngleRadians, expectedRadians, accuracy: 0.000_000_001)
                XCTAssertEqual(spec.targetHeightMillimeters, expectedMillimeters, accuracy: 0.000_001)
                XCTAssertEqual(
                    Double(spec.renderedHeightPoints) / calibration.pointsPerMillimeter,
                    spec.targetHeightMillimeters,
                    accuracy: 0.000_001
                )
                previousHeight = spec.targetHeightMillimeters
            }
        }
    }

    func testTwoHundredCentimeterAnchors() throws {
        // Myotect's protocol distance. Exact-chord vs the single-tangent ETDRS table differs
        // only ~1e-7 mm here, far inside the 0.001 tolerance.
        let calibration = makeCalibration(pointsPerMillimeter: 6, nativeScale: 3)
        let font = UIFont.systemFont(ofSize: 100)

        let twentyTwenty = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 20,
            calibration: calibration,
            font: font
        )
        XCTAssertEqual(twentyTwenty.targetAngleArcMinutes, 5, accuracy: 0.000_001)
        XCTAssertEqual(twentyTwenty.targetHeightMillimeters, 2.909, accuracy: 0.001)

        let twentyForty = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 40,
            calibration: calibration,
            font: font
        )
        XCTAssertEqual(twentyForty.targetAngleArcMinutes, 10, accuracy: 0.000_001)
        XCTAssertEqual(twentyForty.targetHeightMillimeters, 5.818, accuracy: 0.001)
    }

    func testPhysicalHeightIsIndependentOfDisplayScale() throws {
        // Locks the D1 fix: (401, 2.6087) is the downsampled Plus-class case where the logical
        // scale (3.0) undersizes optotypes ~13%.
        let displays = [
            (ppi: 326.0, scale: 2.0),
            (ppi: 460.0, scale: 3.0),
            (ppi: 401.0, scale: 2.6087)
        ]
        let font = UIFont.systemFont(ofSize: 100)
        for distance in stride(from: 100.0, through: 300.0, by: 20.0) {
            for acuity in acuityLevels {
                var physicalHeights: [Double] = []
                for display in displays {
                    let calibration = try XCTUnwrap(ScreenCalibrationProvider.automaticCalibration(
                        ppi: display.ppi,
                        nativeScale: display.scale,
                        screenSignature: "mock-\(display.scale)"
                    ))
                    let spec = try OptotypeSizing.renderSpec(
                        distanceCM: distance,
                        snellenDenominator: acuity,
                        calibration: calibration,
                        font: font
                    )
                    physicalHeights.append(
                        Double(spec.renderedHeightPoints) / calibration.pointsPerMillimeter
                    )
                }
                for height in physicalHeights {
                    XCTAssertEqual(height, physicalHeights[0], accuracy: 0.000_001)
                }
            }
        }
    }

    func testSloanFontPointSizeProducesRequestedCapHeight() throws {
        // App-hosted test bundle: MyotectApp registers Sloan.otf, so real metrics are available.
        let sloan = try OptotypeSizing.sloanBaseFont()
        let calibration = makeCalibration(pointsPerMillimeter: 6.05, nativeScale: 3)
        let spec = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 200,
            calibration: calibration,
            font: sloan
        )
        let resized = sloan.withSize(spec.fontPointSize)

        XCTAssertEqual(resized.capHeight, spec.renderedHeightPoints, accuracy: 0.5)
    }

    // MARK: - Rejection

    func testInvalidInputsThrowSpecificErrors() {
        let valid = makeCalibration(pointsPerMillimeter: 6, nativeScale: 3)
        let font = UIFont.systemFont(ofSize: 100)

        assertThrows(.invalidDistance, distanceCM: 0, calibration: valid, font: font)
        assertThrows(.invalidDistance, distanceCM: -200, calibration: valid, font: font)
        assertThrows(.invalidDistance, distanceCM: .infinity, calibration: valid, font: font)
        assertThrows(.invalidDistance, distanceCM: .nan, calibration: valid, font: font)

        assertThrows(.invalidAcuity, snellenDenominator: 0, calibration: valid, font: font)
        assertThrows(.invalidAcuity, snellenDenominator: -20, calibration: valid, font: font)

        let zeroPPM = ScreenCalibration(
            pointsPerMillimeter: 0,
            nativeScale: 3,
            source: .manual,
            screenSignature: "test-screen",
            schemaVersion: ScreenCalibration.schemaVersion
        )
        let negativePPM = ScreenCalibration(
            pointsPerMillimeter: -6,
            nativeScale: 3,
            source: .manual,
            screenSignature: "test-screen",
            schemaVersion: ScreenCalibration.schemaVersion
        )
        let staleSchema = ScreenCalibration(
            pointsPerMillimeter: 6,
            nativeScale: 3,
            source: .manual,
            screenSignature: "test-screen",
            schemaVersion: ScreenCalibration.schemaVersion + 1
        )
        let legacyUnknown = ScreenCalibration(
            pointsPerMillimeter: 6,
            nativeScale: 3,
            source: .legacyUnknown,
            screenSignature: "test-screen",
            schemaVersion: ScreenCalibration.schemaVersion
        )
        XCTAssertFalse(legacyUnknown.isValidated)
        assertThrows(.invalidCalibration, calibration: zeroPPM, font: font)
        assertThrows(.invalidCalibration, calibration: negativePPM, font: font)
        assertThrows(.invalidCalibration, calibration: staleSchema, font: font)
        assertThrows(.invalidCalibration, calibration: legacyUnknown, font: font)

        assertThrows(.invalidFontMetrics, calibration: valid, font: UIFont.systemFont(ofSize: 0))
    }

    // MARK: - needsRender damping

    func testNeedsRenderUsesHalfPhysicalPixelThreshold() throws {
        // nativeScale 2 makes the threshold exactly 0.25 pt, so the boundary case is exact
        // in floating point.
        let calibration = makeCalibration(pointsPerMillimeter: 6, nativeScale: 2)
        let previous = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 200,
            calibration: calibration,
            font: UIFont.systemFont(ofSize: 100)
        )
        let threshold = calibration.halfPhysicalPixelInPoints
        XCTAssertEqual(threshold, 0.25)

        XCTAssertFalse(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: spec(previous, offsetPoints: 0.99 * threshold)
        ))
        XCTAssertFalse(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: previous
        ))
        XCTAssertTrue(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: spec(previous, offsetPoints: threshold)
        ), "A delta of exactly half a physical pixel must re-render")
        XCTAssertTrue(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: spec(previous, offsetPoints: 2 * threshold)
        ))
        XCTAssertTrue(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: spec(previous, offsetPoints: -2 * threshold)
        ), "Shrinking past the threshold must also re-render")
    }

    func testNeedsRenderInvalidatesOnCalibrationIdentityChange() throws {
        let calibration = makeCalibration(pointsPerMillimeter: 6, nativeScale: 2)
        let previous = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 200,
            calibration: calibration,
            font: UIFont.systemFont(ofSize: 100)
        )

        let changedScreen = ScreenCalibration(
            pointsPerMillimeter: calibration.pointsPerMillimeter,
            nativeScale: calibration.nativeScale,
            source: calibration.source,
            screenSignature: "different-screen",
            schemaVersion: calibration.schemaVersion
        )
        XCTAssertTrue(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: spec(previous, calibration: changedScreen)
        ), "A changed screen signature must force a render even with identical heights")

        let changedSource = ScreenCalibration(
            pointsPerMillimeter: calibration.pointsPerMillimeter,
            nativeScale: calibration.nativeScale,
            source: .deviceDatabase,
            screenSignature: calibration.screenSignature,
            schemaVersion: calibration.schemaVersion
        )
        XCTAssertTrue(OptotypeSizing.needsRender(
            previousSpec: previous,
            candidateSpec: spec(previous, calibration: changedSource)
        ))
    }

    func testNeedsRenderForcedOrWithoutPreviousSpec() throws {
        let calibration = makeCalibration(pointsPerMillimeter: 6, nativeScale: 2)
        let spec = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 200,
            calibration: calibration,
            font: UIFont.systemFont(ofSize: 100)
        )

        XCTAssertTrue(OptotypeSizing.needsRender(previousSpec: nil, candidateSpec: spec))
        XCTAssertTrue(OptotypeSizing.needsRender(
            previousSpec: spec,
            candidateSpec: spec,
            force: true
        ))
    }

    // MARK: - fitsSquare

    func testFitsSquareBoundary() throws {
        let calibration = makeCalibration(pointsPerMillimeter: 6, nativeScale: 3)
        let base = try OptotypeSizing.renderSpec(
            distanceCM: 200,
            snellenDenominator: 200,
            calibration: calibration,
            font: UIFont.systemFont(ofSize: 100)
        )
        // 100 pt glyph + 2 × 12 pt margin needs exactly 124 pt of square.
        let squareSpec = spec(base, renderedHeightPoints: 100)

        XCTAssertTrue(squareSpec.fitsSquare(side: 124, innerMargin: 12))
        XCTAssertTrue(squareSpec.fitsSquare(side: 340, innerMargin: 12))
        XCTAssertFalse(squareSpec.fitsSquare(side: 123.999, innerMargin: 12))
        XCTAssertFalse(squareSpec.fitsSquare(side: 100, innerMargin: 12))
        XCTAssertTrue(squareSpec.fitsSquare(side: 100, innerMargin: 0))
    }

    // MARK: - Helpers

    private func makeCalibration(
        pointsPerMillimeter: Double,
        nativeScale: Double
    ) -> ScreenCalibration {
        ScreenCalibration(
            pointsPerMillimeter: pointsPerMillimeter,
            nativeScale: nativeScale,
            source: .manual,
            screenSignature: "test-screen",
            schemaVersion: ScreenCalibration.schemaVersion
        )
    }

    /// Copy of `base` with a controlled rendered height and/or calibration, so threshold cases
    /// are exact instead of derived through distance.
    private func spec(
        _ base: OptotypeRenderSpec,
        offsetPoints: CGFloat = 0,
        renderedHeightPoints: CGFloat? = nil,
        calibration: ScreenCalibration? = nil
    ) -> OptotypeRenderSpec {
        OptotypeRenderSpec(
            targetAngleArcMinutes: base.targetAngleArcMinutes,
            targetAngleRadians: base.targetAngleRadians,
            targetHeightMillimeters: base.targetHeightMillimeters,
            renderedHeightPoints: renderedHeightPoints ?? (base.renderedHeightPoints + offsetPoints),
            fontPointSize: base.fontPointSize,
            calibration: calibration ?? base.calibration
        )
    }

    private func assertThrows(
        _ expected: OptotypeSizingError,
        distanceCM: Double = 200,
        snellenDenominator: Int = 20,
        calibration: ScreenCalibration,
        font: UIFont,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try OptotypeSizing.renderSpec(
                distanceCM: distanceCM,
                snellenDenominator: snellenDenominator,
                calibration: calibration,
                font: font
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? OptotypeSizingError, expected, file: file, line: line)
        }
    }
}
