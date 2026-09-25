import XCTest
@testable import Myotect

/// The pure outcome rules behind `WhisperKitLetterRecognitionService`'s deadline flush. They exist
/// because a `no input registered` row is visible in every export and its backstop is the only
/// exit from a same-level loop, so the service may only say "silence" when nothing usable was said
/// in the whole window. The buffer arithmetic lives in `ListeningBufferRulesTests`.
final class RecognitionFlushRulesTests: XCTestCase {

    // MARK: - resolveFinalOutcome

    func testSilentTailAfterEngagedPassReportsTheEngagedPass() {
        // "um" / "banana" / "C D" at 2 s and quiet after: the child engaged, so the trial
        // retries with the re-prompt instead of being logged as absent.
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.silence), engagedDuringTrial: .unrecognized(.filler)),
            .unrecognized(.filler))
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.silence), engagedDuringTrial: .unrecognized(.unintelligible)),
            .unrecognized(.unintelligible))
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.silence), engagedDuringTrial: .ambiguous),
            .ambiguous)
    }

    func testSilentTailWithNoEngagementIsSilence() {
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.silence), engagedDuringTrial: nil),
            .unrecognized(.silence))
    }

    func testAnsweredOrInspectedTailAlwaysWins() {
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .letter("C"), engagedDuringTrial: .unrecognized(.filler)), .letter("C"))
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .skipped, engagedDuringTrial: .ambiguous), .skipped)
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.unintelligible), engagedDuringTrial: .unrecognized(.filler)),
            .unrecognized(.unintelligible))
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .serviceFailure(.microphonePermissionDenied), engagedDuringTrial: .ambiguous),
            .serviceFailure(.microphonePermissionDenied))
    }

    // MARK: - strongerEngagement

    func testEngagementRanksAmbiguousOverUnintelligibleOverFiller() {
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(nil, .unrecognized(.filler)),
                       .unrecognized(.filler))
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(
            .unrecognized(.filler), .unrecognized(.unintelligible)), .unrecognized(.unintelligible))
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(
            .unrecognized(.unintelligible), .ambiguous), .ambiguous)
        // Never downgrades.
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(.ambiguous, .unrecognized(.filler)),
                       .ambiguous)
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(
            .unrecognized(.unintelligible), .unrecognized(.filler)), .unrecognized(.unintelligible))
    }

    func testNonEngagementNeverCountsAsEngagement() {
        XCTAssertNil(RecognitionFlushRules.strongerEngagement(nil, .unrecognized(.silence)))
        XCTAssertNil(RecognitionFlushRules.strongerEngagement(nil, .letter("C")))
        XCTAssertNil(RecognitionFlushRules.strongerEngagement(nil, .skipped))
        XCTAssertNil(RecognitionFlushRules.strongerEngagement(
            nil, .serviceFailure(.microphonePermissionDenied)))
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(
            .unrecognized(.filler), .unrecognized(.silence)), .unrecognized(.filler))
    }

    // MARK: - upgradedForTrace (the voice trace decides silence)

    /* At 2 m Whisper-base often renders a faint child's letter as "Thank you." or "you", which the
       transcript filter rightly calls a silence hallucination. When the voice trace shows a
       speech-length sound, the child DID say something: that pass is unintelligible (retry with
       re-prompt), never silence — the failure mode behind "no input registered" for a child who
       spoke. With no speech-length sound the hallucination stays what it is.
     */
    func testSilenceWithSpeechLengthSoundUpgradesToUnintelligible() {
        XCTAssertEqual(RecognitionFlushRules.upgradedForTrace(.unrecognized(.silence), hadSpeechLengthSound: true),
                       .unrecognized(.unintelligible))
        XCTAssertEqual(RecognitionFlushRules.upgradedForTrace(.unrecognized(.silence), hadSpeechLengthSound: false),
                       .unrecognized(.silence))
        for untouched: RecognitionOutcome in [.letter("C"), .skipped, .ambiguous, .unrecognized(.filler),
                                              .unrecognized(.unintelligible),
                                              .serviceFailure(.microphonePermissionDenied)] {
            XCTAssertEqual(RecognitionFlushRules.upgradedForTrace(untouched, hadSpeechLengthSound: true), untouched)
            XCTAssertEqual(RecognitionFlushRules.upgradedForTrace(untouched, hadSpeechLengthSound: false), untouched)
        }
    }

    /* The upgrade feeds the engagement bookkeeping: a hallucination over a real sound is
       remembered so a quiet tail afterwards retries, while a hallucination over nothing (a click)
       is not engagement and the window can still end as silence.
     */
    func testHallucinationCountsAsEngagementOnlyWithSound() {
        let withSound = RecognitionFlushRules.upgradedForTrace(.unrecognized(.silence), hadSpeechLengthSound: true)
        XCTAssertEqual(RecognitionFlushRules.strongerEngagement(nil, withSound), .unrecognized(.unintelligible))
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.silence),
            engagedDuringTrial: RecognitionFlushRules.strongerEngagement(nil, withSound)),
            .unrecognized(.unintelligible))

        let withoutSound = RecognitionFlushRules.upgradedForTrace(.unrecognized(.silence), hadSpeechLengthSound: false)
        XCTAssertNil(RecognitionFlushRules.strongerEngagement(nil, withoutSound))
        XCTAssertEqual(RecognitionFlushRules.resolveFinalOutcome(
            tail: .unrecognized(.silence), engagedDuringTrial: nil), .unrecognized(.silence))
    }
}
