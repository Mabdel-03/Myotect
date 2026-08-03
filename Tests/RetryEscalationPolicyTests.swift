import XCTest
@testable import Myotect

final class RetryEscalationPolicyTests: XCTestCase {

    private func makePolicy(maxRetries: Int = 2, stickyAfter: Int = 2) -> RetryEscalationPolicy {
        RetryEscalationPolicy(config: .init(maxAutoRetriesPerTrial: maxRetries,
                                            stickyManualAfterConsecutiveEscalations: stickyAfter))
    }

    func testRetrySequenceThenEscalation() {
        var policy = makePolicy()
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .retry(withPrompt: true))
        XCTAssertEqual(policy.actionForFailedAttempt(), .retry(withPrompt: false))
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual)
    }

    func testBeginTrialResetsAttemptCount() {
        var policy = makePolicy()
        policy.beginTrial()
        _ = policy.actionForFailedAttempt()
        _ = policy.actionForFailedAttempt()
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .retry(withPrompt: true))
    }

    func testDistancePauseRepeatsDoNotGrantExtraRetries() {
        var policy = makePolicy()
        policy.beginTrial()
        _ = policy.actionForFailedAttempt()
        _ = policy.actionForFailedAttempt()
        // A distance pause re-presents the same letter WITHOUT beginTrial: the next failed
        // attempt still escalates.
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual)
    }

    func testServiceFailureEscalatesImmediately() {
        var policy = makePolicy()
        policy.beginTrial()
        XCTAssertEqual(policy.actionForServiceFailure(), .escalateToManual)
        XCTAssertEqual(policy.consecutiveEscalatedTrials, 1)
    }

    func testStickyManualAfterConsecutiveEscalationsAndVoiceResolveClearsStreak() {
        var policy = makePolicy(maxRetries: 0, stickyAfter: 2)
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual)
        XCTAssertFalse(policy.isStickyManual)
        // A voice-resolved trial in between clears the streak.
        policy.trialResolved(byVoice: true)
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual)
        XCTAssertFalse(policy.isStickyManual)
        // Two escalations with only keypad resolutions between them stick.
        policy.trialResolved(byVoice: false)
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual)
        XCTAssertTrue(policy.isStickyManual)
    }

    func testStickyManualBypassesRetries() {
        var policy = makePolicy(maxRetries: 0, stickyAfter: 1)
        policy.beginTrial()
        _ = policy.actionForFailedAttempt()
        XCTAssertTrue(policy.isStickyManual)
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual)
    }

    func testClinicianRestoreClearsStickyAndStreak() {
        var policy = makePolicy(maxRetries: 0, stickyAfter: 1)
        policy.beginTrial()
        _ = policy.actionForFailedAttempt()
        XCTAssertTrue(policy.isStickyManual)
        policy.clinicianRestoredVoice()
        XCTAssertFalse(policy.isStickyManual)
        XCTAssertEqual(policy.consecutiveEscalatedTrials, 0)
        policy.beginTrial()
        XCTAssertEqual(policy.actionForFailedAttempt(), .escalateToManual) // maxRetries 0 still applies
    }
}
