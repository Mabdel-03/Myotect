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

`MyopiaScreenSession` (the whole record, `Codable`), `TrialResult` (one scored trial),
`AcuityConditionResult` (per-condition summary), `ColorCondition`, `ScreenPhase`, `SloanLetter`.

Newer fields (`calibration`, `sizingDistanceCM`, `provenance`) are optional specifically so
pre-upgrade session JSON still decodes.

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
- **`SessionStore`** — JSON + CSV to `Documents/MyopiaSessions/`.
- **`BrightnessController`** — locks test brightness, restores the user's value on completion,
  abort, and backgrounding.
- **`FontRegistrar`** — registers `Sloan.otf` programmatically via CoreText.

### Distance — measurement and policy, deliberately separated

`DistanceProvider` implementations only produce clean, validated samples. **All policy lives
outside them**, which is why the policy is exhaustively testable without hardware:

| Type | Responsibility |
| --- | --- |
| `DistanceSample` / `DistanceValidity` | A reading, and an explicit trust verdict with a reason |
| `DistanceStabilityEvaluator` | Dwell-lock policy → `DistanceStatus` guidance |
| `DistanceBandGate` | Pause/resume hysteresis (full band out, inset band in) |
| `ARKitDistanceProvider` | Real face tracking; smoothing + plausibility rejection |
| `MockDistanceProvider` | Steady or scripted events, for simulator/tests |

Consumption is deliberately **dual push/pull**: the throttled `onUpdate` push drives the
coordinator's reactive state, while `validity(maximumAge:now:)` is pulled at decision points
(sizing, answer scoring) so those never read a cached callback value.

### Speech — one letter per trial

`LetterRecognitionService` is a three-method protocol (`isAvailable`, `recognizeOneLetter`,
`cancel`) with four implementations: `WhisperKitLetterRecognitionService` (production, on-device
Whisper), `ManualClinicianService` (clinician keypad fallback), `MockLetterRecognitionService`
(tests/simulator), and `AppleSpeechRecognitionService` (kept as a revert path, currently unused).

`LetterMappingTable` is the **single source of truth** for transcript → Sloan letter, shared by every
implementation. `WhisperTranscriptFilter` sits in front of it to reject filler and Whisper's
near-silence hallucinations before they can be mistaken for answers.

Recognition outcomes distinguish four cases, and the difference matters:
`.letter` · `.ambiguous` · `.unrecognized(NonAnswerKind)` · `.serviceFailure`. The last is
structural (permissions, model, capture) — repeating the letter cannot fix it, so it must never be
retry-looped.

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
- **`noteMicrophoneCaptureActive()`** is called by the recognition side after WhisperKit
  reconfigures the session to `.playAndRecord`, so the next `speak` knows a real category switch
  plus settle delay is needed rather than assuming the cached category still holds.

Completions fire **exactly once** even when an utterance is superseded or stopped, guarded by a
generation counter — the same discipline used for recognition callbacks.

`PromptThrottle` is a pure, clock-injected repeat filter: a *different* prompt speaks immediately, the
*same* prompt repeats only after `minInterval` (5 s default). It keeps distance guidance from
becoming a chant while still reacting instantly when the guidance actually changes.

### Retry and escalation

`RetryEscalationPolicy` is a pure value type owned by the coordinator, one instance per session. It
exists to guarantee that **a dead microphone can never produce a silent infinite re-present loop**:

- A non-answer (`.unrecognized` / `.ambiguous`) earns up to `maxAutoRetriesPerTrial` same-letter
  retries — the first with a spoken re-prompt, later ones silent — then escalates to the clinician
  keypad.
- `.serviceFailure` escalates **immediately**; it is structural, so retrying cannot help.
- After `stickyManualAfterConsecutiveEscalations` consecutive escalated trials, manual mode becomes
  sticky until the clinician explicitly restores voice input.
- **A distance-pause repeat is not an answer attempt** and deliberately does not reset the attempt
  count, so pausing cannot be used to farm extra retries.

### Coordinator — the only stateful orchestrator

`MyopiaScreenCoordinator` is `@MainActor` and owns the phase, the session record, and every
transition. Provider callbacks are contractually main-thread, so it uses
`MainActor.assumeIsolated` rather than a deferred `Task` — keeping the flow synchronous and
deterministic for tests.

`ScreenConfig` holds every tunable in one struct (see [PROTOCOL.md](PROTOCOL.md)).

### Views — thin

`ScreeningRootView` picks providers (real on TrueDepth hardware, mocks otherwise), switches on
`coordinator.phase`, and forwards scene-phase changes. Each phase has one view. Shared Back/Next
controls call `goBack()` / `goNext()` on the coordinator.

---

## The state machine

```
setup ──Begin──▶ distanceLock ──lock──▶ warmup ──5 letters──▶ highContrastGate
                                                                    │
                                            ┌───gate failed─────────┤
                                            ▼                       │ gate passed (20/25)
                                        results ◀──────────┐        ▼
                                            ▲              └── lowContrast(red|teal)
                                            └──────both conditions done──┘
```

`goBack()` returns to the **start** of the preceding phase and rolls back what the abandoned phase
wrote. `goNext()` skips the current test **without recording a result**, preserving earlier ones.
Both return `false` on a terminal phase so the caller can dismiss.

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

**A scored letter is never sized from an assumed distance.** `sizedSpec` uses a fresh valid sample or
the last sample the provider vouched for — there is deliberately no nominal-distance fallback. If
neither exists, the presentation pauses rather than showing a letter of unknown angular size.

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

---

## Threading

- The coordinator and `WhisperKitLetterRecognitionService` are `@MainActor`.
- `DistanceProvider.onUpdate` and recognition completions are contractually main-thread.
- Recognition uses a `didComplete` guard plus an internal `generation` counter, bumped on every
  `cancel()`, so a callback from a superseded trial becomes a no-op. The coordinator keeps its own
  `recognitionGeneration` for the same reason at the flow level.

## Provenance of ported logic

Ported from the sibling `VisualAcuityTest/Distance Measure Test` (UIKit near-vision app):
ARKit eye-transform distance tracking, ETDRS optotype sizing, the acuity staircase, the phonetic
mapping table, and `Sloan.otf`. WhisperKit integration is ported from that repo's
`ETDRSWhisperLetterService`, adapted from a continuous/streaming model to Myotect's one-shot-per-trial
contract.

Myotect's protocol differs: it is a **distance** test (~2 m, not near), **voice**-driven (not
swipes), uses **letters** (not Landolt C), and adds a high-contrast 20/25 gate before randomized
low-contrast duochrome conditions.
