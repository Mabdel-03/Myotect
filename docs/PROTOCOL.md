# The screening protocol

> Myotect is a research screening instrument. It does not diagnose an eye condition and does not
> encode a clinically validated diagnostic threshold.

Every parameter below lives in `ScreenConfig`
([Sources/EarlyMyopiaScreen/Coordinator/ScreenConfig.swift](../Sources/EarlyMyopiaScreen/Coordinator/ScreenConfig.swift)),
so the clinical team can adjust distances, contrast, the gate, and the letter set without touching
logic.

---

## 1. Setup — seven pre-flight checks

*Begin* stays disabled until all pass. Calibration, the optotype font, and display fit are hard
requirements **even under mocks**, because sizing correctness does not depend on which providers are
live.

1. Distance tracking available (`ARFaceTrackingConfiguration.isSupported`)
2. Camera permission
3. Microphone permission
4. Speech model ready (`WhisperKit` `modelState == .ready`) — so the first letter meets a warm model
5. Screen calibrated
6. Sloan optotype font loaded
7. Display fits the protocol's worst-case letter

If the **voice** path alone is blocked — microphone denied, or the speech model failed to load —
but every sizing prerequisite is met, setup offers **"Continue with clinician keypad"**, which
starts the session in sticky manual mode. Calibration, the optotype font, display fit, camera, and
face tracking remain hard requirements: the keypad substitutes for the microphone, never for
correct sizing or distance measurement.

## 2. Distance lock (operator-initiated capture)

The child is guided to the target distance, and the OPERATOR decides when it is right — the
gold-standard user-initiated capture flow. The Capture Distance button arms once a fresh reading
sits inside the valid band; tapping it anchors a steady hold to the tap-instant reading. Any
reading drifting beyond the tolerance from that anchor — or losing the face — voids the hold with
a transient on-screen notice ("Moved too much — try again" / "Lost your face — try again") and a
matching spoken prompt. Only hold completion advances to warm-up; the mean of every
timestamp-deduped reading across the hold window is recorded on the session as `lockedDistanceCM`.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `targetDistanceCM` | 200 | Nominal test distance |
| `validDistanceRangeCM` | 180…240 | Band required to arm Capture and to keep a trial valid. The 0.9× lower fraction deliberately tightens the reference app's 0.8× — a too-close child inflates measured acuity |
| `providerDistanceRangeCM` | 100…300 | Wider band the provider accepts as *plausible* at all |
| `holdDurationSeconds` | 2.0 | Steady hold after the Capture tap (whole-second countdown shown) |
| `holdToleranceCM` | 4.0 | Max deviation from the tap-instant anchor before the hold voids |
| `captureRetryNoticeSeconds` | 2.5 | How long a void notice stays up before clearing itself |
| `distanceStableWindowSeconds` | 0.75 | Continuous in-band dwell — IN-TRIAL resume re-lock only |
| `maxDistanceSDCM` | 5 | Max standard deviation across the dwell window (in-trial re-lock only) |

Guidance strings: `noFace` → "I can't see you. Step into view." · `tooClose` → "Move farther away" ·
`tooFar` → "Move closer" · `holdSteady` → "Hold still…" · `locked` → "Distance locked".
On the lock screen the pill goes quiet once the subject is in band — the enabled Capture button
speaks for itself.

### Sampling and validity

| Parameter | Default | Meaning |
| --- | --- | --- |
| `maximumSampleAgeSeconds` | 0.5 | Older than this is stale and never trusted for sizing or scoring |
| `distanceUpdateIntervalSeconds` | 0.1 | Throttle for same-kind pushes (~10 Hz); kind changes deliver immediately |
| `trackingLostTimeoutSeconds` | 0.5 | Anchor silence beyond this counts as face lost |
| `smoothingWindowSamples` | 5 | Moving-average window over raw readings |

### In-trial hysteresis

| Parameter | Default | Meaning |
| --- | --- | --- |
| `resumeInsetMaxCM` | 3.0 | Cap on the per-side inset of the resume band |
| `resumeInsetFraction` | 0.25 | Inset as a fraction of band width |

A trial pauses the moment distance leaves the **full** band, and resumes only after re-entering the
**inset** band (`min(3.0, 0.25 × width)` per side — 3 cm for the default band, i.e. 183…237 cm) *and*
completing a fresh dwell lock. A subject hovering at the edge therefore cannot chatter the pause
state at sample rate.

## 3. Warm-up

| Parameter | Default |
| --- | --- |
| `warmupLetterCount` | 5 |
| `warmupAcuity` | 80 (20/80) |

Unscored high-contrast letters so the child learns the task. A clean recognition advances, and so
does a spoken **"skip"** — a heard skip proves the voice path works, so it counts as one completed
practice letter. Anything ambiguous, filler, unintelligible, or silent re-presents a fresh letter on
the §7a retry → keypad path and records nothing: warm-up is where a dead microphone is caught before
anything is scored. Scored trials treat silence differently (§7): the row is recorded but uncounted,
and the 3-in-a-row backstop — not the retry budget — is what hands off to the keypad.

**Operator briefing.** No spoken prompt mentions skip. Before warm-up the OPERATOR tells the child:
*"If you cannot see the letter, say 'skip'."*

## 4. Acuity staircase

The staircase is the ETDRS five-letter protocol, ported from the reference app's authoritative
`ETDRSProgressionEngine` (`etdrs-five-letter-v1`).

| Parameter | Default | Meaning |
| --- | --- | --- |
| `acuityLevels` | 200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16 | Easiest → hardest |
| `startAcuity` | 40 | Starting level for high contrast (and the low-contrast fallback) |
| `trialsPerLevel` | 5 | Trials before a pass/fail decision (one ETDRS line) |
| `advanceThreshold` | 3 | Minimum correct to advance |
| `earlySkipCount` | 3 | All-correct run that passes the level immediately |
| `lineLogMARIncrement` | 0.1 | logMAR per line; per-letter credit = 0.1 / 5 = **0.02** |
| `gateAcuity` | 25 | Reference level for `reachedGate` on the high-contrast result (recorded; does not gate the flow) |
| `lowContrastStartOffsetSteps` | 2 | Ladder steps coarser than the high-contrast result that the low-contrast conditions start at |

**Rules**

- ≥ 3 of 5 correct → advance to the next finer level.
- First 3 all correct → pass immediately, recorded as a perfect 5/5 line.
- Otherwise → step back to the next coarser level; if that level was already passed, the threshold
  lies between them and the staircase terminates.
- Advancing INTO a level that already has a result also terminates (the threshold is bracketed) —
  a completed line is never re-tested or overwritten.
- Completing the finest level terminates with that level as the score's base line, pass or fail.
- Failing the largest level terminates, scored against the (possibly untested) second-largest.
- Only counting trials reach `record(correct:)`. Since 2026-09-03 a voice no-input trial is recorded
  with `countsTowardStaircase = false` and never fed to the engine: the level does not move and a
  fresh letter replaces it (§7).

**Scoring (two terminal lines).** The threshold sits between the two *terminal* lines: the finer
one — even when it was failed — is `primaryAcuity`; the coarser is `secondaryAcuity`.
`logMAR = table[primaryAcuity] + (primaryMisses + secondaryMisses) × 0.02`, where the table is
20/20 → 0.0, 20/25 → 0.1, 20/32 → 0.2, 20/40 → 0.3, 20/50 → 0.4, 20/63 → 0.5, 20/80 → 0.6,
20/100 → 0.7, 20/125 → 0.8, 20/160 → 0.9, 20/200 → 1.0 (and 20/16 → −0.1, 20/12 → −0.2, 20/10 → −0.3).

`reachedGate` is true when the finest PASSED level is 20/25 or finer — a failed primary line never
sets `reachedGate`. Since 2026-09-03 it is an analysis field only, never a flow branch: both
low-contrast conditions always run after high contrast, whatever the 20/25 result. The low-contrast
conditions run with `gateAcuity = nil`, so `reachedGate` is not evaluated for them. The protocol
parameters in force are persisted on every session as `staircaseProtocol`.

**Starting level.** High contrast starts at `startAcuity` (20/40). Each low-contrast condition
starts `lowContrastStartOffsetSteps` rungs **coarser** (bigger letters) than
`highContrast.finestAcuityDenominator` — the finest line the child actually PASSED — because a
low-contrast letter is harder to read than the same-size high-contrast one, so the run opens with
headroom above the child's own demonstrated line rather than at a fixed level. The offset is a
ladder-index step, not logMAR arithmetic (`ScreenConfig.acuityLevel(coarserBy:than:)`), clamped to
the coarsest level. The 2-step offset was chosen when the default contrast was 10 %; at the current
20 % default the low-contrast conditions are materially easier, and the offset may warrant
re-evaluation.

- Passed 20/20 → low contrast starts at 20/32. Passed 20/25 (the gate edge) → 20/40.
- The anchor can be any rung, because low contrast runs regardless of the 20/25 result. Passed only
  20/50 → low contrast starts at 20/80. When nothing was passed, `finestAcuityDenominator` is the
  coarser terminal line (20/200) and the clamp keeps the start on the ladder at 20/200.
- Both low-contrast conditions derive independently from the high-contrast result; the second is
  never chained off the first.
- With no high-contrast result — the operator skipped the gate with Next — the start falls back to
  `startAcuity`.

The per-condition starting rung is recoverable from the trial log: `TrialResult.acuityDenominator`
records the level of every row, so no session-record field is needed. Filter on
`countsTowardStaircase` first — a no-input row also carries the level and shares its `trialNumber`
with the letter that replaced it.

## 5. Conditions and contrast

| Condition | Background | Stimulus |
| --- | --- | --- |
| `highContrast` | white | black |
| `lowContrastRed` | red channel at full brightness | red channel × (1 − weber) |
| `lowContrastGreen` | teal (green + blue) | teal × (1 − weber) |

| Parameter | Default | Meaning |
| --- | --- | --- |
| `lowContrastWeber` | 0.20 | 20 % nominal sRGB-channel Weber — operator-selectable 5 / 10 / 15 / 20 % in Settings |
| `backgroundBrightness` | 1.0 | Background channel value (0…1) |
| `ContrastPalette.tealBlueFraction` | 1.0 | Blue mixed into the short-wavelength condition |

Weber contrast: `stimulus = background × (1 − weber)`.

The contrast setting is persisted by `ScreeningSettingsProvider` (UserDefaults, `schemaVersion` 2),
read once when the screening flow is launched (`ScreenConfig(settings:)`), and immutable for the
session; it is recorded on the session as `weberContrast` (JSON) and on every CSV trial row
(`weber_contrast`). A schema-1 record is upgraded on read, not deleted: its audio choice is kept, a
stored 10 % — the old default, which the audio toggle could have persisted implicitly — moves to
20 %, and an explicit 5 / 15 % is kept.

The teal condition keeps **red at exactly 0** so no long-wavelength light contaminates the
short-wavelength stimulus — otherwise the duochrome comparison is meaningless. The case name
`lowContrastGreen` is retained for on-disk compatibility; it renders teal.

> These are sRGB channel values, not photometric luminance. Clinical-grade validation would need
> device-specific luminance calibration. The nominal figures understate the photometric contrast
> considerably: at the 20 % default the stimulus channel is 0.80 sRGB ≈ 0.60 linear, roughly 40 %
> photometric Weber contrast; 10 % nominal ≈ 21 %.

**Order.** Both low-contrast conditions run after high contrast whatever the 20/25 result, in
randomized order (`.shuffled()`), overridable via `lowContrastOrderOverride` for tests.

## 6. Presentation geometry

Every condition draws the letter inside a fixed-size colored square, framed by a blue border, on
black. The square is computed **once per session** from the worst case (coarsest level at the far
band edge) and stays fixed across acuity levels; only the glyph changes size.

| Parameter | Default |
| --- | --- |
| `optotypeSquareInnerMargin` | 12 pt |
| `optotypeBorderGap` | 14 pt |
| `optotypeBorderWidth` | 8 pt |
| `testBrightness` | 1.0 |
| `interstimulusBlankSeconds` | 0.25 s |

Available width is `screenShortSide − 2 × (gap + borderWidth) − 8`. If the worst-case letter plus
margins exceeds it, `optotypeSquareSide` throws `DisplayFitError.screenTooSmall` and setup blocks.

The blue frame is an accommodation-relaxing cue.

**Inter-stimulus blank.** The colored square turns **black for `interstimulusBlankSeconds`
(0.25 s) before every letter**, so one optotype never swaps straight into the next. The letter is
hidden; the blue frame and every dimension stay put, so the child's fixation target does not move.
The blank runs on every presentation — the first letter of each block, letter-to-letter
transitions, same-letter repeats after a retry or escalation, and re-presentation after a distance
pause — but **not** on a live re-size, which republishes the same letter at a fresher size without
a transition. Recognition is deliberately **not armed until the blank clears**, so response latency
is never timed from a blank field. A distance pause cancels an in-flight blank; the square never
sticks black. Setting the value to zero presents synchronously (how the unit tests run).

## 6a. Display sleep

`IdleTimerController` disables the system idle timer for as long as the app is in the **foreground**
— the whole app, not just the screening — and restores the previous setting on background. The
screening has long stretches with no touch input at all, so the display would otherwise dim and
lock mid-test, taking the brightness lock the optotype sizing depends on with it.

## 7. Stimuli and response

| Parameter | Default | Meaning |
| --- | --- | --- |
| `letterSet` | Sloan 10: C D H K N O R S V Z | |
| `recognitionTimeoutSeconds` | 10 | The **no-input window**, timed from the first microphone audio after the letter is revealed — after the inter-stimulus blank and after any spoken prompt plus `listenResumeAfterSpeechSeconds` — never from a blank field or from the app's own speech. **Soft** since 2026-09-03: it never fires while voice is in the newest `utteranceEndQuietSeconds` of audio or a transcription is in flight (deferred in `deadlineDeferralStepSeconds` steps up to `deadlineDeferralCapSeconds`), so a late answer is scored for this letter. Was 5 s while silence scored a miss; 8 s when it merely retried |
| `noInputTrialsBeforeEscalation` | 3 | Consecutive voice trials ended by the no-input window before the NEXT letter goes to the clinician keypad (§7a) — the only exit from a same-level loop, because no-input trials do not move the staircase |
| `deadlineDeferralStepSeconds` | 0.25 | Step by which the soft deadline is pushed back each time it lands on voice in the tail or an in-flight inference |
| `deadlineDeferralCapSeconds` | 3.0 | Total deferral allowed past the window before it flushes regardless — a television keeps the tail "voiced" forever. Worst case ≈ window + cap + the 1.5 s inference drain + one decode (~15 s) |
| `utteranceEndQuietSeconds` | 0.3 | A live transcription runs only once the newest this-many seconds read as silence — the answer has ENDED (Whisper completes a truncated first syllable into a non-letter word). Also exactly the tail a non-answer pass leaves unconsumed; the two are equal on purpose |
| `maximumUtteranceSeconds` | 2.0 | A sound continuous for this long is transcribed anyway (a long answer, a noisy room); also bounds how much of a run that began BEFORE the reveal is skipped as carried-over voice |
| `voiceSilenceThreshold` | 0.10 | Per-100 ms block energy, relative (0…1) to the quietest of the previous 2 s (blocks below −80 dBFS never serve as the reference), above which a block reads as voice. A **speech-length sound** is 2 consecutive voice blocks — a constant, not a key. WhisperKit's default; tunable for the 2 m distance |
| `capturePurgeKeepSeconds` | 3.0 | Audio kept behind the session start whenever the recognizer's capture store is trimmed (at each arm, after a cancel, at block ends): must cover the 2 s silence reference plus the block the carried-over-voice rule inspects |
| `captureBufferTrimAfterSeconds` | 120 | WhisperKit's own live buffer grows for the life of an engine; once it holds this much audio (~7.7 MB) the engine is paused for a few milliseconds, the buffer emptied, and the engine resumed — between letters or during a pause, never on a reveal |

Consecutive repeats of the same letter are avoided. Responses are spoken and mapped by
`LetterMappingTable`. A scored voice trial resolves in exactly one of these ways:

- **A recognized Sloan letter** → scored, correct or incorrect.
- **A spoken "skip"** → an **incorrect** trial with `response = "skip"`, never retried. The
  vocabulary is `LetterMappingTable.skipPhrases` (skip, skipp, skiip, skipped, skips, skipping,
  skippy, skype, scip, skep, skup — Whisper's mis-hearings). A skip word alone, or with filler or a
  non-letter tail ("um skip", "skip it", "please skip"), is a skip; a skip word beside a letter
  ("c skip", and notably "okay skip", because "okay" is a K correction) is ambiguous and retries.
  Conservative on purpose: a false skip is a scored miss, a missed skip only a retry. The tier-2
  mis-hearings ski, kip, skit, skid, skiff are deliberately excluded pending device logs — Whisper
  can fuse an "S… K" self-correction into one of them, which would turn today's ambiguous retry
  into a scored miss.
- **The no-input window elapses with no speech-length sound and no usable text from an armed
  microphone** (`.unrecognized(.silence)`; ~10 s, soft) → since 2026-09-03 an **incorrect,
  uncounted** row with `response = "no input registered"` and `countsTowardStaircase = false`: the
  staircase is not fed, the level does not move, and a **fresh letter** is presented at the same
  level — no retry of the same letter, no re-prompt. (From 2026-09-02 until then the row counted as
  a miss.)
- **Ambiguous, filler, or unintelligible** answers → re-present the same letter (§7a) and are
  **never** recorded as trials.

| Resolution | Recorded as a row | Fed to the staircase |
| --- | --- | --- |
| Recognized letter | yes (`isCorrect` per match) | yes |
| Spoken "skip" | yes — `skip`, incorrect | yes |
| Keypad "No response" | yes — `-`, incorrect | yes |
| Voice no-input window | yes — `no input registered`, incorrect, `countsTowardStaircase = false` | **no** — fresh letter, same level |
| Ambiguous / filler / unintelligible | no | no — same letter retries (§7a) |
| Distance-pause repeat | no | no — same letter repeats |

Silence is only ever reported for a whole window from an armed microphone. A microphone that never
armed (model still loading, permission prompt, no audio delivered) reports `.serviceFailure` —
immediate keypad plus alert, never silence. Since 2026-09-03 the listening design is the one ported
from the sibling ETDRS app (`ListeningBufferRules`, `CaptureSampleStore`; ARCHITECTURE § Speech):
the service keeps its **own** 16 kHz sample store fed by WhisperKit's tap and computes a per-100 ms
voice trace from it (RMS relative to the quietest of the previous 2 s, `voiceSilenceThreshold`) —
it never reads WhisperKit's buffer or its voice heuristic (the block an engine start lands in, and the next, are masked out of the trace, so a ramp-in buffer can never become the silence reference). The session **starts at the reveal**: the
start index is minted in the same main-actor turn that shows the letter, so nothing recorded before
the reveal is ever transcribed, and a sound already under way in the session's first 100 ms block
began before the child could see the letter and is skipped as **carried-over voice** (bounded by
`maximumUtteranceSeconds`) — the tail of one answer can never be scored for the next letter. A live
transcription runs only once an utterance has **ended** (voice in the unconsumed span and a quiet
`utteranceEndQuietSeconds` tail, or `maximumUtteranceSeconds` of continuous sound), never on a
first syllable Whisper would complete into a non-letter word; a pass that produced an answer, and
the final flush, consume everything they saw, any other pass leaves the newest 0.3 s unconsumed so
a straddling onset survives, and the consumed pointer never moves backwards. **The voice trace
decides silence, never Whisper's text alone:** `.unrecognized(.silence)` needs no speech-length
sound (two consecutive voice blocks) AND no usable text; hallucination text ("Thank you.", "you")
over a real sound is `.unintelligible` (retry with re-prompt), so a child who spoke is never logged
as `no input registered`; a filler / unintelligible / ambiguous pass heard earlier in the window is
reported instead of a quiet tail (so "um" then quiet → retry, not a row); and audio that could not
be inspected reports `.unintelligible`. The deadline flush first drains an in-flight decode (it may
be the child's late answer), then decodes only the speech-length runs left unconsumed (padded
0.5 s) — with none it reports silence without calling Whisper at all, because 5–10 s of room noise
is exactly what Whisper hallucinates text over. A keypad escalation releases the microphone for the
keypad trial; the first voice letter after it re-opens the block's capture session, so the remaining
letters keep the warm engine and the interruption/route observers rather than cold-starting the
engine after each reveal.

## 7a. Retry and escalation

A trial that produces no usable answer must never re-present forever.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `maxAutoRetriesPerTrial` | 2 | Same-letter retries before handing off to the clinician keypad |
| `stickyManualAfterConsecutiveEscalations` | 2 | Consecutive escalated trials before manual mode sticks |

- `.ambiguous` / `.unrecognized(.filler | .unintelligible)` → retry the same letter, the **first**
  retry with a spoken re-prompt, later retries silent. Past the cap, escalate to the keypad. Voice
  `.unrecognized(.silence)` on a scored trial is **not** a retry of the same letter — it is recorded
  as an uncounted row and a fresh letter is presented (§7).
- During the first retry's re-prompt the square is **blanked** and the letter re-presents (a fresh
  one in warm-up) in the prompt's completion: the microphone is off while the app speaks, so a visible letter would invite
  an answer nobody hears — and end as a no-input row.
- `.serviceFailure` (permissions, model, capture) → escalate **immediately**; retrying cannot fix a
  structural fault.
- **No-input backstop.** After `noInputTrialsBeforeEscalation` (3) **consecutive** voice trials
  ended by the no-input window, the NEXT presentation goes to the clinician keypad. The silent
  trials are recorded but never counted; any spoken letter, skip, or keypad entry resets the count.
  The hand-off counts as an escalation for sticky-manual purposes, and a no-input row does **not**
  clear the consecutive-escalation streak (silence proves nothing about the voice path), so two
  no-input escalations in a row make manual mode sticky. Since 2026-09-03 this backstop is the
  **only** termination guard on the voice path: silence cannot fail a line or end a condition, so
  without it a silent child or a muted microphone would be shown fresh letters at the same level
  forever, with no operator signal — the operator status strip is hidden in voice mode. Three soft
  windows mean ~30–40 s of silence before the keypad appears (was ~18 s under the 5 s rule).
- After enough consecutive escalations, manual mode is sticky until the clinician explicitly
  restores voice input.
- A distance-pause repeat is **not** an answer attempt and does not consume or reset retries.
- A **keypad-only start** (`forceStickyManual`) latches manual mode from the first trial and
  survives resolved letters, so a session begun without a usable microphone never drifts back to
  voice on its own.
- `goBack()` clears non-sticky escalation state so a re-run starts clean.

**Operator skip.** The Next control on a scored condition (high contrast, low-contrast red,
low-contrast teal) first asks *"Skip this test? No result will be recorded for the … test."* with
**Skip** and **Cancel**. Cancel leaves the trial exactly as it was; a confirmed skip records no
result for that condition (results show "Skipped") and the session moves on. Next on distance lock
and warm-up stays immediate — there is nothing scored to lose.

Keypad answers score exactly like voice answers; keypad "No response" records an incorrect,
counted trial (`response = "-"`) rather than being dropped from the record — as does a spoken skip
(`"skip"`). A voice no-input (`"no input registered"`) is recorded but **not counted** (§7). The
keypad has no Skip button: letters plus "No response" only. Escalation during warm-up records
nothing but still advances.

## 7b. Patient-facing audio

| Parameter | Default | Meaning |
| --- | --- | --- |
| `ttsEnabled` | `true` | Master switch for spoken prompts |
| `ttsRate` | 0.5 | `AVSpeechUtterance` rate |
| `categorySettleSeconds` | 0.15 | Settle delay after an audio-session category switch, so the utterance onset is not clipped |
| `listenResumeAfterSpeechSeconds` | 0.5 | Delay between a prompt finishing and recognition re-arming when a prompt was still playing at the reveal. Since 2026-09-03 the announcer speaks UNDER the live capture session with no category flip: the prompt's echo lies before the session start and is never inspected, and a ring-down straddling the start is skipped as carried-over voice (§7), so only the speaker's drain (~0.2 s) needs to clear. Was 1.5 s — the reference app's value, covering a cold engine restart after a `.playback` flip. Raise to 0.75 if device logs ever show prompt words inside a session |
| `distancePromptMinIntervalSeconds` | 5 | Minimum gap before the *same* guidance prompt repeats |
| `speakEveryTrialPrompt` | `false` | When false, the per-trial prompt is not repeated on every letter. Known limitation when `true`: the letter is visible while the prompt plays and the session starts only after it, so an answer given during the prompt is not heard — the child repeats it |

The spoken catalog is closed (`SpokenPrompt`): "Say the letter you see.", "Say the letter you see out
loud.", "Let's practice. Say each letter out loud.", "Here we go. Say the letter you see.", "Move
closer.", "Move farther.", "I can't see you. Step back into view.", "Hold still.", "Moved too much.
Please try again.", "Lost your face. Please try again.", "All done. Great job!"

No prompt mentions skip — the catalog is unchanged by the spoken-skip rule. The OPERATOR briefs the
child before warm-up (§3).

**Recognition never runs while the app is speaking** — the coordinator gates listening on
`isSpeaking`, which deliberately covers the pre-speech category-switch window as well as the
utterance itself, so the microphone cannot capture the app's own voice. A prompt different from the
last one speaks immediately; the same prompt repeats only after `distancePromptMinIntervalSeconds`.

## 7c. Operator "Heard" line

Since 2026-09-03 the trial screen shows, at the top in voice mode, a one-row caption pill with the
recognizer's narration: `Listening…` while the microphone is armed and nothing has completed, then
`Heard "C." → C ✓` / `Heard "C." → C ✗` / `Heard "seat" → no letter` / `Heard "um" → hesitation` /
`Heard "C D" → more than one letter` / `Heard "skip" → skip` / `Deadline extended +0.75 s` /
`Heard nothing (window elapsed)` (`HeardDiagnosticFormatter`; the raw transcript is condensed and
capped at 24 characters). It lets the operator holding the phone tell "the child said nothing" from
"the recognizer misheard" without waiting for the CSV. **Display only:** it mirrors
`MyopiaScreenCoordinator.lastHeard`, fed by the service's `RecognitionDiagnostic` stream, and never
scores or drives the flow — a trial resolves solely through the recognition callback, so the line
can never disagree with the score. At caption size it subtends ≈2 arcmin at 200 cm, well under the
20/25 letter, so the child cannot read it and it cannot cue the answer; it sits below the Back/Next
capsules and never over the optotype. The line is kept across the letter transition (a fresh
`Listening…` fills only an empty line) so the operator can read the previous result — shown dimmed with a `Last:` prefix until the current letter produces its own — and it is hidden during a distance pause, when the child may approach the phone and could read it; a deferral narration that lands after the trial resolved is dropped; warm-up shows
the same line beneath its warm-up pill; manual/keypad mode keeps the bottom operator strip instead.

## 8. Results and interpretation

`duochromeDeltaLogMAR = lowContrastGreen.logMAR − lowContrastRed.logMAR`.

Positive means **red was read better than teal** — the pattern under investigation for subtle myopic
defocus, since shorter wavelengths focus in front of the retina and blur first.

`interpretation` is a free-text research label, never a diagnosis:

| Value | When |
| --- | --- |
| `notComputed` | Session incomplete, or a low-contrast condition was skipped by the operator |
| `highContrastBelowGate` | Legacy — written only by sessions saved before 2026-09-03, when a below-20/25 high-contrast result ended the session before low contrast ran. Not written any more |
| `redBetterThanGreen_deltaRecorded` | Delta > 0 |
| `noRedGreenDifference_deltaRecorded` | Delta ≤ 0 |

**No validated threshold is applied.** The delta is recorded raw for later analysis.

## 9. Privacy

| Parameter | Default | Meaning |
| --- | --- | --- |
| `persistRawSignals` | `false` | When off, no raw audio buffers or face geometry are stored — only the derived per-trial distance scalar |

Enable only under an approved research protocol with appropriate participant privacy documentation.

---

## Calibration reference

`pointsPerMillimeter` comes from DevicePpi (`ppi / nativeScale / 25.4`) or a 50 mm operator ruler
measurement. It is bound to a screen signature `machineIdentifier|WxH|nativeScale` and
`ScreenCalibration.schemaVersion`; any mismatch deletes the stored record permanently.

Target cap height is `2 × distance_mm × tan(θ / 2)` where `θ = (denominator / 20) × 5` arcminutes.
At 200 cm: 20/20 = 2.909 mm, 20/25 = 3.636 mm, 20/40 = 5.818 mm, 20/200 = 29.089 mm. The full table
and the physical verification procedure are in [TESTING.md § Part 4](TESTING.md#part-4--verifying-physical-optotype-size).
