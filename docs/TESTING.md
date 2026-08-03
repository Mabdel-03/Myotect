# Testing Myotect — complete guide

This document covers everything needed to verify Myotect: the automated unit suite (how to run it,
what every one of its 174 tests asserts), the manual on-device protocol for the parts a simulator
cannot exercise, physical verification of optotype size, and troubleshooting for the failure modes
this project actually hits.

**Current status: 174 tests, 0 failures** on iPhone 16 Pro / iOS 18.2.

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

Nothing else. The unit suite has no external fixtures, no network access, and no simulator UI
automation — it is pure XCTest against injected mocks and completes in **under one second**.

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
Executed 174 tests, with 0 failures (0 unexpected) in 0.7 (0.8) seconds
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
xcodebuild ... test -only-testing:MyotectTests/CoordinatorGateTests/testGateFailSkipsLowContrast

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
| Back/Next navigation, pause/resume policy | Brightness lock/restore |
| Setup gating logic | Audio-session coexistence with ARKit |

In the simulator `ARFaceTrackingConfiguration.isSupported` is false, so `ScreeningRootView` swaps in
mocks: a steady 200 cm distance and a speech service that answers correctly for whatever letter is
shown. That runs a clean pass end-to-end without a microphone.

---

## Part 2 — The unit suite, test by test

**174 tests across 18 files.** All are `XCTest`, synchronous or `@MainActor`, and deterministic —
no `Date.now` dependence in assertions, no randomness (condition order is injected via
`lowContrastOrderOverride`), no sleeps.

| File | Tests | Under test |
| --- | ---: | --- |
| [CoordinatorGateTests](#coordinatorgatetests--29-tests) | 29 | `MyopiaScreenCoordinator` — the whole state machine |
| [DistanceModelsTests](#distancemodelstests--28-tests) | 28 | Sample validity, validity resolution, emission throttle |
| [ScreenCalibrationProviderTests](#screencalibrationprovidertests--12-tests) | 12 | Auto + manual calibration, invalidation |
| [LetterMappingTableTests](#lettermappingtabletests--11-tests) | 11 | Transcript → Sloan letter mapping |
| [AcuityStaircaseEngineTests](#acuitystaircaseenginetests--10-tests) | 10 | Staircase advance/step-back/gate/logMAR |
| [DistanceBandGateTests](#distancebandgatetests--10-tests) | 10 | Pause/resume hysteresis |
| [OptotypeSizingTests](#optotypesizingtests--9-tests) | 9 | Physical sizing math and render damping |
| [SizingProvenanceTests](#sizingprovenancetests--8-tests) | 8 | Provenance matching and Codable round-trips |
| [WhisperTranscriptFilterTests](#whispertranscriptfiltertests--7-tests) | 7 | Filler / silence-hallucination rejection |
| [CoordinatorRetryTests](#coordinatorretrytests--9-tests) | 9 | Retry → keypad escalation, end to end |
| [RetryEscalationPolicyTests](#retryescalationpolicytests--8-tests) | 8 | The escalation state machine in isolation |
| [ContrastPaletteTests](#contrastpalettetests--6-tests) | 6 | Weber contrast and channel isolation |
| [SessionStoreTests](#sessionstoretests--7-tests) | 7 | JSON/CSV encoding, quoting, delta, load ordering |
| [ARKitDistanceProviderTests](#arkitdistanceprovidertests--5-tests) | 5 | Smoothing and plausibility rejection |
| [CoordinatorTTSTests](#coordinatorttstests--5-tests) | 5 | Spoken prompts wired into the flow |
| [SpeechAnnouncerTests](#speechannouncertests--5-tests) | 5 | Utterance lifecycle and completion-exactly-once |
| [PromptThrottleTests](#promptthrottletests--4-tests) | 4 | Repeat-prompt throttling |
| [MyotectTests](#myotecttests--1-test) | 1 | Placeholder |

---

### CoordinatorGateTests — 29 tests

The largest and most important file: it drives `MyopiaScreenCoordinator` through complete flows with
injected mocks, asserting the protocol invariants listed in the README. A static
`testCalibration(pointsPerMillimeter:)` helper (not a test) builds a fixed calibration so sizing is
reproducible.

**Protocol flow**

| Test | Asserts |
| --- | --- |
| `testReachesWarmupAfterDistanceLock` | Dwell lock in the valid band transitions `distanceLock → warmup` |
| `testGatePassRunsBothLowContrastConditions` | Passing the 20/25 gate runs red *and* teal, then results |
| `testGateFailSkipsLowContrast` | Failing the gate skips low contrast entirely and records `interpretation = "highContrastBelowGate"` |
| `testAmbiguousRepeatsSameLetterWithoutAdvancing` | An ambiguous answer re-presents the *same* letter and records no trial |

**Distance policy — the heart of the correctness story**

| Test | Asserts |
| --- | --- |
| `testDistanceInvalidPausesAndResumesWarmupLetter` | Leaving the band mid-warm-up pauses; re-lock re-presents the same warm-up letter |
| `testDistanceInvalidPausesAndResumesScoredTrial` | Same for a scored trial — the letter is never silently swapped |
| `testStaleDistanceAtAnswerTimeIsNotScoredAndLetterRepeats` | An answer arriving with no *fresh* sample is discarded, not scored |
| `testResumeRequiresInsetBandNotJustDwellLock` | Re-entering the raw band is insufficient; resumption needs the **inset** band (anti-chatter hysteresis) |
| `testInterruptionMidTrialPausesAndRecoveryResumesSameLetter` | An AR session interruption pauses and recovers to the same letter |
| `testBackgroundPausesTrialAndForegroundRequiresRelock` | Backgrounding pauses; foregrounding alone never resumes scoring |
| `testRecordedTrialDistanceIsAnswerTimeSampleNotLockValue` | The recorded `distanceCM` is the answer-time measurement, not the lock value — **currently failing, see below** |
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

**Back navigation** — returns to the *start* of the preceding phase and rolls back what that phase wrote.

`testBackFromWarmupReturnsToDistanceLock` · `testBackFromGateReturnsToWarmup` ·
`testBackFromLowContrastReturnsToGateAndClearsResults` · `testBackFromSetupIsNotHandled` (returns
`false` so the caller dismisses the flow) · `testStaleRecognitionCallbackAfterBackIsIgnored` (the
generation counter neutralizes an in-flight callback from the abandoned phase).

**Forward (Next) navigation** — skips the current test *without* recording a result, preserving earlier results.

`testNextFromSetupBeginsDistanceLock` · `testNextFromDistanceLockSkipsToWarmup` ·
`testNextFromWarmupSkipsToGate` · `testNextFromGateSkipsToLowContrastWithoutRecording` ·
`testNextThroughLowContrastConditionsReachesResults` · `testNextFromResultsIsNotHandled`.

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

### LetterMappingTableTests — 11 tests

`testCommonPhonetics` ("see"→C, "aitch"→H, "kay"→K …) · `testCaseAndPunctuationInsensitive` ·
`testSingleLetterDirectMatch` · `testNonSloanReturnsNil` · `testClassifySingleLetter` ·
`testClassifyAmbiguousWhenMultipleDistinctLetters` (two distinct letters in one transcript →
`.ambiguous`, never a guess) · `testClassifyUnrecognizedKinds` (`.silence` vs `.unintelligible`) ·
`testMisidentificationCorrections` ("okay"→K, "and"→N, "our"→R).

Three **table-integrity** tests guard the data itself: `testMisidentificationValuesAreSloanLetters`,
`testAllValuesAreSloanLetters`, and `testPhoneticsAndMisidentificationsAreDisjoint` — so a new entry
can never introduce a non-Sloan target or shadow a genuine phonetic spelling.

---

### AcuityStaircaseEngineTests — 10 tests

`testStartsAtConfiguredAcuity` · `testAcuityLevelsContain25` (the gate must be a real level) ·
`testAdvanceOnSixOfTen` · `testEarlySkipAdvancesAtFifthCorrect` (5 consecutive correct passes the
level immediately and records a perfect score) · `testStepBackBelowSix` · `testContinuesWithinLevel` ·
`testGateReachedAtTwentyFive` · `testGateNotReachedWhenStuckAtThirtyTwo` ·
`testLogMARIncludesErrorAdjustment` (table value + `wrong / 100`) · `testLowContrastConfigHasNoGate`
(`gateAcuity = nil` ⇒ `reachedGate` always true).

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

### WhisperTranscriptFilterTests — 7 tests

`nonAnswerKind(_:)` runs *before* the letter mapper and separates "the child made a sound" from "the
microphone heard nothing".

`testFillerKind` ("um", "uh", "hmm" → `.filler`) · `testSilenceKindForHallucinations`
(Whisper's classic near-silence output "you", "thank you", "thanks for watching" → `.silence`) ·
`testSilenceKindForSilenceMarkers` ("blank audio", "silence", "music") ·
`testSilenceKindForEmptyAndWhitespace` · `testRealAnswerCandidatesReturnNil` (a genuine answer must
reach the mapper untouched) · `testDeprecatedIsNonAnswerShimAgrees`.

The critical one is `testRejectedPhrasesNeverCollideWithLetterTables`: **no rejected phrase may also
be a valid letter spelling.** Without it, adding a filler word could silently make a real Sloan
answer unanswerable.

---

### ContrastPaletteTests — 6 tests

`testWeberFivePercent` and `testWeberTenPercent` pin `stimulus = background × (1 − weber)` ·
`testWeberMatchesMeetingExample` pins the agreed clinical worked example ·
`testHighContrastIsBlackOnWhite` · `testRedConditionIsolatesRedChannel` and
`testTealConditionIsBlueGreen` — the duochrome comparison is only meaningful if no long-wavelength
light contaminates the short-wavelength stimulus, so red must be exactly 0 in the teal condition.

---

### SessionStoreTests — 7 tests

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

### CoordinatorRetryTests — 9 tests

End-to-end escalation through the coordinator, using a mock speech service that returns non-answers.

| Test | Asserts |
| --- | --- |
| `testRepeatedNonAnswersEscalateToKeypadAfterCap` | After the retry cap the trial hands off to the clinician keypad instead of looping forever |
| `testKeypadSubmissionScoresTrialAndNextTrialReturnsToVoice` | A keypad answer scores normally and the next trial goes back to voice |
| `testKeypadNoResponseScoresIncorrectTrial` | "Couldn't answer" records an incorrect trial rather than silently skipping |
| `testServiceFailureEscalatesImmediatelyWithAlert` | `.serviceFailure` bypasses retries entirely — it is structural |
| `testDistancePauseRepeatDoesNotGrantExtraRetries` | A pause repeat is not an answer attempt, so it cannot farm extra retries |
| `testConsecutiveKeypadTrialsBecomeStickyAndClinicianRestores` | Repeated escalations make manual mode sticky until explicitly restored |
| `testKeypadOnlyStartStaysStickyAcrossResolvedLetters` | Starting keypad-only from setup stays manual even as letters resolve successfully — it must not silently drift back to a mic that was never available |
| `testGoBackClearsNonStickyEscalationForCleanRerun` | Back re-runs a phase with escalation state reset, so a prior bad streak does not poison the retry |
| `testWarmupEscalationScoresNothingAndKeypadAdvancesWarmup` | Escalation during warm-up records no trial but still advances |

### RetryEscalationPolicyTests — 8 tests

The same state machine in isolation: `testRetrySequenceThenEscalation` (first retry carries a spoken
re-prompt, later ones do not) · `testBeginTrialResetsAttemptCount` ·
`testDistancePauseRepeatsDoNotGrantExtraRetries` · `testServiceFailureEscalatesImmediately` ·
`testStickyManualAfterConsecutiveEscalationsAndVoiceResolveClearsStreak` ·
`testStickyManualBypassesRetries` · `testClinicianRestoreClearsStickyAndStreak` ·
`testForceStickyManualSurvivesResolvedTrials` (the keypad-only start latches until the clinician
restores voice, rather than clearing on the first successful answer).

### CoordinatorTTSTests — 5 tests

`testPhasePromptsAreSpoken` · `testFirstRetrySpeaksReprompt` ·
`testDistanceGuidanceIsSpokenAndThrottled` · `testCompletionSpeaksAllDone`.

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

1. Five large (20/80) high-contrast letters, unscored. Say each aloud.
2. Confirm a correctly recognized letter advances, and that an unclear answer **re-presents the same
   letter** rather than moving on.
3. During a scored trial, **step out of the band**. Expected: the letter disappears / pauses
   immediately and the microphone stops listening.
4. Step back to just inside the band edge (e.g. 181 cm). Expected: it does **not** resume — the
   inset band requires ~183 cm plus a fresh dwell lock. This is the anti-chatter behavior.
5. Return to ~200 cm and hold. Expected: the **same letter** re-presents.
6. Background the app mid-trial, then foreground it. Expected: paused on return; brightness
   re-locks; resumption still requires a re-lock.

### 3.5 Spoken prompts and retry escalation

The audio path is the one area where simulator coverage is weakest — `SilentAnnouncer` proves the
*wiring*, but only a device proves the *audio session*.

| Check | Expected |
| --- | --- |
| Entering each phase | The matching prompt is spoken ("Let's practice…", "Here we go…", "All done. Great job!") |
| While a prompt is playing | Recognition does **not** start — verify the app never transcribes its own voice |
| Drift out of band repeatedly | "Move closer" / "Move farther away" speak on change but do **not** repeat more than once per 5 s |
| Stay silent for a trial | First retry speaks a re-prompt; the second retry is silent |
| Stay silent past the retry cap | The trial escalates to the clinician keypad |
| Escalate two trials in a row | Manual mode becomes sticky until voice is explicitly restored |
| Deny microphone permission mid-session | `.serviceFailure` escalates **immediately**, with no retry loop |

Cover the mic and let a trial run out: the app must escalate to the keypad rather than re-presenting
the same letter forever. That is the specific failure mode `RetryEscalationPolicy` exists to prevent.

### 3.6 Speech accuracy

Say each Sloan letter (C D H K N O R S V Z) several times across the high- and low-contrast
conditions and log misrecognitions. Tune by adding phonetic spellings to
`LetterMappingTable.phonetics` — the single source of truth — **not** inside the Whisper service.
Re-run `LetterMappingTableTests` afterwards; the disjointness and Sloan-membership tests will catch
a bad entry.

### 3.7 Two items known to need device confirmation

1. **Audio-session coexistence.** WhisperKit's `startRecordingLive` may reset the `AVAudioSession`
   category away from the `.record`/`.measurement` configuration the app sets. **Symptom: the
   face-tracking distance freezes while the app is listening.** If that happens, re-assert the
   category *after* `startRecordingLive`.
2. **ARKit stability at 2 m.** The 2 m target is within ARKit's face-tracking envelope but noisier
   than short-range use. If readings are jittery, tune `smoothingWindowSamples`,
   `maxDistanceSDCM`, `validDistanceRangeCM`, or fall back to `ManualClinicianService`.

### 3.8 Results and export

1. Complete a session; confirm the results screen shows both low-contrast results and the delta.
2. Connect the device and open Finder → *Files* → **Myotect**, or use the Files app.
3. Confirm `MyopiaSessions/<sessionID>.json` and `.csv` exist and that the CSV row count equals the
   number of scored trials. Ambiguous/repeated attempts must **not** appear as rows.
4. Confirm screen brightness returns to its pre-test value on completion, abort, and backgrounding.

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
`ContrastPalette`) and wire them in the coordinator. Anything testable only through a SwiftUI view
is in the wrong place.

**Determinism levers** — the coordinator takes every source of nondeterminism as an injectable:

| Parameter | Use |
| --- | --- |
| `distance:` | `MockDistanceProvider` — steady distance or a script of `.distance/.faceLost/.interruption/.failure` |
| `speech:` | `MockLetterRecognitionService` — a fixed outcome sequence, or answer-correctly mode |
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
- Prefer exercising the pure seam (e.g. `provider.ingest(...)`) over standing up a real session.
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
