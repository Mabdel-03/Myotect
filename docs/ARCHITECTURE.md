# Architecture

Myotect is SwiftUI-first. ARKit and UIKit are confined to the distance provider and a handful of
platform shims; **all protocol logic is view-agnostic and unit tested**. The rule of thumb: if a
behavior can only be tested by driving a SwiftUI view, it is in the wrong layer.

```
                         ┌─────────────────────────┐
                         │   ScreeningRootView     │  picks providers, renders per phase
                         └───────────┬─────────────┘
                                     │ @StateObject
                         ┌───────────▼─────────────┐
                         │ MyopiaScreenCoordinator │  @MainActor, ObservableObject
                         │  owns session + phase   │  the ONLY stateful orchestrator
                         └─┬────┬────┬────┬────┬───┘
           ┌───────────────┘    │    │    │    └───────────────┐
           ▼                    ▼    ▼    ▼                    ▼
  DistanceProvider   AcuityStaircaseEngine   PatientAudioPrompting   LetterRecognitionService
  (ARKit | Mock)     OptotypeSizing          (SpeechAnnouncer)       (WhisperKit | Manual | Mock)
                     ContrastPalette         PromptThrottle
                     ScreenCalibrationProviding
                     RetryEscalationPolicy
                     SessionStore
```

---

## Layers

### Models — plain data

`MyopiaScreenSession` (the whole record, `Codable`), `TrialResult` (one recorded trial — counted
or, for a voice no-input, uncounted), `AcuityConditionResult` (per-condition summary),
`ColorCondition`, `ScreenPhase`, `SloanLetter`.

Newer fields (`calibration`, `sizingDistanceCM`, `provenance`, `countsTowardStaircase`) are
optional specifically so pre-upgrade session JSON still decodes.

### Engine — the staircase

`AcuityStaircaseEngine` is a deterministic, UI-agnostic state machine. You feed it one
`record(correct:)` at a time and it returns `continueSameLevel` / `advance` / `stepBack` /
`finished`. It holds no timing, no view, and no distance concepts.

Ported from the sibling Distance Measure Test app's `processNextTrial` (transitions) and
`calculateScore` (logMAR + per-error adjustment).

### Services — sizing, calibration, color, persistence

- **`OptotypeSizing`** — the physical-size core. Converts a measured distance plus a Snellen
  denominator into an `OptotypeRenderSpec` (target angle, target height in mm, rendered height in
  points, font point size). Uses the exact chord `2·d·tan(θ/2)`, and derives point size from the
  **live font's** cap-height ratio rather than a hand-tuned multiplier. Also owns `needsRender`,
  the half-physical-pixel damping rule.
- **`ScreenCalibrationProvider`** — resolves points-per-millimeter, automatically from DevicePpi
  (`ppi / nativeScale / 25.4`) or from an operator ruler measurement persisted in `UserDefaults`.
  Injected as `ScreenCalibrationProviding`, never a singleton.
- **`ContrastPalette`** — Weber contrast pairs, `stimulus = background × (1 − weber)`.
- **`ScreeningSettingsProvider`** — operator settings (5/10/15/20 % Weber choice, default 20 %;
  audio prompts) in UserDefaults under `schemaVersion` 2, self-invalidating on read: an invalid
  weber or unknown schema is deleted on sight, while a schema-1 record is **upgraded** on read
  (audio kept; the old implicit 10 % default moves to 20 %; an explicit 5/15 % is kept) and
  re-persisted as v2 without a change notification. Sampled into the flow's `ScreenConfig` at
  launch through `ScreenConfig(settings:)`, the only settings → config seam.
- **`Sources/Theme/`** — the Visinear-format design system (colors, text styles, buttons, pills,
  cards, decorative daisies) shared by every screen; trial stimulus rendering does not use it.
- **`SessionStore`** — JSON + CSV to `Documents/MyopiaSessions/`.
- **`BrightnessController`** — locks test brightness, restores the user's value on completion,
  abort, and backgrounding.
- **`IdleTimerController`** (`Sources/`, not `EarlyMyopiaScreen/`) — keeps the display awake.
  Same shape as `BrightnessController`, but **app-scoped, not session-scoped**: driven from
  `MyotectApp`'s `scenePhase`, so the menu, calibration, and results screens stay lit too.
- **`FontRegistrar`** — registers `Sloan.otf` programmatically via CoreText.

### Distance — measurement and policy, deliberately separated

`DistanceProvider` implementations only produce clean, validated samples. **All policy lives
outside them**, which is why the policy is exhaustively testable without hardware:

| Type | Responsibility |
| --- | --- |
| `DistanceSample` / `DistanceValidity` | A reading, and an explicit trust verdict with a reason |
| `DistanceStabilityEvaluator` | Dwell-lock policy → `DistanceStatus` guidance (in-trial resume) |
| `DistanceHoldTracker` | Operator-initiated capture: tap-anchored 2 s hold, ±4 cm envelope, mean of the steady window |
| `DistanceBandGate` | Pause/resume hysteresis (full band out, inset band in) |
| `ARKitDistanceProvider` | Real face tracking; smoothing + plausibility rejection |
| `MockDistanceProvider` | Steady or scripted events, for simulator/tests |

Consumption is deliberately **dual push/pull**: the throttled `onUpdate` push drives the
coordinator's reactive state, while `validity(maximumAge:now:)` is pulled at decision points
(sizing, answer scoring) so those never read a cached callback value.

### Speech — one letter per trial

`LetterRecognitionService` is a three-method protocol (`isAvailable`, `recognizeOneLetter`,
`cancel`) with three implementations: `WhisperKitLetterRecognitionService` (production, on-device
Whisper), `ManualClinicianService` (clinician keypad fallback), and `MockLetterRecognitionService`
(tests/simulator; past the end of its script it answers `.unrecognized(.unintelligible)` — a
retrying non-answer, never `.silence`, which the voice path would record as an uncounted row and
replace with a fresh letter).

`LetterMappingTable` is the **single source of truth** for transcript → Sloan letter, shared by every
implementation. `WhisperTranscriptFilter` sits in front of it to reject filler and Whisper's
near-silence hallucinations before they can be mistaken for answers.

Recognition outcomes distinguish five cases, and the difference matters:
`.letter` · `.skipped` · `.ambiguous` · `.unrecognized(NonAnswerKind)` · `.serviceFailure`.
`.skipped` (a spoken "skip"; vocabulary in `LetterMappingTable.skipPhrases`) resolves the trial like
a letter does: scored as a miss, never retried. `NonAnswerKind` is `.filler` / `.unintelligible`
(retry) or `.silence`, which means **no speech-length sound and no usable text in the whole window
from an armed microphone** and on the scored voice path is RECORDED as a `no input registered` row
that does **not** count toward the staircase (`TrialResult.countsTowardStaircase = false`; since
2026-09-03) — the level does not move and a fresh letter replaces it. `.serviceFailure` is
structural (permissions, model, capture) — repeating the letter cannot fix it, so it must never be
retry-looped.

The WhisperKit service's listening design is ported (since 2026-09-03) from the sibling ETDRS app's
`ETDRSWhisperLetterService` — the version that is robust on device — behind Myotect's one-shot
contract: each `recognizeOneLetter` opens a *session* on a continuously running capture engine
(`ContinuousCaptureControlling`: one engine per listening block, kept warm between letters,
restarted in place once per trial if it stalls, and — with the engine briefly paused, never
rebuilt — emptied of WhisperKit's own buffer once it holds `captureBufferTrimAfterSeconds` of audio,
between letters or during a pause; the first voice letter after a keypad escalation re-opens the
block's session from `listen()`). The decisions live in two pure
types so they are unit-testable without a microphone:

- **`CaptureSampleStore`** — the service's own lock-protected 16 kHz sample store, fed by
  WhisperKit's tap callback and the **only** audio the service ever reads. WhisperKit's
  `audioSamples` is appended on the tap thread without a lock and emptied by every engine start,
  so reading or trimming it from the main actor is a data race that also resets every index;
  `WhisperServiceSourcePinsTests` pins that the service never touches it, `purgeAudioSamples`, or
  WhisperKit's per-tap-buffer voice heuristic. Indices are absolute and block-aligned —
  `baseIndex` never decreases and `purge` drops whole 100 ms blocks — so engine stops and starts
  are just gaps in one continuous index space, and per-block RMS energies are computed
  incrementally on the tap thread as blocks complete.
- **`ListeningBufferRules`** — a port of `ETDRSListeningBufferRules` plus Myotect's additions: the
  voice trace (`relativeEnergies`: dB relative to the quietest of the previous 2 s, blocks below
  −80 dBFS never the reference; `voiceBlocks` at `voiceSilenceThreshold`; `maskingEngineStart`:
  the block an engine start lands in, and the next, are zeroed so a ramp-in buffer is neither a
  reference nor voice), when a live pass runs
  (`shouldRunLivePass`: voice in the unconsumed span AND a quiet `utteranceEndQuietSeconds` tail,
  or `maximumUtteranceSeconds` of continuous sound — never on a first syllable), how the consumed
  pointer moves (`consumedSampleCount`: an answer or the final flush consumes everything; any
  other pass keeps the newest 0.3 s so a straddling onset survives; never backwards), the live
  window (`windowStart`), the flush span (`flushSpan`: only speech-length runs — two consecutive
  voice blocks — padded 0.5 s, nil when there are none), the carried-over-voice rule
  (`carriedOverBlocks`: a run already sounding in the session's first block began before the
  child could see the letter and is skipped, capped by the utterance maximum), and the soft
  deadline (`shouldDeferDeadline`).

Because a no-input row is visible in every export and its backstop is the only exit from a
same-level loop, the service may only say `.silence` when the voice trace held no speech-length
sound AND no usable text. The contract: the session start index is minted synchronously at the
reveal — in the same main-actor turn, before any `await` — so nothing recorded before the reveal is
ever transcribed and the tail of the previous answer can never be scored for the next letter; the
caller's timeout is first an arming deadline (a microphone that never delivered audio reports
`.serviceFailure`, never silence) and then, from the first block after the reveal, the listening
window; the window is **soft** — while the tail is voice or a decode is in flight it defers in
`deadlineDeferralStepSeconds` steps up to `deadlineDeferralCapSeconds`, then drains the in-flight
decode (≤ 1.5 s, it may be the late answer) and flushes; the flush decodes only the speech-length
runs, or nothing at all; `RecognitionFlushRules` (kept beside the service) upgrades a silence
classification over a real sound to `.unintelligible` (`upgradedForTrace`), remembers the
strongest non-answer heard during the trial (`strongerEngagement`) and substitutes it for a silent
tail (`resolveFinalOutcome`); audio that could not be inspected reports `.unintelligible`; and live
answers are trusted as they arrive, because the live gate already requires an acoustic event that
ended. The service also publishes a `RecognitionDiagnostic` stream (`RecognitionDiagnosticsProviding`:
listening / heard / deferred deadline / flushed silent) that the coordinator mirrors into
`lastHeard` through the pure `HeardDiagnosticFormatter` for the operator "Heard" line — display
only, never a scoring input.

### Audio — patient-facing prompts

`PatientAudioPrompting` (implemented by `SpeechAnnouncer`, on `AVSpeechSynthesizer`) speaks a
**closed catalog** of `SpokenPrompt` values — "Say the letter you see.", "Move closer.",
"Hold still.", "All done. Great job!" — so the coordinator, the throttle, and the tests share one
vocabulary.

Two rules make this safe to run alongside recognition:

- **Recognition never runs while the app is speaking.** The coordinator gates `listen()` on
  `isSpeaking` and resumes after `.finished`. Critically, `isSpeaking` covers the *pre-speech*
  window while the audio session switches category and settles — not just the utterance itself —
  because that gap is exactly when a microphone would otherwise capture the app's own voice.
- **`setMicrophoneCaptureActive(_:)`** is called by the coordinator around the capture session:
  WhisperKit's `startRecordingLive` applies `.playAndRecord + .defaultToSpeaker`, and while that
  session is live the announcer speaks **under** it with no category flip (the prompt's echo lies
  before the recognition session start and is never inspected, which is why
  `listenResumeAfterSpeechSeconds` is only 0.5 s); outside a capture session the next `speak`
  knows a real category switch plus settle delay is needed.

Completions fire **exactly once** even when an utterance is superseded or stopped, guarded by a
generation counter — the same discipline used for recognition callbacks.

`PromptThrottle` is a pure, clock-injected repeat filter: a *different* prompt speaks immediately, the
*same* prompt repeats only after `minInterval` (5 s default). It keeps distance guidance from
becoming a chant while still reacting instantly when the guidance actually changes.

### Retry and escalation

`RetryEscalationPolicy` is a pure value type owned by the coordinator, one instance per session. It
exists to guarantee that **a dead microphone can never produce a silent infinite re-present loop**:

- A non-answer (`.ambiguous` / `.unrecognized(.filler | .unintelligible)`) earns up to
  `maxAutoRetriesPerTrial` same-letter retries — the first with a spoken re-prompt, during which the
  square is blanked and the letter re-presents in the prompt's completion; later ones silent — then
  escalates to the clinician keypad.
- Voice `.unrecognized(.silence)` on a scored trial is **not** a retry: the coordinator
  (`handleScoredOutcome` → `score(countsTowardStaircase: false)`) records a `no input registered`
  row that the engine never sees and presents a fresh letter at the same level (same
  `trialNumber` slot, fresh retry budget). Warm-up keeps the retry → keypad path for silence — that
  is the dead-microphone guard.
- **No-input backstop.** After `ScreenConfig.noInputTrialsBeforeEscalation` (3) consecutive voice
  trials ended by the no-input window, the next presentation goes to the keypad
  (`escalateCurrentPresentation`), counted as an escalation via
  `RetryEscalationPolicy.noteNoInputEscalation()`. Any spoken letter, skip, or keypad entry resets
  the count. A no-input row does **not** clear the consecutive-escalation streak (`score` passes
  `provesVoicePath: false` — silence proves nothing about the voice path), so two no-input
  escalations in a row make manual mode sticky. Since 2026-09-03 this is the only guard against an
  unbounded same-level loop on the voice path.
- `.serviceFailure` escalates **immediately**; it is structural, so retrying cannot help.
- After `stickyManualAfterConsecutiveEscalations` consecutive escalated trials, manual mode becomes
  sticky until the clinician explicitly restores voice input.
- **A distance-pause repeat is not an answer attempt** and deliberately does not reset the attempt
  count, so pausing cannot be used to farm extra retries.
- `forceStickyManual()` supports a **keypad-only start** from setup (mic denied or model failed):
  manual mode latches from the first trial and survives resolved letters, so a session begun without
  a usable microphone never silently drifts back to voice.

### Coordinator — the only stateful orchestrator

`MyopiaScreenCoordinator` is `@MainActor` and owns the phase, the session record, and every
transition. Provider callbacks are contractually main-thread, so it uses
`MainActor.assumeIsolated` rather than a deferred `Task` — keeping the flow synchronous and
deterministic for tests.

`ScreenConfig` holds every tunable in one struct (see [PROTOCOL.md](PROTOCOL.md)).

### Views — thin

`ScreeningRootView` picks providers (real on TrueDepth hardware, mocks otherwise), switches on
`coordinator.phase`, and forwards scene-phase changes. Each phase has one view. Shared Back/Next
controls call `goBack()` / `goNext()` on the coordinator. On the three scored phases the root view
first shows a skip-confirmation dialog (keyed off `ScreenPhase.scoredCondition`) and calls `goNext()`
only on Skip; Cancel leaves the trial exactly as it was. Next on distanceLock and warmup stays
immediate. In voice mode `AcuityTrialView` shows the operator "Heard" line (`HeardDiagnosticLine`)
at the top of the trial screen — below the Back/Next capsules, never over the optotype; at caption
size it subtends ≈2 arcmin at 2 m, so the child cannot read it. It only mirrors
`coordinator.lastHeard` / `listeningStatus` and never scores; it is hidden during a distance pause
(the child may approach the phone), and a result kept over from the previous letter is dimmed with
a `Last:` prefix until the current letter produces its own. `WarmupView` places the same line
beneath its warm-up pill, and manual/keypad mode keeps the bottom operator strip instead.

---

## The state machine

```
setup ──Begin──▶ distanceLock ──capture hold──▶ warmup ──5 letters──▶ highContrastGate
                                                                             │
                     staircase done (20/25 result recorded, never a branch)  │
                                                                             ▼
                                        results ◀──both conditions done── lowContrast(red|teal)
```

The 20/25 level survives only as an analysis field: the high-contrast result records `reachedGate`
(finest passed line 20/25 or finer) and anchors the low-contrast starting level, but both
low-contrast conditions always run, and interpretation stays `notComputed` until both have results.

`goBack()` returns to the **start** of the preceding phase and rolls back what the abandoned phase
wrote. `goNext()` skips the current test **without recording a result**, preserving earlier ones; on
a scored phase the root view confirms before calling it. Both return `false` on a terminal phase so
the caller can dismiss.

### Pause and resume

Any of: leaving the valid band, losing the face, a stale sample, an AR interruption/failure, or
backgrounding → `isPausedForDistance = true` and in-flight recognition is cancelled.

Resuming requires **both**:
1. the distance to re-enter the *inset* resume band (`DistanceBandGate`), and
2. a fresh dwell re-lock (`DistanceStabilityEvaluator`).

Then the **same letter** re-presents. Foregrounding alone never resumes scoring.

---

## Why the design is shaped this way

Each of these is enforced in code and pinned by a test:

**A scored letter is never sized from an assumed distance.** `sizedSpec` uses a fresh valid sample
from the provider (never older than `maximumSampleAgeSeconds`) — there is deliberately no
nominal-distance fallback and no cached-sample fallback. If no trusted sample exists, the
presentation pauses rather than showing a letter of unknown angular size.

**An answer is scored only against a fresh, in-band sample at answer time.** If the measurement
lapsed between presentation and response, the answer cannot be trusted; the trial pauses and repeats.

**Sizing provenance is re-validated against the live calibration before scoring.** Every
`OptotypeRenderSpec` carries a `SizingProvenance` (sizing version, calibration source,
points-per-mm, screen signature, target mm, rendered points). A mid-session calibration change
pauses rather than mis-scoring, and the provenance is written into every trial row.

**A damped re-size candidate never overwrites the visible spec.** Because only rendered specs are
published, the recorded provenance is by construction a description of what was actually on screen.

**A letter is never cropped.** The colored square is derived once per session from the worst case
(coarsest level at the far band edge). If that cannot fit the display, setup blocks — a structurally
invalid device/protocol combination must fail before the session, never mid-trial.

**Calibration is bound to exact hardware.** A stored manual calibration whose screen signature,
native scale, or schema version no longer matches is deleted on sight so it can never resurface.

**`nativeScale`, not `scale`.** On downsampled Plus-class displays the logical scale renders
optotypes ~13 % undersized — a systematic acuity overestimate of about one full line.

**Font failure is loud.** A silent system-font fallback would render non-optotype glyphs and
invalidate the entire test, so `FontRegistrar` exposes its status, setup gates on it, and
`OptotypeSizing.sloanBaseFont()` throws as a runtime backstop.

**A trial nobody answered never moves the staircase.** A voice no-input is recorded with
`countsTowardStaircase = false`, `engine.record` is not called, and a fresh letter is presented at
the same level; the 3-in-a-row keypad backstop is the only exit. And the service may only report
that silence when its own voice trace held no speech-length sound — a child who spoke retries.

---

## Threading

- The coordinator and `WhisperKitLetterRecognitionService` are `@MainActor`; every piece of the
  recognizer's mutable state is touched only there. The one object shared with WhisperKit's audio
  tap thread is the recognizer's `CaptureSampleStore`, guarded by an `OSAllocatedUnfairLock`: the
  tap only appends (and computes block energies), the main actor only snapshots, copies, and
  purges. The service never reads WhisperKit's own unlocked buffer.
- `DistanceProvider.onUpdate` and recognition completions are contractually main-thread.
- Recognition uses a `didComplete` guard plus an internal `generation` counter, bumped on every
  `recognizeOneLetter` / `cancel()`, so a callback, pass, or deadline from a superseded trial
  becomes a no-op; tap-driven passes read `armedSessionToken` at execution, and a pass that
  outlives its trial is dropped after its `await` so it never writes the next trial's consumed
  pointer. One inference slot (`isRunningInference`) is set only by a pass and cleared only by
  that pass's `defer`, so two decodes never overlap; `cancel()` cancels the in-flight decode so it
  aborts in milliseconds instead of blocking the next trial. The coordinator keeps its own
  `recognitionGeneration` for the same reason at the flow level; `teardown()` routes through
  `cancelRecognition()` so that generation bumps too, and a service callback already dispatched to
  the main queue cannot score into a torn-down session.

## Provenance of ported logic

Ported from the sibling `VisualAcuityTest/Distance Measure Test` (UIKit near-vision app):
ARKit eye-transform distance tracking, ETDRS optotype sizing, the acuity staircase, the phonetic
mapping table, and `Sloan.otf`. WhisperKit integration is ported from that repo's
`ETDRSWhisperLetterService`: since 2026-09-03 the listening-buffer design itself is adopted rather
than adapted — `ListeningBufferRules` is a port of `ETDRSListeningBufferRules` (own per-100 ms block
energies, transcribe only once the utterance has ended, the consumed pointer with its retained tail,
the warm engine with a stall watchdog) — wrapped in Myotect's one-shot-per-trial contract with four
additions for a 2 m, one-letter-at-a-time test: a session start minted synchronously at the reveal,
the carried-over-voice rule (the mirror image of the ETDRS pre-roll, which reaches *back* for an
onset because that app arms after the letter is drawn), a trace-decided silence whose flush decodes
only speech-length runs, and the soft deadline.

Myotect's protocol differs: it is a **distance** test (~2 m, not near), **voice**-driven (not
swipes), uses **letters** (not Landolt C), and adds a high-contrast staircase followed by randomized
low-contrast duochrome conditions that always run; the 20/25 level is recorded on the high-contrast
result (`reachedGate`) but does not gate them.
