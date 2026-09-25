import XCTest
@testable import Myotect

/// Unit coverage for the pure derivations on ``ScreenConfig`` — the ladder arithmetic that decides
/// where the low-contrast staircases begin, and the staircase-config factory that carries it.
final class ScreenConfigTests: XCTestCase {

    // MARK: - acuityLevel(coarserBy:than:)

    func testTwoStepsCoarserWalksTheLadderTowardLargerLetters() {
        let config = ScreenConfig()
        // acuityLevels: 200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16 (easiest → hardest)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 16), 25)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 20), 32)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 25), 40)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 32), 50)
    }

    func testZeroStepsIsIdentity() {
        XCTAssertEqual(ScreenConfig().acuityLevel(coarserBy: 0, than: 25), 25)
    }

    func testClampsAtTheCoarsestLevel() {
        let config = ScreenConfig()
        // Two steps coarser than the second-coarsest rung would fall off the ladder.
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 160), 200)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 200), 200)
        XCTAssertEqual(config.acuityLevel(coarserBy: 99, than: 20), 200)
    }

    /// Below-gate anchors are real now that the 20/25 result never gates the flow: a child who
    /// passed only 20/50 (or nothing, where the anchor is the 20/200 terminal line) still gets
    /// an on-ladder low-contrast start.
    func testBelowGateAnchorsStillWalkTheLadderAndClamp() {
        let config = ScreenConfig()
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 50), 80)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 80), 125)
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 200), 200)
    }

    /// An off-ladder input must never be returned verbatim: `AcuityStaircaseEngine.init` silently
    /// drops an unknown `startAcuity` to the coarsest rung, which would open a low-contrast run at
    /// 20/200 for a child who reads 20/20.
    func testUnknownLevelFallsBackToProtocolStart() {
        var config = ScreenConfig()
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 22), config.startAcuity)
        config.startAcuity = 63
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 22), 63)
    }

    func testHonorsACustomLadder() {
        var config = ScreenConfig()
        //                      idx: 0    1   2   3   4
        config.acuityLevels = [200, 100, 50, 25, 20]
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 20), 50)   // idx 4 → 2
        XCTAssertEqual(config.acuityLevel(coarserBy: 1, than: 25), 50)   // idx 3 → 2
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 25), 100)  // idx 3 → 1
        // A rung the DEFAULT ladder has but this one does not is off-ladder here.
        XCTAssertEqual(config.acuityLevel(coarserBy: 2, than: 32), config.startAcuity)
    }

    // MARK: - staircaseConfig

    func testStaircaseConfigDefaultsToTheProtocolStartAndGatesOnlyWhenAsked() {
        let config = ScreenConfig()
        let gated = config.staircaseConfig(gated: true)
        XCTAssertEqual(gated.startAcuity, config.startAcuity)
        XCTAssertEqual(gated.gateAcuity, config.gateAcuity)

        let ungated = config.staircaseConfig(gated: false)
        XCTAssertEqual(ungated.startAcuity, config.startAcuity)
        XCTAssertNil(ungated.gateAcuity)
    }

    func testStaircaseConfigCarriesAStartOverride() {
        let config = ScreenConfig()
        let seeded = config.staircaseConfig(gated: false, startAcuity: 32)
        XCTAssertEqual(seeded.startAcuity, 32)
        XCTAssertNil(seeded.gateAcuity)
        // The override is on the ladder, so the engine actually opens there.
        XCTAssertEqual(AcuityStaircaseEngine(config: seeded).currentAcuity, 32)
    }

    func testDefaultLowContrastOffsetIsTwoSteps() {
        XCTAssertEqual(ScreenConfig().lowContrastStartOffsetSteps, 2)
    }

    func testDefaultInterstimulusBlankIsQuarterSecond() {
        XCTAssertEqual(ScreenConfig().interstimulusBlankSeconds, 0.25, accuracy: 1e-9)
    }

    // MARK: - Speech window and no-input backstop

    /// The no-input window is 10 s and SOFT (the service defers it while sound is being
    /// collected); a regression to the old 5 s / 8 s must fail here, not on device.
    func testDefaultNoInputWindowIsTenSeconds() {
        XCTAssertEqual(ScreenConfig().recognitionTimeoutSeconds, 10, accuracy: 1e-9)
    }

    func testDefaultSoftDeadlineStepAndCap() {
        XCTAssertEqual(ScreenConfig().deadlineDeferralStepSeconds, 0.25, accuracy: 1e-9)
        XCTAssertEqual(ScreenConfig().deadlineDeferralCapSeconds, 3.0, accuracy: 1e-9)
    }

    /// The utterance-end quiet tail is also the tail a non-answer pass retains, so both derive
    /// from ONE key; the cap and the voice threshold are WhisperKit's / the gold app's values.
    func testUtteranceRulesDefaults() {
        let config = ScreenConfig()
        XCTAssertEqual(config.utteranceEndQuietSeconds, 0.3, accuracy: 1e-9)
        XCTAssertEqual(config.maximumUtteranceSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(config.voiceSilenceThreshold, 0.10, accuracy: 1e-6)
        XCTAssertEqual(config.captureBufferTrimAfterSeconds, 120, accuracy: 1e-9)
    }

    /// The trimmed capture buffer must always keep the 2 s silence reference the voice trace is
    /// computed against, or the first blocks of every session would read as voice.
    func testPurgeKeepCoversTheSilenceReference() {
        XCTAssertGreaterThanOrEqual(
            ScreenConfig().capturePurgeKeepSeconds,
            Double(ListeningBufferRules.referenceWindowBlocks) * 0.1)
    }

    func testDefaultListenResumeAfterSpeechIsHalfSecond() {
        XCTAssertEqual(ScreenConfig().listenResumeAfterSpeechSeconds, 0.5, accuracy: 1e-9)
    }

    func testDefaultNoInputBackstopIsThreeTrials() {
        XCTAssertEqual(ScreenConfig().noInputTrialsBeforeEscalation, 3)
    }

    // MARK: - init(settings:)

    func testInitFromSettingsCopiesContrastAndAudio() {
        // 0.05 / audio-off are never defaults, so this discriminates a dropped or swapped copy.
        let config = ScreenConfig(settings: ScreeningSettings(weberChoice: .five, audioEnabled: false))
        XCTAssertEqual(config.lowContrastWeber, 0.05, accuracy: 1e-9)
        XCTAssertFalse(config.ttsEnabled)
        // Everything else stays at the protocol defaults.
        XCTAssertEqual(config.recognitionTimeoutSeconds, ScreenConfig().recognitionTimeoutSeconds)
        XCTAssertEqual(config.startAcuity, ScreenConfig().startAcuity)

        let fromDefaults = ScreenConfig(settings: ScreeningSettings())
        XCTAssertEqual(fromDefaults.lowContrastWeber, 0.20, accuracy: 1e-9)
        XCTAssertTrue(fromDefaults.ttsEnabled)
    }
}
