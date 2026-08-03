import UIKit
import XCTest
@testable import Myotect

final class ScreenCalibrationProviderTests: XCTestCase {
    private let storageKey = "ManualScreenCalibration"
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!
    /// Mutated by tests to simulate the app moving to different display hardware.
    private var descriptor = ScreenCalibrationProviderTests.defaultDescriptor

    private static let defaultDescriptor = ScreenDescriptor(
        machineIdentifier: "iPhone-test",
        nativeBounds: CGRect(x: 0, y: 0, width: 1179, height: 2556),
        nativeScale: 3
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ScreenCalibrationProviderTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        notificationCenter = NotificationCenter()
        descriptor = Self.defaultDescriptor
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        notificationCenter = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Automatic (device database) path

    func testVerifiedDeviceProducesAutomaticCalibration() throws {
        let provider = makeProvider(ppiResolution: .verified(460))

        let calibration = try XCTUnwrap(provider.currentCalibration)
        XCTAssertEqual(calibration.pointsPerMillimeter, 460 / 3 / 25.4, accuracy: 0.000_001)
        XCTAssertEqual(calibration.source, .deviceDatabase)
        XCTAssertEqual(calibration.screenSignature, descriptor.signature)
        XCTAssertTrue(calibration.isValidated)
        XCTAssertEqual(calibration.halfPhysicalPixelInPoints, 1.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(provider.status, .validated(calibration))
    }

    func testScreenSignatureFormat() {
        let provider = makeProvider(ppiResolution: .verified(460))
        XCTAssertEqual(provider.screenSignature, "iPhone-test|1179x2556|3.0000")
    }

    // MARK: - Unknown device / manual path

    func testUnknownDeviceRequiresManualCalibration() {
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))

        XCTAssertNil(provider.currentCalibration)
        guard case .manualCalibrationRequired(let signature) = provider.status else {
            return XCTFail("An unknown device must require manual calibration")
        }
        XCTAssertEqual(signature, descriptor.signature)
    }

    func testSuggestedPointsPerMillimeterFallsBackToSuggestedPPI() {
        descriptor = ScreenDescriptor(
            machineIdentifier: "iPhone-test",
            nativeBounds: CGRect(x: 0, y: 0, width: 640, height: 1136),
            nativeScale: 2
        )
        let unknown = makeProvider(ppiResolution: .unknown(suggestedPPI: 326))
        XCTAssertEqual(unknown.suggestedPointsPerMillimeter, 326 / 2 / 25.4, accuracy: 0.000_001)

        descriptor = Self.defaultDescriptor
        let verified = makeProvider(ppiResolution: .verified(460))
        XCTAssertEqual(verified.suggestedPointsPerMillimeter, 460 / 3 / 25.4, accuracy: 0.000_001)
    }

    func testSaveManualCalibrationValidatesAndPostsNotification() throws {
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))
        var notifications: [Notification] = []
        let token = notificationCenter.addObserver(
            forName: .screenCalibrationDidChange,
            object: nil,
            queue: nil
        ) { notifications.append($0) }
        defer { notificationCenter.removeObserver(token) }

        let saved = try XCTUnwrap(provider.saveManualCalibration(pointsPerMillimeter: 6.05))

        XCTAssertEqual(saved.pointsPerMillimeter, 6.05)
        XCTAssertEqual(saved.source, .manual)
        XCTAssertEqual(saved.screenSignature, descriptor.signature)
        XCTAssertTrue(saved.isValidated)
        XCTAssertEqual(provider.currentCalibration, saved)
        XCTAssertEqual(provider.status, .validated(saved))
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.object as? ScreenCalibration, saved)
    }

    func testSaveManualCalibrationRejectsNonPositiveValues() {
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))
        XCTAssertNil(provider.saveManualCalibration(pointsPerMillimeter: 0))
        XCTAssertNil(provider.saveManualCalibration(pointsPerMillimeter: -6))
        XCTAssertNil(provider.saveManualCalibration(pointsPerMillimeter: .nan))
        XCTAssertNil(defaults.data(forKey: storageKey))
    }

    // MARK: - Delete-on-mismatch permanence

    func testChangedSignatureDeletesManualCalibrationPermanently() throws {
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))
        _ = try XCTUnwrap(provider.saveManualCalibration(pointsPerMillimeter: 6.05))
        XCTAssertNotNil(provider.currentCalibration)

        descriptor = ScreenDescriptor(
            machineIdentifier: "iPhone-test",
            nativeBounds: CGRect(x: 0, y: 0, width: 1284, height: 2778),
            nativeScale: 3
        )
        XCTAssertNil(provider.currentCalibration)
        XCTAssertNil(defaults.data(forKey: storageKey), "The mismatched record must be deleted")

        descriptor = Self.defaultDescriptor
        XCTAssertNil(
            provider.currentCalibration,
            "An invalidated calibration must not resurface on the original screen"
        )
    }

    func testStaleSchemaVersionDeletesManualCalibrationPermanently() throws {
        // A record written under a future/different schema must never be trusted or kept.
        let record: [String: Any] = [
            "pointsPerMillimeter": 6.05,
            "nativeScale": 3.0,
            "screenSignature": descriptor.signature,
            "schemaVersion": ScreenCalibration.schemaVersion + 1
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: storageKey)
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))

        XCTAssertNil(provider.currentCalibration)
        XCTAssertNil(defaults.data(forKey: storageKey), "The stale-schema record must be deleted")
        XCTAssertNil(provider.currentCalibration)
    }

    func testUndecodableRecordIsDeleted() {
        defaults.set(Data("not json".utf8), forKey: storageKey)
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))

        XCTAssertNil(provider.currentCalibration)
        XCTAssertNil(defaults.data(forKey: storageKey))
    }

    func testClearManualCalibrationPostsNotificationAndRequiresRecalibration() throws {
        let provider = makeProvider(ppiResolution: .unknown(suggestedPPI: 460))
        _ = try XCTUnwrap(provider.saveManualCalibration(pointsPerMillimeter: 6.05))
        var notifications: [Notification] = []
        let token = notificationCenter.addObserver(
            forName: .screenCalibrationDidChange,
            object: nil,
            queue: nil
        ) { notifications.append($0) }
        defer { notificationCenter.removeObserver(token) }

        provider.clearManualCalibration()

        XCTAssertEqual(notifications.count, 1)
        XCTAssertNil(notifications.first?.object)
        XCTAssertNil(provider.currentCalibration)
        XCTAssertNil(defaults.data(forKey: storageKey))
        guard case .manualCalibrationRequired = provider.status else {
            return XCTFail("Clearing must return the provider to the manual-calibration state")
        }
    }

    // MARK: - Static validation

    func testManualCalibrationRejectsMismatches() {
        XCTAssertNotNil(ScreenCalibrationProvider.manualCalibration(
            pointsPerMillimeter: 6.1,
            nativeScale: 3,
            storedScreenSignature: "screen-a",
            storedSchemaVersion: ScreenCalibration.schemaVersion,
            currentScreenSignature: "screen-a",
            currentNativeScale: 3
        ))
        XCTAssertNil(ScreenCalibrationProvider.manualCalibration(
            pointsPerMillimeter: 6.1,
            nativeScale: 3,
            storedScreenSignature: "screen-a",
            storedSchemaVersion: ScreenCalibration.schemaVersion,
            currentScreenSignature: "screen-b",
            currentNativeScale: 3
        ))
        XCTAssertNil(ScreenCalibrationProvider.manualCalibration(
            pointsPerMillimeter: 6.1,
            nativeScale: 3,
            storedScreenSignature: "screen-a",
            storedSchemaVersion: ScreenCalibration.schemaVersion + 1,
            currentScreenSignature: "screen-a",
            currentNativeScale: 3
        ))
        XCTAssertNil(ScreenCalibrationProvider.manualCalibration(
            pointsPerMillimeter: 6.1,
            nativeScale: 3,
            storedScreenSignature: "screen-a",
            storedSchemaVersion: ScreenCalibration.schemaVersion,
            currentScreenSignature: "screen-a",
            currentNativeScale: 2
        ))
    }

    // MARK: - Static test double

    func testStaticProviderStates() throws {
        let calibration = try XCTUnwrap(ScreenCalibrationProvider.automaticCalibration(
            ppi: 460,
            nativeScale: 3,
            screenSignature: "static-screen"
        ))
        let validated = StaticScreenCalibrationProvider(calibration: calibration)
        XCTAssertEqual(validated.currentCalibration, calibration)
        XCTAssertEqual(validated.status, .validated(calibration))
        XCTAssertEqual(validated.screenSignature, "static-screen")

        let uncalibrated = StaticScreenCalibrationProvider(uncalibratedSignature: "blank-screen")
        XCTAssertNil(uncalibrated.currentCalibration)
        XCTAssertEqual(
            uncalibrated.status,
            .manualCalibrationRequired(screenSignature: "blank-screen")
        )

        let saved = try XCTUnwrap(uncalibrated.saveManualCalibration(pointsPerMillimeter: 6.05))
        XCTAssertEqual(uncalibrated.status, .validated(saved))
        uncalibrated.clearManualCalibration()
        XCTAssertNil(uncalibrated.currentCalibration)
    }

    // MARK: - Helpers

    private func makeProvider(ppiResolution: DevicePpiResolution) -> ScreenCalibrationProvider {
        ScreenCalibrationProvider(
            defaults: defaults,
            notificationCenter: notificationCenter,
            ppiResolution: { ppiResolution },
            screenDescriptor: { [unowned self] in descriptor }
        )
    }
}
