import UIKit
import XCTest
@testable import Myotect

/// The idle timer is process-global state, so every test here restores what it found.
@MainActor
final class IdleTimerControllerTests: XCTestCase {

    private var originalValue = false

    override func setUp() {
        super.setUp()
        originalValue = UIApplication.shared.isIdleTimerDisabled
    }

    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = originalValue
        super.tearDown()
    }

    func testDisableSleepDisablesTheIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = false
        let controller = IdleTimerController()
        controller.disableSleep()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }

    func testRestorePutsBackTheValueCapturedByTheFirstDisable() {
        UIApplication.shared.isIdleTimerDisabled = false
        let controller = IdleTimerController()
        controller.disableSleep()
        controller.restore()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    /// Re-asserted on every return to the foreground, so repeated calls must not overwrite the
    /// remembered original with the value we ourselves just wrote.
    func testRepeatedDisableSleepKeepsTheOriginalValue() {
        UIApplication.shared.isIdleTimerDisabled = false
        let controller = IdleTimerController()
        controller.disableSleep()
        controller.disableSleep()
        controller.disableSleep()
        controller.restore()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    func testRestoreIsSafeBeforeAnyDisableAndIsIdempotent() {
        UIApplication.shared.isIdleTimerDisabled = true
        let controller = IdleTimerController()
        controller.restore()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled,
                      "restore() with nothing captured must not touch the setting")

        controller.disableSleep()
        controller.restore()
        controller.restore()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }

    /// A controller that finds the timer already disabled must leave it that way on restore.
    func testRestoreKeepsAnAlreadyDisabledTimerDisabled() {
        UIApplication.shared.isIdleTimerDisabled = true
        let controller = IdleTimerController()
        controller.disableSleep()
        controller.restore()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }
}
