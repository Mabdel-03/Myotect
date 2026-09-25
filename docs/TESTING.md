# Testing Myotect — complete guide

This document covers everything needed to verify Myotect: the automated unit suite (how to run it,
what every one of its 324 tests asserts), the manual on-device protocol for the parts a simulator
cannot exercise, physical verification of optotype size, and troubleshooting for the failure modes
this project actually hits.

**Current status: 324 tests, 0 failures** on iPhone 17 / iOS 26.5.

**Contents**

- [Part 0 — Prerequisites](#part-0--prerequisites)
- [Part 1 — Running the automated suite](#part-1--running-the-automated-suite)
- [Part 2 — The unit suite, test by test](#part-2--the-unit-suite-test-by-test)
- [Part 3 — On-device validation](#part-3--on-device-validation)
- [Part 4 — Verifying physical optotype size](#part-4--verifying-physical-optotype-size)
- [Part 5 — Writing new tests](#part-5--writing-new-tests)
- [Part 6 — Troubleshooting](#part-6--troubleshooting)

---

## Part 0 — Prerequisites

| Requirement | Notes |
| --- | --- |
| Xcode 16+ | Developed against Xcode 26.6 (build 17F113) |
| XcodeGen | `brew install xcodegen` — `project.yml` is the source of truth |
| An iOS simulator runtime | Any runtime ≥ iOS 17.0. See [the runtime pitfall](#pitfall-2--missing-simulator-runtime-breaks-destination-resolution) |
| Network (first build only) | SPM resolves `DevicePpi` and `argmax-oss-swift` |
| A TrueDepth device | Only for [Part 3](#part-3--on-device-validation); not needed for the unit suite |

Nothing else. The unit suite has no fixtures other than the service source pin
(`WhisperServiceSourcePinsTests` reads `WhisperKitLetterRecognitionService.swift` as text via
`#filePath`), no network access, and no simulator UI automation — it is pure XCTest against
injected mocks and completes in a **few seconds**.

### The one rule that will bite you

> **Run `xcodegen generate` after every add, delete, or rename of a file under `Sources/` or
> `Tests/`.**

`project.yml` globs sources; the generated `.xcodeproj` records a fixed file list. Delete a source
file without regenerating and the build fails with:

```
error: Build input files cannot be found: '.../OptotypeSizer.swift', '.../PpiProvider.swift'.
Did you forget to declare these files as outputs of any script phases or custom build rules?
```

That message names files that *no longer exist* and reads like a build-system bug. It is not — the
project is simply stale. `xcodegen generate` fixes it every time.

---

## Part 1 — Running the automated suite

### 1.1 Full suite from the command line

```bash
cd Myotect
xcodegen generate
xcodebuild -project Myotect.xcodeproj -scheme Myotect \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' test
```

Expected tail on a green run:

```
Executed 324 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

To see only the verdict:

```bash
xcodebuild -project Myotect.xcodeproj -scheme Myotect \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' test 2>&1 \
  | grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|error:"
```

> **`xcodebuild test` exits 0 even when tests fail.** Do not gate on the exit code. Grep for
> `** TEST FAILED **` / `** TEST SUCCEEDED **`, or use `-resultBundlePath` and inspect the bundle.

### 1.2 From Xcode

```bash
xcodegen generate && open Myotect.xcodeproj
```

Select the shared **Myotect** scheme and a simulator, then `⌘U`. The scheme is declared in
`project.yml` under `schemes:` and builds `Myotect` (all) + `MyotectTests` (test). Without that
declaration `xcodebuild` finds no scheme and falls back to the device placeholder.

### 1.3 Running a subset

```bash
# One test class
xcodebuild ... test -only-testing:MyotectTests/AcuityStaircaseEngineTests

# One test method
xcodebuild ... test -only-testing:MyotectTests/CoordinatorGateTests/testBelowGateHighContrastStillRunsBothLowContrastConditions

# Everything except one class
xcodebuild ... test -skip-testing:MyotectTests/CoordinatorGateTests
```

### 1.4 Faster iteration

Separate compilation from execution so repeat runs skip the build:

```bash
xcodebuild -project Myotect.xcodeproj -scheme Myotect \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' build-for-testing
xcodebuild -project Myotect.xcodeproj -scheme Myotect \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' test-without-building
```

### 1.5 Choosing a destination

Any simulator with a runtime ≥ iOS 17.0 works; the logic under test is device-independent. Pin the
OS explicitly — an unpinned `name=iPhone 16 Pro` matches several runtimes and xcodebuild emits an
ambiguity warning listing every candidate, which is easily mistaken for a failure.

```bash
xcrun simctl list devices available          # what you actually have
xcodebuild -project Myotect.xcodeproj -scheme Myotect -showdestinations
```

#### Pitfall 1 — a device destination cannot run these tests

Unit tests need a simulator or a provisioned device. With no `-destination`, xcodebuild picks the
generic device placeholder and fails on code signing.

#### Pitfall 2 — missing simulator runtime breaks destination resolution

If the runtime you name is not installed, xcodebuild can enumerate **zero** simulator destinations
for the scheme and every build fails with `id:dvtdevice-DVTiPhonePlaceholder ... iOS <x> is not
installed` — even when other runtimes exist. Fix:

```bash
xcodebuild -downloadPlatform iOS
```

#### Pitfall 3 — `-target` instead of `-scheme`

A bare `-target` build sees the simulator but cannot resolve SPM modules (`DevicePpi`, `WhisperKit`).
**Always go through `-scheme`.**

### 1.6 What the simulator can and cannot cover

| Exercised in the simulator | Requires physical hardware |
| --- | --- |
| Every unit test (all pure logic) | ARKit face tracking / real distance |
| The full phase flow via `MockDistanceProvider` + `MockLetterRecognitionService` | Live microphone capture |
| Sizing math, calibration, staircase, persistence | WhisperKit model load + real speech accuracy |
| The recognizer's listening rules and sample store (`ListeningBufferRulesTests`, `CaptureSampleStoreTests`, `RecognitionFlushRulesTests` — when a pass runs, how the consumed pointer and the soft deadline move, what the voice trace says) | WhisperKit's tap feeding the store, the real voice trace at 2 m, and the `[Whisper]` log lines that prove it (Part 3 § 3.5) |
| Back/Next navigation (the coordinator's skip), pause/resume policy | Brightness lock/restore; the Next "Skip this test?" confirmation dialog (UI-only, in `ScreeningRootView`) |
| Setup gating logic | Audio-session coexistence with ARKit |

In the simulator `ARFaceTrackingConfiguration.isSupported` is false, so `ScreeningRootView` swaps in
mocks: a steady 200 cm distance and a speech service that answers correctly for whatever letter is
shown. That runs a clean pass end-to-end without a microphone.

---

## Part 2 — The unit suite, test by test

**324 tests across 27 files.** All are `XCTest`, synchronous or `@MainActor`, and deterministic —
no `Date.now` dependence in assertions, no randomness (condition order is injected via
`lowContrastOrderOverride`), no sleeps. (`grep -c 'func test' Tests/*.swift` sums to 325: the extra
hit is `CoordinatorGateTests.testCalibration(pointsPerMillimeter:)`, a static fixture helper that
XCTest does not run.)

| File | Tests | Under test |
| --- | ---: | --- |
| [CoordinatorGateTests](#coordinatorgatetests--54-tests) | 54 | `MyopiaScreenCoordinator` — the whole state machine, incl. the operator capture hold, config→session contrast, the no-input window and the uncounted no-input rule, the low-contrast starting level, the below-gate flow and confirmed skips, and the inter-stimulus blank |
| [DistanceModelsTests](#distancemodelstests--28-tests) | 28 | Sample validity, validity resolution, emission throttle |
| [AcuityStaircaseEngineTests](#acuitystaircaseenginetests--21-tests) | 21 | ETDRS five-letter staircase: advance/step-back/terminations/gate/two-terminal logMAR |
| [LetterMappingTableTests](#lettermappingtabletests--19-tests) | 19 | Transcript → Sloan letter mapping, normalization, spoken skip |
| [CoordinatorRetryTests](#coordinatorretrytests--22-tests) | 22 | Retry → keypad escalation, spoken skip, uncounted no-input rows and their backstop, end to end |
| [ScreenConfigTests](#screenconfigtests--17-tests) | 17 | Ladder arithmetic for the low-contrast start, staircase-config factory, protocol and listening defaults, `init(settings:)` |
| [ScreeningSettingsProviderTests](#screeningsettingsprovidertests--13-tests) | 13 | Operator settings store: defaults, round trips, self-invalidation, notifications, v1 → v2 upgrade |
| [ListeningBufferRulesTests](#listeningbufferrulestests--16-tests) | 16 | The pure listening-buffer rules behind the WhisperKit service: voice trace, when a pass runs, consumed pointer, flush span, carried-over voice, soft deadline |
| [ScreenCalibrationProviderTests](#screencalibrationprovidertests--12-tests) | 12 | Auto + manual calibration, invalidation |
| [SessionStoreTests](#sessionstoretests--12-tests) | 12 | JSON/CSV encoding, quoting, weber and counts-toward-staircase columns, legacy rows, delta, load ordering, delete-all |
| [DistanceBandGateTests](#distancebandgatetests--10-tests) | 10 | Pause/resume hysteresis |
| [WhisperTranscriptFilterTests](#whispertranscriptfiltertests--10-tests) | 10 | Filler / silence-hallucination rejection; skip and hesitant answers pass through |
| [OptotypeSizingTests](#optotypesizingtests--9-tests) | 9 | Physical sizing math and render damping |
| [DistanceHoldTrackerTests](#distanceholdtrackertests--9-tests) | 9 | Operator-initiated capture hold (anchor, tolerance, countdown, mean) |
| [ContrastPaletteTests](#contrastpalettetests--9-tests) | 9 | Weber contrast (5/10/15/20 %), the 20 % default, channel isolation |
| [SizingProvenanceTests](#sizingprovenancetests--8-tests) | 8 | Provenance matching and Codable round-trips |
| [RetryEscalationPolicyTests](#retryescalationpolicytests--9-tests) | 9 | The escalation state machine in isolation |
| [CoordinatorTTSTests](#coordinatorttstests--10-tests) | 10 | Spoken prompts wired into the flow |
| [RecognitionFlushRulesTests](#recognitionflushrulestests--7-tests) | 7 | The pure outcome rules of the WhisperKit service's deadline flush: engagement, trace-upgraded silence |
| [ARKitDistanceProviderTests](#arkitdistanceprovidertests--5-tests) | 5 | Smoothing and plausibility rejection |
| [SpeechAnnouncerTests](#speechannouncertests--5-tests) | 5 | Utterance lifecycle and completion-exactly-once |
| [IdleTimerControllerTests](#idletimercontrollertests--5-tests) | 5 | Display-sleep lock and restore |
| [PromptThrottleTests](#promptthrottletests--4-tests) | 4 | Repeat-prompt throttling |
| [CaptureSampleStoreTests](#capturesamplestoretests--4-tests) | 4 | The recognizer's own sample store: block-complete cue, absolute indices across purges, clamped copies |
| [HeardDiagnosticFormatterTests](#hearddiagnosticformattertests--4-tests) | 4 | The operator "Heard" line's wording, one test per diagnostic kind |
| [WhisperServiceSourcePinsTests](#whisperservicesourcepinstests--1-test) | 1 | Source pin: the service never reads WhisperKit's buffer or its voice heuristic |
| [MyotectTests](#myotecttests--1-test) | 1 | Placeholder |

### ScreeningSettingsProviderTests — 13 tests

Pins the operator-settings store (`ScreeningSettingsProvider`): empty defaults → 20% Weber +
audio on (`testEmptyDefaultsReturnTwentyPercentWithAudioOn`);
`testTwentyPercentIsAnApprovedChoiceAndTheDefault` (`.twenty` = 0.20, label "20%",
`defaultChoice`, and the picker order 5% / 10% / 15% / 20% built from `allCases`); save/read round
trips for every 5/10/15/20% × audio combination; garbage, schema-mismatch, and disallowed-weber
records return defaults AND delete themselves; save/reset post `.screeningSettingsDidChange` with
the new value. Suite-isolated `UserDefaults(suiteName:)` per test, per the
`ScreenCalibrationProviderTests` harness.

**v1 → v2 upgrade (5)** — a schema-1 record is upgraded on read, not deleted:
`testLegacyImplicitTenPercentMovesToNewDefaultAndKeepsAudio` (a v1 10% may have been written by the
audio toggle alone, so it is treated as "never chose": contrast → 20%, audio kept, and the record is
re-persisted as v2 so the upgrade runs exactly once) · `testLegacyExplicitChoicesSurviveTheUpgrade`
(5% / 15% can only have come from the picker, so they are kept) ·
`testLegacyRecordWithDisallowedWeberIsDeleted` · `testUnknownSchemaVersionsAreDeletedOnSight`
(schema 0 and schema 3 both delete) · `testUpgradeDoesNotPostChangeNotification` (a getter must not
fan out UI updates).

### DistanceHoldTrackerTests — 9 tests

Pins the operator-initiated capture hold to the gold semantics: tap-instant anchor, hard ±4 cm
envelope judged against the ANCHOR (not the last reading), whole-second countdown values,
timestamp-deduped mean of the steady window, face-loss/drift voids, cancel-discards-silently, and
fresh re-anchoring after a void.

---

### CoordinatorGateTests — 54 tests

The largest and most important file: it drives `MyopiaScreenCoordinator` through complete flows with
injected mocks, asserting the protocol invariants listed in the README. A static
`testCalibration(pointsPerMillimeter:)` helper (not a test) builds a fixed calibration so sizing is
reproducible.

**Protocol flow**

| Test | Asserts |
| --- | --- |
| `testReachesWarmupAfterDistanceLock` | Operator Capture tap + completed 2 s hold transitions `distanceLock → warmup` and records `lockedDistanceCM` |
| `testValidSamplesAloneNeverAdvancePastDistanceLock` | However long the subject stands steady in band, nothing advances without the tapped hold |
| `testCaptureNotReadyOutOfBandAndTapRefused` | Out-of-band readings never arm Capture; a stray tap starts nothing |
| `testHoldVoidsOnDriftWithRetryNoticeThenRecaptures` / `testHoldVoidsOnFaceLoss` | Anchor drift > 4 cm or face loss voids the hold with the gold retry notice |
| `testHoldVoidsWhenLeavingValidBandEvenWithinAnchorTolerance` | A hold near the band edge cannot complete out of band |
| `testHoldWithinToleranceCapturesMeanOfWindow` | The recorded `lockedDistanceCM` is the deduped hold-window mean (≠ anchor, ≠ target), frozen at completion |
| `testHoldShowsWholeSecondCountdown` | `captureState` counts "2 s → 1 s" from sample timestamps |
| `testLockedDistanceClearedByBackNavigationAndManualSkip` | Back + manual skip never exports an abandoned run's captured distance |
| `testGatePassRunsBothLowContrastConditions` | Reaching 20/25 runs red *and* teal, then results |
| `testBelowGateHighContrastStillRunsBothLowContrastConditions` | A below-20/25 high-contrast run still runs red *and* teal; all three results and the delta are recorded and `interpretation` is a delta label, never `highContrastBelowGate` |
| `testAmbiguousRepeatsSameLetterWithoutAdvancing` | An ambiguous answer re-presents the *same* letter and records no trial |
| `testSessionRecordsConfiguredWeberContrast` | The injected config's `lowContrastWeber` (0.15, deliberately not the 0.20 default) is what the session record exports |

**Distance policy — the heart of the correctness story**

| Test | Asserts |
| --- | --- |
| `testDistanceInvalidPausesAndResumesWarmupLetter` | Leaving the band mid-warm-up pauses; re-lock re-presents the same warm-up letter |
| `testDistanceInvalidPausesAndResumesScoredTrial` | Same for a scored trial — the letter is never silently swapped |
| `testStaleDistanceAtAnswerTimeIsNotScoredAndLetterRepeats` | An answer arriving with no *fresh* sample is discarded, not scored |
| `testResumeRequiresInsetBandNotJustDwellLock` | Re-entering the raw band is insufficient; resumption needs the **inset** band (anti-chatter hysteresis) |
| `testInterruptionMidTrialPausesAndRecoveryResumesSameLetter` | An AR session interruption pauses and recovers to the same letter |
| `testBackgroundPausesTrialAndForegroundRequiresRelock` | Backgrounding pauses; foregrounding alone never resumes scoring |
| `testRecordedTrialDistanceIsAnswerTimeSampleNotLockValue` | The recorded `distanceCM` is the answer-time measurement, not the lock value |
| `testNoStimulusBeforeFirstDistanceSample` | No letter is shown until a real measurement exists (no assumed distance) |

**Calibration and sizing**

| Test | Asserts |
| --- | --- |
| `testBeginRefusedWhenUncalibrated` | `beginAfterSetup()` is a no-op without a validated calibration |
| `testBeginRefusedWhenDisplayTooSmallForWorstCase` | A display that cannot fit the worst-case letter blocks at setup rather than cropping later |
| `testLiveResizeAboveThresholdGrowsSpecAndKeepsLetter` | Drift beyond the damping threshold re-sizes the glyph but keeps the same letter |
| `testSubThresholdResizeIsDamped` | Sub-half-physical-pixel drift does **not** republish the stimulus |
| `testScoringBlockedWhenCalibrationChangesMidTrial` | A mid-session calibration change pauses instead of mis-scoring |
| `testTrialCarriesProvenanceAndSessionCarriesCalibration` | Each trial records its sizing provenance; the session records the calibration in force |

**No-input window**

| Test | Asserts |
| --- | --- |
| `testListenArmsTheServiceWithTheNoInputWindow` | `listen()` arms the service with `config.recognitionTimeoutSeconds` (10 s, soft). It is the only place the window flows and every fake discards it, so a regression to a literal or the old 5 s / 8 s would otherwise ship green |
| `testNoInputTrialsAreRecordedButNeverMoveTheStaircase` | Five silent letters are five uncounted `no input registered` rows in the same slot (`trialNumber` 1): the level stays 20/40, each is replaced by a fresh letter, and three correct answers afterwards still early-pass the line with slots 1, 2, 3 (backstop raised to 100 to isolate the rule from the keypad hand-off) |
| `testLateSilenceAfterTeardownIsDropped` | `teardown()` bumps the recognition generation, so a silence callback already dispatched cannot score into a dead session |

**Low-contrast starting level** — two ladder steps coarser than the finest high-contrast line
actually passed, clamped to the coarsest rung (20/200).

`testLowContrastStartsTwoStepsCoarserThanHighContrastResult` (passed 20/20 → starts 20/32) ·
`testLowContrastStartAtGateEdgeMatchesProtocolStart` (passed 20/25 → 20/40, identical to
`startAcuity`) · `testLowContrastStartAfterBelowGateResultAnchorsToPassedLine` (passed only 20/50 →
20/80) · `testLowContrastStartClampsToCoarsestRungWhenNothingPassed` (nothing passed → 20/200) ·
`testBothLowContrastConditionsStartAtTheSameDerivedLevel` (teal is never chained
off red) · `testLowContrastFallsBackToProtocolStartWhenGateSkipped` ·
`testLowContrastStartIsRederivedAfterBackNavigation`.

**Inter-stimulus blank** — the next letter is committed but hidden, and recognition is not armed,
until the blank clears.

`testBlankHoldsStimulusHiddenAndDefersListening` · `testBlankPrecedesEachSubsequentLetter`
(warm-up included) · `testDistancePauseDuringBlankCancelsIt` (the square never sticks black and a
cancelled reveal never fires late) · `testZeroBlankPresentsSynchronously` (the fast path the rest
of the suite relies on).

**Back navigation** — returns to the *start* of the preceding phase and rolls back what that phase wrote.

`testBackFromWarmupReturnsToDistanceLock` · `testBackFromGateReturnsToWarmup` ·
`testBackFromLowContrastReturnsToGateAndClearsResults` · `testBackFromSetupIsNotHandled` (returns
`false` so the caller dismisses the flow) · `testStaleRecognitionCallbackAfterBackIsIgnored` (the
generation counter neutralizes an in-flight callback from the abandoned phase).

**Forward (Next) navigation** — skips the current test *without* recording a result, preserving earlier results.
On the three scored phases the operator's Next first shows a "Skip this test?" confirmation; that
dialog lives in `ScreeningRootView` (keyed off `ScreenPhase.scoredCondition`) and is device-only —
the coordinator's `goNext()` is unchanged and these tests drive it directly.

`testNextFromSetupBeginsDistanceLock` · `testNextFromDistanceLockSkipsToWarmup` ·
`testNextFromWarmupSkipsToGate` · `testNextFromGateSkipsToLowContrastWithoutRecording` ·
`testNextThroughLowContrastConditionsReachesResults` · `testNextFromResultsIsNotHandled` ·
`testScoredConditionForPhase` (`ScreenPhase.scoredCondition` is non-nil for exactly the three
scored phases) · `testSkippingOneLowContrastConditionKeepsTheOtherTwoResults` (Next on red leaves
red `nil`, keeps the high-contrast and teal results, delta `nil`, `interpretation = notComputed`).

---

### DistanceModelsTests — 28 tests

Pure validity logic — no ARKit involved.

**`DistanceSample.isValid` (9)** — `testFreshInRangeSampleIsValid`,
`testAgeExactlyAtMaximumIsValid` (inclusive boundary), `testAgeJustOverMaximumIsInvalid`,
`testNegativeAgeIsInvalid` (future/garbage timestamps rejected), `testNaNDistanceIsInvalid`,
`testInfiniteDistanceIsInvalid`, `testBoundaryDistancesAreValid`, `testJustOutsideRangeIsInvalid`,
`testNegativeMaximumAgeIsInvalid`.

**Validity resolution from provider state (13)** — every `DistanceTrackingState` maps to the right
`DistanceValidity`: `testIdleResolvesMissing`, `testUnsupportedResolvesUnsupported`,
`testInterruptedResolvesInterrupted`, `testFailedResolvesFailed`,
`testTrackingWithNoSampleResolvesMissing`, `testTrackingWithRawOutOfRangeResolvesOutOfRangeWithPayload`,
`testRawOutOfRangeWinsOverStoredSample` (an implausible raw reading must not be masked by a stale
good one), `testTrackingWithFreshSampleResolvesValidWithPayload`,
`testAgeExactlyAtMaximumResolvesValid`, `testTrackingWithOldSampleResolvesStale`,
`testTrackingWithFutureSampleResolvesStale`, `testResolverHonorsInjectedRange`,
`testValiditySampleAccessorReturnsOnlyValidPayload` (a `.stale` sample is never surfaced as usable).

**`ValidityEmissionThrottle` (6)** — same-kind updates throttle to the configured interval while
*kind changes deliver immediately*: `testFirstEmissionAlwaysEmits`,
`testSameKindWithinIntervalSuppressed`, `testSameKindAtIntervalEmits`,
`testKindChangeEmitsImmediatelyWithinInterval`, `testSuppressedRepeatDoesNotExtendThrottleWindow`
(a suppressed emission must not push the next deadline out), `testResetClearsHistory`.

---

### ScreenCalibrationProviderTests — 12 tests

`testVerifiedDeviceProducesAutomaticCalibration` (`ppi / nativeScale / 25.4`),
`testScreenSignatureFormat` (`machineIdentifier|WxH|nativeScale`),
`testUnknownDeviceRequiresManualCalibration`, `testSuggestedPointsPerMillimeterFallsBackToSuggestedPPI`,
`testSaveManualCalibrationValidatesAndPostsNotification`,
`testSaveManualCalibrationRejectsNonPositiveValues`,
`testChangedSignatureDeletesManualCalibrationPermanently`,
`testStaleSchemaVersionDeletesManualCalibrationPermanently`, `testUndecodableRecordIsDeleted`,
`testClearManualCalibrationPostsNotificationAndRequiresRecalibration`,
`testManualCalibrationRejectsMismatches`, `testStaticProviderStates`.

The three *deletes* matter most: a calibration is valid for exactly one hardware/display signature
and schema version. Anything else is destroyed on sight so it can never resurface and silently
mis-size letters on different hardware.

---

### LetterMappingTableTests — 19 tests

`testCommonPhonetics` ("see"→C, "aitch"→H, "kay"→K …) · `testCaseAndPunctuationInsensitive` ·
`testSingleLetterDirectMatch` · `testNonSloanReturnsNil` · `testConversationalYesIsNotALetter`
("yes" must never score as S) · `testNormalizationSpacesOutPunctuation` ("C-D" → "c d",
"[BLANK_AUDIO]" → "blank audio") · `testPunctuationJoinedLettersClassifyAsAmbiguous` ·
`testClassifySingleLetter` · `testClassifyAmbiguousWhenMultipleDistinctLetters` (two distinct
letters in one transcript → `.ambiguous`, never a guess) · `testClassifyUnrecognizedKinds`
(`.silence` vs `.unintelligible`) · `testMisidentificationCorrections` ("okay"→K, "and"→N, "our"→R).

Three **table-integrity** tests guard the data itself: `testMisidentificationValuesAreSloanLetters`,
`testAllValuesAreSloanLetters`, and `testPhoneticsAndMisidentificationsAreDisjoint` — so a new entry
can never introduce a non-Sloan target or shadow a genuine phonetic spelling.

**Spoken skip (5)** — `testClassifySkipAndWhisperVariants` (every `skipPhrases` entry, plus
"Skip." / "SKIP!" / "skipped" / "skype", → `.skipped`) · `testClassifySkipWithFillerOrTailIsSkip`
("um skip", "skip it", "please skip", "skip thank you") ·
`testClassifySkipMixedWithLetterIsAmbiguous` ("c skip", "S, skip", and "okay skip" — "okay" is a K
correction, pinned so nobody "fixes" it blind) · `testTierTwoSkipVariantsAreNotSkips` ("ski",
"kip", "skit", "skid", "skiff" stay `.unintelligible`; "S K" stays `.ambiguous`) ·
`testSkipPhrasesNeverCollideWithLetterTables` (no skip phrase may resolve to a Sloan letter through
any layer, or a real answer would be scored as a skipped miss).

---

### AcuityStaircaseEngineTests — 21 tests

Pins the gold ETDRS five-letter protocol (5 trials/level, ≥3 to advance, early-perfect at 3,
two-terminal-line ±0.02/letter scoring), ported from the reference
`ETDRSProgressionEngineTests`.

`testConfigurationIsFiveLetterProtocol` · `testStartsAtConfiguredAcuity` ·
`testAcuityLevelsContain25` (the gate must be a real level) ·
`testThreeInitialCorrectUsePerfectShortcut` · `testAnyMissInFirstThreeRequiresAllFiveResponses` ·
`testThreeOfFiveAdvances` · `testTwoOfFiveStepsBackToUntestedLargerAcuity` ·
`testContinuesWithinLevel` · `testNextTrialNumberCountsWithinLevelAndResetsOnChange` ·
`testFailingAboveAPassedLevelFinishesWithFailedLineAsPrimary` (primary = the FAILED finer line) ·
`testAdvancingIntoAlreadyCompletedLevelFinishesInsteadOfRetesting` (a completed line is never
re-tested or overwritten) · `testFailAtLargestLevelScoresAgainstSecondLargest` ·
`testPassingFinestLevelFinishes` · `testFailingFinestLevelStillScoresFromItAsPrimary` ·
`testMissedLettersAcrossBothTerminalLinesAllCount` (every miss on BOTH terminal lines credits
0.02) · `testPassingFinestAsStartScoresUntestedCoarserSecondaryAsZero` (untested coarser terminal
line scores 0 correct, +0.1 logMAR — gold's smallest-boundary rule) · `testGateReachedAtTwentyFive` ·
`testGateNotReachedWhenStuckAtThirtyTwo` · `testGateNeverOpensOnAFailedPrimaryLine` ·
`testLowContrastConfigHasNoGate` (`gateAcuity = nil` ⇒ `reachedGate` always true) ·
`testEarlyPerfectRecordsFullLineInPerLevelCorrect`.

---

### DistanceBandGateTests — 10 tests

The inset is `min(resumeInsetMaxCM, resumeInsetFraction × bandWidth)` per side — 3 cm for the default
180–240 cm band.

`testStandardBandInsetIsCapped` · `testNarrowBandUsesFractionalInset` ·
`testShouldPauseJustOutsideRawBounds` · `testShouldNotPauseAtRawBounds` (boundary is inclusive) ·
`testShouldNotPauseInsideBand` · `testResumeBandRejectsShallowReentry` · `testResumeBandAcceptsInsetBoundary`.

Degenerate-geometry guards: `testDegenerateTinyBandDoesNotInvert` (insets that would cross collapse
to the midpoint rather than producing an inverted range that traps the user in a permanent pause),
`testZeroWidthBandCollapsesToItself`, `testZeroInsetKeepsResumeBandEqualToBand`.

---

### OptotypeSizingTests — 9 tests

| Test | Asserts |
| --- | --- |
| `testTwoHundredCentimeterAnchors` | The canonical anchors at 200 cm (see [Part 4](#part-4--verifying-physical-optotype-size)) |
| `testAllAcuitiesAcrossProviderDistanceRange` | Every level × the full 100–300 cm range stays finite, positive, monotonic |
| `testPhysicalHeightIsIndependentOfDisplayScale` | Physical mm is invariant to `nativeScale` — the anti-regression test for the Plus-class undersizing bug |
| `testSloanFontPointSizeProducesRequestedCapHeight` | Point size is derived from the *live* font's cap-height ratio, not a hand-tuned multiplier |
| `testInvalidInputsThrowSpecificErrors` | Each bad input throws its own `OptotypeSizingError` (never silently substitutes a default) |
| `testNeedsRenderUsesHalfPhysicalPixelThreshold` | Re-render only past half a physical pixel |
| `testNeedsRenderInvalidatesOnCalibrationIdentityChange` | A calibration identity change forces a re-render regardless of damping |
| `testNeedsRenderForcedOrWithoutPreviousSpec` | `force` and first-render always render |
| `testFitsSquareBoundary` | The fit check is exact at the boundary, so a letter is never cropped by a rounding error |

---

### SizingProvenanceTests — 8 tests

`matches(_:)` must fail closed on every axis: `testMatchesPassesOnIdentity`,
`testMatchesFailsOnSizingVersionMismatch`, `testMatchesFailsOnCalibrationSourceMismatch`,
`testMatchesFailsOnPointsPerMillimeterMismatch`, `testMatchesFailsOnScreenSignatureMismatch`,
`testMatchesFailsWhenCalibrationIsNotValidated`. Plus
`testProvenanceCodableRoundTripPreservesEquality` and `testCalibrationCodableRoundTripPreservesEquality`
so archived sessions stay comparable to live ones.

---

### WhisperTranscriptFilterTests — 10 tests

`nonAnswerKind(_:)` runs *before* the letter mapper and separates "the child made a sound" from "the
microphone heard nothing".

`testFillerKind` ("um", "uh", "hmm" → `.filler`) · `testSilenceKindForHallucinations`
(Whisper's classic near-silence output "you", "thank you", "thanks for watching" → `.silence`) ·
`testSilenceKindForSilenceMarkers` ("blank audio", "silence", "music") ·
`testSilenceKindForBracketedWhisperMarkers` ("[BLANK_AUDIO]", "(blank audio)", "[SILENT_AUDIO]",
and the compact "blankaudio" / "silentaudio") · `testSilenceKindForEmptyAndWhitespace` ·
`testRealAnswerCandidatesReturnNil` (a genuine answer must reach the mapper untouched) ·
`testHesitationPrefixedAnswersReachTheMapper` ("Er, R", "Uh, H" must not be swallowed as filler —
their compact forms "err" / "uhh" are filler words) · `testDeprecatedIsNonAnswerShimAgrees`.

The critical one is `testRejectedPhrasesNeverCollideWithLetterTables`: **no rejected phrase may also
be a valid letter spelling.** Without it, adding a filler word could silently make a real Sloan
answer unanswerable. `testSkipPhrasesReachTheMapper` is its mirror for the spoken skip: the filter
runs first, so no `skipPhrases` entry may sit in either rejection set, and "um skip" / "skip thank
you" / "skip you" must pass through and classify as `.skipped`.

---

### ListeningBufferRulesTests — 16 tests

The pure listening-buffer rules behind `WhisperKitLetterRecognitionService` (`ListeningBufferRules`,
a port of the sibling ETDRS app's rule tests plus Myotect's additions): WHEN audio is transcribed,
what the voice trace says, and how the deadline and the consumed pointer move. Each test names the
device failure it prevents.

**Voice trace** — `testBlockEnergiesAreRMSPerFullBlock` (100 ms blocks, trailing partial block
dropped, boundaries follow the slice) · `testRelativeEnergiesIgnoreDigitalZeroReferencesAndStartQuiet`
(a zero or ramp-in buffer at engine start never becomes the silence reference — otherwise room noise
reads as voice for a whole window — and the first block reads 0) ·
`testWindowHadVoiceNeedsTwoConsecutiveVoiceBlocks` (a speech-length sound is two consecutive voice
blocks; a click is not) · `testTailHasVoiceLooksOnlyAtTheQuietTail` ·
`testSpeechRunsIgnoreIsolatedVoiceBlocks`.

**Passes and the consumed pointer** — `testLivePassWaitsForTheUtteranceToEnd` (voice in the
unconsumed span AND a quiet 0.3 s tail, or 2 s of continuous voice; never on the first syllable
Whisper would complete into "seat") ·
`testConsumedPointerAdvancesForAnswersAndFinalButRetainsATailAfterANonAnswerPass` (an answer or the
final flush consumes everything; any other pass keeps the newest tail so a straddling onset survives
and a hallucinated "Thank you." can never swallow the child's audio; never backwards) ·
`testLiveWindowIsTheLastRollingWindowPastTheConsumedPointer` ·
`testFinalWindowStartsAtTheConsumedPointer` (both moved here from `RecognitionFlushRulesTests`) ·
`testFlushSpanCoversOnlySpeechLengthRunsWithPaddingAndIsNilWithoutOne` (the deadline flush decodes
from 0.5 s before the first speech-length run to 0.5 s after the last, clamped; an isolated click
before the answer does not widen it; nil with no run — then Whisper is not called at all).

**Myotect additions** — `testCarriedOverVoiceIsSkippedOnlyWhenTheSessionStartsInsideARun` (voice
already sounding in session block 0 began before the child could see the letter and is skipped; a
quiet block 0 skips nothing; a run longer than the utterance cap is capped, so a noisy room cannot
starve the trial) · `testCarriedOverBlocksGrowMonotonicallyAsTheRunGrows` (stateless, recomputed on
every pass) · `testDeadlineDefersOnlyForVoiceOrInferenceWithinTheCap` (the soft deadline steps back
while the tail is voice or a decode is in flight, and never past the cap — a television keeps the
tail voiced forever).

---

**Engine starts and the review-driven rules (2026-09-03)** —
`testEngineStartBlocksAreMaskedOutOfTheReference` (the block an engine start lands in, and the
next, are zeroed out of the trace: a mostly-digital-zero block with a sliver of room noise would
otherwise become the silence reference, make room noise read as voice, and let the carried-over
rule swallow a real answer) · `testCapPathRetainedTailReTriggersOnceTheSoundEnds` (after a
2 s cap pass the retained tail IS voice, so the first quiet blocks re-run a pass over the end of
the same long answer; a fully consumed utterance never re-triggers) · `testFlushSpanBridgesTwoRuns`
(two speech-length runs decode as one padded span, and a run already consumed is left out).

### CaptureSampleStoreTests — 4 tests

The recognizer's own 16 kHz sample store (`CaptureSampleStore`): absolute, block-aligned indices
that survive trimming, so every index the listening rules bookkeep stays valid across purges and
engine rebuilds.

`testAppendReportsCompletedBlocksOnlyAndCarriesTheRemainder` (`append` returns true only when a
100 ms block completed — the cue to run a pass — and a partial block carries over) ·
`testAbsoluteIndicesSurviveAPurge` (`baseIndex` advances, `totalCount` and `copySamples` keep
answering in absolute terms) · `testPurgeIsBlockAlignedAndNeverDropsBelowKeep` (pins
`baseIndex % 1600 == 0` after every purge, so energy block `k` is always samples
`[baseIndex + 1600k, …)`) · `testCopySamplesClampsOutOfRangeRequests` (a range reaching before the
purge point or past the end is clamped, never a crash).

---

### RecognitionFlushRulesTests — 7 tests

The pure outcome rules of `WhisperKitLetterRecognitionService`'s deadline flush, testable without
WhisperKit. They exist because a `no input registered` row is visible in every export and its
backstop is the only exit from a same-level loop, so the service may only say "silence" when nothing
usable was said in the whole window. The buffer arithmetic lives in `ListeningBufferRulesTests`.

`resolveFinalOutcome`: `testSilentTailAfterEngagedPassReportsTheEngagedPass` ("um" / "banana" /
"C D" at 2 s and quiet after → the earlier filler / unintelligible / ambiguous pass is reported, so
the child retries with a re-prompt instead of being logged absent) ·
`testSilentTailWithNoEngagementIsSilence` · `testAnsweredOrInspectedTailAlwaysWins` (a letter,
skip, unintelligible tail, or service failure is never overridden by earlier engagement).
`strongerEngagement`: `testEngagementRanksAmbiguousOverUnintelligibleOverFiller` (never downgrades)
· `testNonEngagementNeverCountsAsEngagement` (silence, letters, skips, and failures rank zero).
`upgradedForTrace`: `testSilenceWithSpeechLengthSoundUpgradesToUnintelligible` (a transcript the
filter called a silence hallucination — "Thank you.", "you", "" — over a speech-length sound becomes
`.unintelligible`, which retries; every other outcome passes through untouched; with no sound the
hallucination stays silence) · `testHallucinationCountsAsEngagementOnlyWithSound` (the upgrade feeds
the engagement bookkeeping, so a quiet tail after a hallucination-over-sound retries, while a
hallucination over nothing lets the window still end as silence).

---

### HeardDiagnosticFormatterTests — 4 tests

One test per `RecognitionDiagnostic.Kind`; the strings are what the operator reads at the top of
the trial screen (PROTOCOL §7c), so a wording change is a deliberate edit here, never a side effect.
`testListeningIsTheArmedPlaceholder` (`Listening…`) · `testHeardShowsTheRawTranscriptAndEveryOutcome`
(`Heard "C." → C ✓` / `✗`, `→ skip`, `→ more than one letter`, `→ hesitation`, `→ no letter`,
`→ nothing usable`, `Microphone unavailable`; whitespace and newlines collapse; a long hallucination
is capped at 24 characters with an ellipsis) · `testDeferredDeadlineShowsTheAccumulatedExtension`
(`Deadline extended +0.75 s`) · `testFlushedSilentSaysNothingWasHeard` (`Heard nothing (window
elapsed)`).

---

### WhisperServiceSourcePinsTests — 1 test

`testServiceNeverReadsWhisperKitsBufferOrItsVoiceHeuristic` reads
`WhisperKitLetterRecognitionService.swift` as text (the one file the simulator cannot exercise) and
asserts it never references `AudioProcessor.isVoiceDetected`, `.relativeEnergy`,
`purgeAudioSamples`, or `audioProcessor.audioSamples` — the three regressions that reintroduce the
on-device bugs the listening rework fixed (data race, indices reset by every engine start, gating on
the first syllable) — while still reaching the engine's own `isRunning` through the
`as? AudioProcessor)?.audioEngine` cast and feeding `CaptureSampleStore`.

---

### ContrastPaletteTests — 9 tests

`testContrastConfigDefaultIsTwentyPercent` pins `ContrastConfig().weber`,
`ScreenConfig().lowContrastWeber`, AND `WeberContrastChoice.defaultChoice` to the 20% protocol
default so they can never silently drift apart. `testWeberTwentyPercent` (0.80 at 20%) and
`testWeberFifteenPercent` (0.85 at 15%) cover the protocol-selectable values. The red/teal channel
tests pin behavior against an explicit `ContrastConfig(weber: 0.10)` (stimulus channel = 0.90 of
background), not the type default.

`testWeberFivePercent` and `testWeberTenPercent` pin `stimulus = background × (1 − weber)` ·
`testWeberMatchesMeetingExample` pins the agreed clinical worked example ·
`testHighContrastIsBlackOnWhite` · `testRedConditionIsolatesRedChannel` and
`testTealConditionIsBlueGreen` — the duochrome comparison is only meaningful if no long-wavelength
light contaminates the short-wavelength stimulus, so red must be exactly 0 in the teal condition.

---

### SessionStoreTests — 12 tests

New with the configurable-contrast work: `testCSVCarriesSessionWeberContrastOnEveryRow` (the
19th `weber_contrast` column repeats the session value on every trial row — pinned positionally,
since it is no longer the last column — and the header still ends in `,counts_toward_staircase`,
pinning the append-last rule) and `testDeleteAllSessionsRemovesEverything` (Clear All History wipes
the store). `testNonLetterResponseSentinelsStayUnquotedAndAlignedInCSVAndJSON` pins the `-` /
`skip` / `no input registered` sentinels: written verbatim, 20 plain columns even for a
comma-splitting parser, never quoted, and round-tripped through JSON.

New with the uncounted no-input rule (2026-09-03):
`testCountsTowardStaircaseRoundTripsThroughJSONAndCSVWithLegacyNilReadingAsOne` (the 20th
`counts_toward_staircase` column is `1` / `0`, appended last; `true` / `false` / nil round-trip
through JSON and export as `1` / `0` / `1`) ·
`testLegacyTrialJSONWithoutTheFlagDecodesAsNilAndExportsAsCounted` (a pre-2026-09-03 row — including
a 09-02-era `no input registered` miss — decodes with the flag absent, re-encodes without the key,
and exports as counted).

`testJSONRoundTrip` · `testDecodeJSONRoundTrip` (ISO-8601 dates, sorted keys) ·
`testCSVRowCountMatchesTrials` (header + one row per trial) · `testDeltaIsGreenMinusRed` (sign
convention: positive means red was read better) · `testDeltaNilWhenMissingCondition` (never a
half-computed delta) · `testLoadAllSessionsReturnsSavedSessionsNewestFirst`.

`testCommaBearingScreenSignatureStaysAlignedInCSV` guards a real-data trap: device machine
identifiers are `iPhone17,1`-shaped, so an unquoted `screen_signature` would push every subsequent
provenance column one field to the right on **every real device**. `SessionStore.csvField` applies
RFC-4180 quoting. See [DATA_FORMAT.md](DATA_FORMAT.md#csv--trial-rows).

---

### ARKitDistanceProviderTests — 5 tests

These test the provider's pure `ingest(rawDistanceCM:timestamp:)` seam, so no AR session is needed.

`testInRangeReadingsAreSmoothedIntoValidSamples` (moving average: 200 then 220 → 210) ·
`testOutOfPlausibleRangeIsRejectedAndClearsSmoothingAndSample` (an implausible value never surfaces
as a trustworthy sample, and recovery restarts smoothing with no residue) ·
`testNonFiniteReadingIsRejected` · `testPullValidityReflectsIngestedStateAndStaleness` ·
`testSmoothingWindowIsBounded`.

---

### CoordinatorRetryTests — 22 tests

End-to-end escalation through the coordinator, using a scripted speech service. Retries are driven
by `.unrecognized(.filler)` — voice silence on a scored trial neither retries nor counts: it is
recorded and replaced by a fresh letter (see below).

| Test | Asserts |
| --- | --- |
| `testRepeatedNonAnswersEscalateToKeypadAfterCap` | After the retry cap the trial hands off to the clinician keypad instead of looping forever |
| `testKeypadSubmissionScoresTrialAndNextTrialReturnsToVoice` | A keypad answer scores normally and the next trial goes back to voice |
| `testKeypadNoResponseScoresIncorrectTrial` | Keypad "No response" records an incorrect trial (`-`) rather than being dropped from the record |
| `testServiceFailureEscalatesImmediatelyWithAlert` | `.serviceFailure` bypasses retries entirely — it is structural |
| `testDistancePauseRepeatDoesNotGrantExtraRetries` | A pause repeat is not an answer attempt, so it cannot farm extra retries |
| `testConsecutiveKeypadTrialsBecomeStickyAndClinicianRestores` | Repeated escalations make manual mode sticky until explicitly restored |
| `testKeypadOnlyStartStaysStickyAcrossResolvedLetters` | Starting keypad-only from setup stays manual even as letters resolve successfully — it must not silently drift back to a mic that was never available |
| `testGoBackClearsNonStickyEscalationForCleanRerun` | Back re-runs a phase with escalation state reset, so a prior bad streak does not poison the retry |
| `testWarmupEscalationScoresNothingAndKeypadAdvancesWarmup` | Escalation during warm-up records no trial but still advances |
| `testSpokenSkipScoresIncorrectTrialAndPresentsNextLetter` | A spoken skip records an incorrect trial with `response = "skip"` and the NEXT letter listens by voice — no retry, no keypad |
| `testVoiceSilenceRecordsAnUncountedNoInputRowAndPresentsAFreshLetterAtTheSameLevel` | Voice silence records an incorrect `no input registered` row with `countsTowardStaircase = false` in slot 1; the level is unchanged and a different letter is listening |
| `testUncountedNoInputKeepsTheLevelPresentsAFreshLetterAndResetsTheRetryBudget` | The replacement is a genuinely fresh trial: same level, different letter, flag false on the row, and a fresh retry budget — a filler spent on the silent letter does not carry over (two fillers on the replacement still retry; the third escalates; nothing extra is recorded) |
| `testUnintelligibleAndAmbiguousStillRetryThenEscalateWithoutScoring` | Unintelligible / ambiguous answers still retry to the cap and escalate with nothing scored |
| `testThreeConsecutiveNoInputTrialsHandTheNextLetterToKeypad` | Three silent letters are recorded, uncounted, all at 20/40 in slot 1; the fourth presentation — a FRESH letter, not the silent one — goes to the keypad; keypad "No response" records a counted `-` in that same slot (`trialNumber`s 1, 1, 1, 1), and the trial after returns to voice |
| `testLetterBetweenSilencesResetsTheNoInputCount` | A spoken letter between silences resets the consecutive count — 2 + 1 + 2 never escalates (four uncounted rows) |
| `testConsecutiveNoInputEscalationsBecomeSticky` | A no-input row does not clear the escalation streak, so two no-input escalations with no voice letter between them make manual mode sticky |
| `testWarmupSkipCountsAsCompletedPracticeLetter` | A skip during warm-up counts as a completed practice letter and records nothing |
| `testSpokenSkipResetsTheNoInputCount` | S, S, skip, S, S never escalates: a heard skip resets the consecutive no-input count (five rows, one counted) |
| `testSpokenSkipClearsTheEscalationStreak` | A spoken skip is a heard voice answer, so it restarts the sticky-manual streak (keypad → skip → keypad stays non-sticky) |
| `testSilencesNeverCompleteTheSessionButTheBackstopKeypadCan` | Four wrong letters plus three silences at teal 20/20 do not end the session (silence never ends a condition); the backstop hands the fresh letter to the keypad, and the keypad "No response" is the fifth counted miss that completes it with no keypad armed on results (35 rows, 32 counted) |
| `testGateEndsOnLettersAndSilencesOnTheFirstLowContrastLettersTripTheBackstopInPlace` | The gate is ended by a wrong letter — two interleaved silences neither count nor carry across the boundary — and three silences on the first red letters trip the backstop with red still at 20/40 (19 rows, 14 counted) |
| `testReturningToVoiceAfterTheBackstopKeypadReopensTheCaptureSession` | A keypad escalation closes the block's capture session; when the keypad trial resolves and the next letter returns to voice, `listen()` re-opens it (idempotent), so the rest of the block keeps its warm engine and interruption/route observers instead of cold-starting the engine after every reveal |

### RetryEscalationPolicyTests — 9 tests

The same state machine in isolation: `testRetrySequenceThenEscalation` (first retry carries a spoken
re-prompt, later ones do not) · `testBeginTrialResetsAttemptCount` ·
`testDistancePauseRepeatsDoNotGrantExtraRetries` · `testServiceFailureEscalatesImmediately` ·
`testStickyManualAfterConsecutiveEscalationsAndVoiceResolveClearsStreak` ·
`testStickyManualBypassesRetries` · `testClinicianRestoreClearsStickyAndStreak` ·
`testForceStickyManualSurvivesResolvedTrials` (the keypad-only start latches until the clinician
restores voice, rather than clearing on the first successful answer) ·
`testNoInputEscalationCountsTowardStickyAndOnlyAHeardVoiceAnswerClearsIt` (the no-input backstop's
hand-off counts toward sticky manual; `trialResolved(byVoice: false)` — a keypad entry or a
no-input row — leaves the streak alone).

### CoordinatorTTSTests — 10 tests

`testPhasePromptsAreSpoken` · `testFirstRetrySpeaksReprompt` (a filler answer earns one spoken
re-prompt; the second retry is silent) · `testNoInputRowDoesNotSpeakReprompt` (voice silence on a
scored trial is recorded, not retried — no re-prompt, one uncounted row, a fresh letter listening
at the same level) · `testRepromptRetryBlanksLetterUntilPromptEnds` (the square is blanked while "Say the
letter you see out loud." plays, and the same letter re-presents with recognition armed only in the
prompt's completion; the stimulus stays committed so the blue frame stays up) ·
`testWarmupRepromptRetryBlanksUntilPromptEnds` (the same blank-during-re-prompt rule in warm-up,
where the completion presents a FRESH letter) ·
`testTeardownDuringRepromptClearsBlankAndIgnoresLateCompletion` (teardown mid-prompt clears the
blank, and the prompt's late completion finds a dead context) ·
`testVoidHoldPromptIsNotSupersededByGuidanceSpeech` (guidance speech stays
quiet while a voided hold's "try again" notice is up, or the prompt would be cut off mid-word) ·
`testDistanceGuidanceIsSpokenAndThrottled` · `testCompletionSpeaksAllDone` (answers wrong through
all three conditions before asserting `.results` and the "All done" prompt — no path ends the
session early).

The load-bearing one is `testListenDeferredWhileSpeakingAndResumesAfterFinish`: **recognition must
not run while the app is speaking**, or the microphone captures the app's own prompt. Listening is
deferred until the utterance finishes.

### SpeechAnnouncerTests — 5 tests

`testDisabledAnnouncerCompletesImmediatelyAndStaysSilent` (TTS off must not strand the flow waiting
on a completion) · `testIsSpeakingCoversPendingWindowBeforeUtteranceStarts` (the pre-speech
category-switch/settle window counts as speaking — otherwise the mic opens during exactly the gap
that matters) · `testStopFiresPendingCompletionExactlyOnce` ·
`testSupersedingSpeakFiresEarlierCompletionExactlyOnce` (superseding must not drop or double-fire a
completion, which would hang or double-advance the trial) · `testSilentAnnouncerRecordsPromptsSynchronously`.

### PromptThrottleTests — 4 tests

`testDifferentPromptSpeaksImmediately` (guidance reacts instantly when it actually changes) ·
`testSamePromptWithinIntervalIsSuppressed` (no chanting) · `testResetClearsHistory` ·
`testSuppressedAttemptDoesNotExtendWindow` (a suppressed attempt must not push the next allowed
utterance further out).

### ScreenConfigTests — 17 tests

The pure derivations on `ScreenConfig`.

**`acuityLevel(coarserBy:than:)` (6)** — `testTwoStepsCoarserWalksTheLadderTowardLargerLetters`
(20/16 → 20/25, 20/20 → 20/32, 20/25 → 20/40) · `testBelowGateAnchorsStillWalkTheLadderAndClamp`
(coarser by 2: 20/50 → 20/80, 20/80 → 20/125, 20/200 → 20/200) · `testZeroStepsIsIdentity` ·
`testClampsAtTheCoarsestLevel` · `testUnknownLevelFallsBackToProtocolStart` (an off-ladder input is
never returned verbatim — the engine would silently drop it to 20/200) · `testHonorsACustomLadder`.

**`staircaseConfig` (2)** — `testStaircaseConfigDefaultsToTheProtocolStartAndGatesOnlyWhenAsked` ·
`testStaircaseConfigCarriesAStartOverride`.

**Protocol and listening defaults (8)** — `testDefaultLowContrastOffsetIsTwoSteps` ·
`testDefaultInterstimulusBlankIsQuarterSecond` · `testDefaultNoInputWindowIsTenSeconds`
(`recognitionTimeoutSeconds` = 10, soft — a regression to the old 5 s / 8 s fails here, not on
device) · `testDefaultSoftDeadlineStepAndCap` (`deadlineDeferralStepSeconds` 0.25,
`deadlineDeferralCapSeconds` 3) · `testUtteranceRulesDefaults` (`utteranceEndQuietSeconds` 0.3,
`maximumUtteranceSeconds` 2, `voiceSilenceThreshold` 0.10 — the quiet tail is also the tail a
non-answer pass retains, so both derive from ONE key) · `testPurgeKeepCoversTheSilenceReference`
(`capturePurgeKeepSeconds` ≥ the 2 s reference window the voice trace is computed against, or the
first blocks of every session would read as voice) ·
`testDefaultListenResumeAfterSpeechIsHalfSecond` (`listenResumeAfterSpeechSeconds` = 0.5) ·
`testDefaultNoInputBackstopIsThreeTrials` (`noInputTrialsBeforeEscalation` = 3).

**`init(settings:)` (1)** — `testInitFromSettingsCopiesContrastAndAudio`: the settings → config
seam copies the Weber choice and the audio switch (probed with the never-default 5% / audio-off)
and leaves every other tunable at the protocol default; default settings yield 0.20 and TTS on.

### IdleTimerControllerTests — 5 tests

`testDisableSleepDisablesTheIdleTimer` · `testRestorePutsBackTheValueCapturedByTheFirstDisable` ·
`testRepeatedDisableSleepKeepsTheOriginalValue` (re-asserted on every return to the foreground, so
repeated calls must not overwrite the remembered original with the value the controller itself
wrote) · `testRestoreIsSafeBeforeAnyDisableAndIsIdempotent` ·
`testRestoreKeepsAnAlreadyDisabledTimerDisabled`.

### MyotectTests — 1 test

`testExample` — the XcodeGen scaffold placeholder. Harmless; delete when convenient.

---

## Part 3 — On-device validation

The unit suite cannot touch ARKit, the microphone, or the display. Run this protocol on a TrueDepth
device after any change to distance handling, speech, sizing, or the setup gate.

### 3.1 Setup

1. Build to the device (set `DEVELOPMENT_TEAM` in `project.yml` or select a team in Xcode).
2. Launch. Accept the camera and microphone prompts.
3. If the model is not vendored, the device needs network access for the first-launch download.
4. Measure and mark **2 m** from the device screen with a tape measure. Put the phone on a stable
   stand at the child's eye height.

### 3.2 Setup-screen gating

Confirm all seven rows show a green check and that *Begin* is disabled until they do:

| Row | How to force the failure state |
| --- | --- |
| Distance tracking available | Run on a non-TrueDepth device |
| Camera permission | Deny in Settings → Myotect |
| Microphone permission | Deny in Settings → Myotect (an "Open Settings" shortcut must appear) |
| Speech model ready | Airplane mode on first launch with no vendored model (a linear progress bar shows prep phase; on failure a "Retry loading" button must appear and work) |
| Screen calibrated | Use a device with no DevicePpi entry (must offer the ruler flow) |
| Sloan optotype font loaded | — (verify it is checked; failure text must be loud, never a silent system-font fallback) |
| Display fits protocol letters | — (verify on the smallest target device) |

**Keypad-only fallback.** When the *voice* path is blocked (mic denied or the model failed) but
everything sizing-related is satisfied, a secondary **"Continue with clinician keypad"** button
appears alongside the disabled *Begin*. It starts the session in sticky manual mode. Verify that:

- it appears **only** when the voice path is blocked and the sizing prerequisites all pass;
- it does **not** appear when calibration, font, display fit, camera, or face tracking is missing —
  those are hard requirements the keypad cannot substitute for;
- the session stays on the keypad for every trial, including after letters resolve successfully.

### 3.3 Distance lock

| Check | Expected |
| --- | --- |
| Step out of frame | "I can't see you. Step into view." |
| Stand at ~1.5 m | "Move farther away" |
| Stand at ~2.6 m | "Move closer" |
| Enter the band and hold | "Hold still…" then "Distance locked" after ~0.75 s |
| Sway gently in band | Lock should **not** trigger while SD > 5 cm |
| Reported distance vs tape | Agrees within a few cm across 180–240 cm |

### 3.4 Warm-up and trials

1. Before the first letter, brief the child: **"If you cannot see the letter, say 'skip'."** No
   spoken prompt says this.
2. Five large (20/80) high-contrast letters, unscored. Say each aloud.
3. Confirm a correctly recognized letter advances, and that an unclear answer **re-presents** (a
   fresh letter in warm-up, the **same letter** in a scored trial) rather than moving on. A
   no-input window ends with a **fresh** letter at the **same** level and a `no input registered`
   row that does not count.
4. Say **"skip"** to one warm-up letter. Expected: it counts as a completed practice letter and the
   next letter follows within ~1 s. In a scored trial a skip records an incorrect `skip` row.
5. During a scored trial, **step out of the band**. Expected: the letter disappears / pauses
   immediately and the microphone stops listening.
6. Step back to just inside the band edge (e.g. 181 cm). Expected: it does **not** resume — the
   inset band requires ~183 cm plus a fresh dwell lock. This is the anti-chatter behavior.
7. Return to ~200 cm and hold. Expected: the **same letter** re-presents.
8. Background the app mid-trial, then foreground it. Expected: paused on return; brightness
   re-locks; resumption still requires a re-lock.
9. Answer wrong through high contrast. Expected: red and teal must **still run**; the results screen
   shows all three conditions and a delta. Nothing is ever skipped automatically.

### 3.5 Spoken prompts, listening, and retry escalation

The audio path is the one area where simulator coverage is weakest — `SilentAnnouncer` proves the
*wiring*, `ListeningBufferRulesTests` prove the *rules*, but only a device proves the *audio
session* and the real voice trace at 2 m. Nothing in this section runs in the simulator.

**Prompts and escalation** (unchanged by the 2026-09-03 listening rework):

| Check | Expected |
| --- | --- |
| Entering each phase | The matching prompt is spoken ("Let's practice…", "Here we go…", "All done. Great job!") |
| While a prompt is playing | Recognition does **not** start — verify the app never transcribes its own voice |
| Drift out of band repeatedly | "Move closer" / "Move farther away" speak on change but do **not** repeat more than once per 5 s |
| Say "um" and then nothing | The first retry speaks "Say the letter you see out loud." with the square blanked; the same letter re-presents when the prompt ends; the second retry is silent |
| Say "skip" | Scored as an incorrect `skip` row; the next letter follows within ~1 s |
| Stay silent during warm-up | Unscored: the first retry re-prompts, the second is silent, then the keypad — the dead-microphone guard |
| Escalate two trials in a row (retry cap, or two no-input backstops) | Manual mode becomes sticky until voice is explicitly restored |
| Deny microphone permission mid-session | `.serviceFailure` escalates **immediately**, with no retry loop |

**Listening rework (2026-09-03) — iPhone at 2 m, Xcode console filtered on `[Whisper]`.** Each row
names the log line that proves it; the "Heard" line at the top of the trial screen (PROTOCOL §7c)
shows the same thing without the console.

| # | Do / say | Expected | Log that proves it |
| ---: | --- | --- | --- |
| 1 | Answer within 0.2 s of the reveal, 10 letters | Every letter scored on the first utterance — never "seat" / "okay" from a truncated first syllable | `mic armed +0.0x s after reveal`, then `live pass on … s (voiced blocks: n): "C." → letter("C")` |
| 2 | Drag the previous answer across the next reveal, then answer the new letter | The first utterance is ignored, the second scored — no bleed between letters | `carried-over voice: skipped N blocks`, then exactly one live pass |
| 3 | Stay silent until ~9.8 s, then answer | Scored for **this** letter — the window must not cut you off while sound is being collected | `deadline deferred +0.25 s (total …)` × n, `live pass … → letter`, `trial #n ended: … after … s` |
| 4 | Whisper faintly | Re-prompt and the **same** letter — never a `no input registered` row for a child who spoke (the trace, not Whisper's text, decides silence) | `live pass … "Thank you." → unrecognized(…unintelligible)` (or the same from `final flush …`), never `final flush skipped` |
| 5 | Quick soft letters ("O", "D") at 2 m | Scored live; note the voiced block count of each answer and tune `voiceSilenceThreshold` if answers show fewer than 2 blocks | `live pass on … s (voiced blocks: n)` |
| 6 | Stay silent for one scored letter | ~10 s later a **fresh letter at the same level** — no re-prompt, no retry; Heard line `Heard nothing (window elapsed)`; the export shows a `no input registered` row with `counts_toward_staircase = 0` | `final flush skipped — no speech-length sound in the window`, `flush resolved: tail unrecognized(…silence) … → unrecognized(…silence)` |
| 7 | Stay silent for three scored letters in a row | The level shown never changes across the three; the **fourth** letter appears on the clinician keypad — this backstop is the only exit from the loop (~30–40 s of silence in total) | Three `trial #n ended: unrecognized(…silence) after … s` lines, then the keypad |
| 8 | TV on, say nothing | The window ends by the cap (≤ ~15 s) as unintelligible → retries → keypad, never hangs open | `deadline deferral cap reached (3.00 s)` |
| 9 | Block start prompt ("Here we go…") | The first letter never transcribes the prompt (with the 0.5 s `listenResumeAfterSpeechSeconds`); if prompt words ever appear inside a session, raise it to 0.75 | No live-pass text resembling the prompt |
| 10 | Say "C" and step out of band; re-lock | No outcome for the paused letter; the re-presented letter is answered normally | `stale pass for session #n dropped`, then a new `session #n start idx=…` |
| 11 | Connect AirPods mid-window; trigger an alarm interruption | Re-armed on the same letter; store indices continue; exactly one engine rebuild | `engine configuration changed; it will be restarted` / `engine stalled … — restarting in place`, one `captureStarted` |
| 12 | Keypad → Restore voice | The letter re-arms with the engine coming up | `mic armed +0.x s after reveal` |
| 13 | A 10-minute block including a 3-minute distance pause, with Xcode's memory gauge open | Memory flat (both buffers are bounded during the pause too); no crash | `capture buffer trimmed after 120 s of audio` roughly every 2 min of audio, incl. during the pause |
| 14 | Face-tracking distance while listening | No freeze — audio-session coexistence (§ 3.7) | — |
| 15 | The Heard line | `Listening…` → `Heard "…" → X ✓` / `✗` → `Heard nothing (window elapsed)`; unreadable from 2 m; never over the optotype or the Back/Next capsules; kept across the letter transition; absent in keypad mode; hidden during a distance pause (the child may approach the phone); the previous letter's result stays visible dimmed with a `Last:` prefix until the current letter produces its own | — |

Cover the mic and let the trials run out: in warm-up the app must escalate to the keypad rather than
re-presenting letters forever — the specific failure mode `RetryEscalationPolicy` exists to prevent
— and in a scored block three `no input registered` rows must hand the fourth letter to the keypad
with the acuity level unchanged, rather than re-presenting fresh letters at that level forever
(silence can no longer fail a line, so this backstop is the only termination guard). A microphone
that never arms at all (model still loading, permission prompt, no audio delivered) must surface as
a `.serviceFailure` alert plus keypad, never as a run of no-input rows.

### 3.6 Speech accuracy

Say each Sloan letter (C D H K N O R S V Z) several times across the high- and low-contrast
conditions and log misrecognitions. Tune by adding phonetic spellings to
`LetterMappingTable.phonetics` — the single source of truth — **not** inside the Whisper service.
Re-run `LetterMappingTableTests` afterwards; the disjointness and Sloan-membership tests will catch
a bad entry.

Say "skip" the same way and log what Whisper transcribed. Mis-hearings go in
`LetterMappingTable.skipPhrases` (tier 1: skip, skipp, skiip, skipped, skips, skipping, skippy,
skype, scip, skep, skup). The tier-2 candidates ski, kip, skit, skid, skiff are deliberately
excluded until device logs show they are real skips rather than fused "S… K" self-corrections — a
false skip is a scored miss, a missed skip only a retry. `testSkipPhrasesNeverCollideWithLetterTables`
and `testSkipPhrasesReachTheMapper` guard a new entry.

### 3.7 Two items known to need device confirmation

1. **Audio-session coexistence.** WhisperKit's `startRecordingLive` applies `.playAndRecord +
   .defaultToSpeaker`; since 2026-09-03 the engine is started once per listening block and kept
   warm across letters (rebuilt in place after a stall, a route change, an interruption, or every
   ~2 min of audio), and the announcer speaks under that session with no category flip. **Symptom:
   the face-tracking distance freezes while the app is listening.** If that happens, re-assert the
   category *after* the engine start (`startEngine` in the service) — ARKit itself never touches
   the audio session. Re-verify after the rework (§ 3.5, check 14).
2. **ARKit stability at 2 m.** The 2 m target is within ARKit's face-tracking envelope but noisier
   than short-range use. If readings are jittery, tune `smoothingWindowSamples`,
   `maxDistanceSDCM`, `validDistanceRangeCM`, or fall back to `ManualClinicianService`.

### 3.8 Results and export

1. Complete a session; confirm the results screen shows both low-contrast results and the delta.
2. Tap Next during a scored condition. Expected: the **"Skip this test?"** dialog appears; *Cancel*
   keeps the same letter up; *Skip* advances and the results detail shows **Skipped** for that
   condition. Next on a warm-up letter still advances immediately, with no dialog.
3. Connect the device and open Finder → *Files* → **Myotect**, or use the Files app.
4. Confirm `MyopiaSessions/<sessionID>.json` and `.csv` exist, that the CSV row count equals the
   number of recorded trials, and that `counts_toward_staircase` (column 20) is `0` on exactly the
   `no input registered` rows. Ambiguous/filler/unintelligible and repeated attempts must **not**
   appear as rows; spoken skips (`skip`, counted) and voice no-inputs (`no input registered`,
   uncounted) **must**, as incorrect rows (unquoted — the values carry spaces but no commas).
5. Confirm screen brightness returns to its pre-test value on completion, abort, and backgrounding.

---

## Part 4 — Verifying physical optotype size

This is the single most important physical check: if the rendered size is wrong, every acuity number
is wrong. A 20/20 optotype subtends 5 arcminutes; the target cap height is
`2 × distance_mm × tan(angle / 2)`.

**Expected cap height at exactly 200 cm:**

| Acuity | Arcmin | Height (mm) | | Acuity | Arcmin | Height (mm) |
| --- | ---: | ---: | --- | --- | ---: | ---: |
| 20/200 | 50.00 | 29.089 | | 20/50 | 12.50 | 7.272 |
| 20/160 | 40.00 | 23.271 | | 20/40 | 10.00 | 5.818 |
| 20/125 | 31.25 | 18.181 | | 20/32 | 8.00 | 4.654 |
| 20/100 | 25.00 | 14.544 | | **20/25** | 6.25 | **3.636** |
| 20/80 | 20.00 | 11.636 | | **20/20** | 5.00 | **2.909** |
| 20/63 | 15.75 | 9.163 | | 20/16 | 4.00 | 2.327 |

**Procedure**

1. Calibrate the screen (automatic on a verified device; otherwise the 50 mm ruler flow).
2. Fix the device at exactly 200 cm — verify with a tape measure, not the app's own reading.
3. Hold a millimetre ruler against the screen and measure the **cap height** (the glyph body, not
   the surrounding square).
4. Compare against the table. 20/25 should measure ~3.6 mm and 20/20 ~2.9 mm.

A consistent proportional error points at the calibration (`pointsPerMillimeter`), not the sizing
math — `OptotypeSizingTests` pins the math and `testPhysicalHeightIsIndependentOfDisplayScale`
specifically guards the `nativeScale` mistake that renders letters ~13 % small.

**Worst-case fit.** The colored square is derived from the coarsest level at the far band edge:
20/200 at 240 cm = **34.907 mm**. On an iPhone 16 Pro (460 ppi, `nativeScale` 3 ⇒ 6.0367 pt/mm)
that is 210.7 pt, so the square is ~234.7 pt against ~350 pt available — comfortable. On a
significantly smaller display the setup screen must block with "This display is too small for the
20/200 letter at 240 cm" rather than cropping mid-trial.

---

## Part 5 — Writing new tests

**Where logic belongs.** Keep decisions in the pure types (`AcuityStaircaseEngine`,
`DistanceStabilityEvaluator`, `DistanceBandGate`, `OptotypeSizing`, `LetterMappingTable`,
`ContrastPalette`, `RetryEscalationPolicy`, and on the speech side `ListeningBufferRules` — when a
pass runs, the consumed pointer, the flush span, carried-over voice, the soft deadline —
`CaptureSampleStore`, `RecognitionFlushRules` (the flush's outcome rules) and
`HeardDiagnosticFormatter`) and wire them in the coordinator or the service. Anything testable
only through a SwiftUI view, or only with a live microphone, is in the wrong place: the WhisperKit
service itself should be a thin caller of those rules, and `WhisperServiceSourcePinsTests` pins
the three WhisperKit accesses it must never regain.

**Determinism levers** — the coordinator takes every source of nondeterminism as an injectable:

| Parameter | Use |
| --- | --- |
| `config:` | A `ScreenConfig`: `recognitionTimeoutSeconds` (assert it on the fake service's recorded timeout — the coordinator is the only place the window flows; the service owns the soft clock), `noInputTrialsBeforeEscalation` (raise it to isolate the uncounted no-input rule from the keypad backstop), `interstimulusBlankSeconds` (zero for the synchronous fast path), `lowContrastWeber`; the listening keys (`utteranceEndQuietSeconds`, `maximumUtteranceSeconds`, `voiceSilenceThreshold`, the deferral step/cap, `capturePurgeKeepSeconds`) reach only the WhisperKit service, so pin them in `ScreenConfigTests` and exercise them through `ListeningBufferRules` directly |
| `distance:` | `MockDistanceProvider` — steady distance or a script of `.distance/.faceLost/.interruption/.failure` |
| `speech:` | The coordinator suites use a private `ScriptedSpeechService` (fires only when the test calls `answer`, records the timeout it was armed with); `MockLetterRecognitionService` — a fixed outcome sequence, or answer-correctly mode — is the simulator's |
| `fallback:` | `ManualClinicianService` — drive keypad escalation without a UI |
| `announcer:` | `PatientAudioPrompting`; defaults to `SilentAnnouncer`, which records prompts synchronously so TTS is assertable without audio |
| `calibration:` | `StaticScreenCalibrationProvider` — validated or deliberately uncalibrated |
| `lowContrastOrderOverride:` | Pins the otherwise-shuffled red/teal order |
| `screenShortSidePoints:` | Forces the display-too-small path |
| `now:` / `sessionID:` / `deviceModel:` / `appVersion:` | Stable session records |

**Conventions**

- Mark coordinator tests `@MainActor` — the coordinator is main-actor isolated and its callbacks use
  `MainActor.assumeIsolated`, which keeps flows synchronous and avoids expectation plumbing.
- Use `ProcessInfo`-style monotonic `TimeInterval` timestamps in distance tests, not `Date`.
- Prefer exercising the pure seam (e.g. `provider.ingest(...)`, `ListeningBufferRules` /
  `CaptureSampleStore` for the WhisperKit listening decisions, `RecognitionFlushRules` for the flush
  outcome) over standing up a real session or a real model.
- After adding a test file: **`xcodegen generate`**.

---

## Part 6 — Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `error: Build input files cannot be found: '.../Foo.swift'` naming a file that does not exist | Stale generated project. **`xcodegen generate`** |
| `xcodebuild: error: Unable to find a destination matching...` / `dvtdevice-DVTiPhonePlaceholder` | The named simulator runtime is not installed — it can zero out destination enumeration. `xcodebuild -downloadPlatform iOS` |
| Long list of destinations printed mid-build | Ambiguous `-destination` (name matches several runtimes). Pin `OS=` |
| "no scheme" / falls back to device placeholder | Build via `-scheme Myotect`, not `-target`; regenerate if the scheme is missing |
| SPM module not found (`DevicePpi`, `WhisperKit`) | You used `-target`. Use `-scheme`. If resolution is broken: `rm -rf ~/Library/Developer/Xcode/DerivedData/Myotect-*` |
| Exit code 0 but tests failed | `xcodebuild test` does not reflect test results in its exit status. Grep for `** TEST FAILED **` |
| Setup screen: "Speech model failed to load" | No vendored model **and** no network. Connect the device or vendor `openai_whisper-base` into `Sources/Resources/WhisperModels/` |
| Model present but not found at runtime | It must be a **folder reference** (`type: folder` in `project.yml`), not part of the source glob — otherwise the `.mlmodelc` tree is flattened into the bundle root and `bundledModelFolderURL()` misses it |
| Setup blocks on "Sloan optotype font loaded" | `Sources/Resources/Sloan.otf` missing from the bundle. Registration is programmatic (`FontRegistrar`) because `GENERATE_INFOPLIST_FILE: YES` makes `UIAppFonts` unreliable |
| Letters look ~13 % too small | Sizing used the logical `scale` instead of `nativeScale`. `testPhysicalHeightIsIndependentOfDisplayScale` guards this |
| Distance freezes while listening | WhisperKit reset the audio-session category — see [3.7](#37-two-items-known-to-need-device-confirmation) |
| Trial pauses constantly at the band edge | Expected hysteresis. Tune `resumeInsetMaxCM` / `resumeInsetFraction` |
| Simulator launch hangs, `launchd failed to respond` | Known-flaky simulator subsystem. `xcrun simctl shutdown all && killall -9 com.apple.CoreSimulator.CoreSimulatorService`, then retry — or use another device/runtime. **Headless `xcodebuild test` is reliable; interactive simulator runs are not.** Do not treat a launch hang as a test failure |
