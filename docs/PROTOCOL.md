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

## 2. Distance lock

The child is guided to the target distance. Lock requires the measured distance to remain inside the
valid band for a continuous window with low variability.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `targetDistanceCM` | 200 | Nominal test distance |
| `validDistanceRangeCM` | 180…240 | Band required to lock and to keep a trial valid |
| `providerDistanceRangeCM` | 100…300 | Wider band the provider accepts as *plausible* at all |
| `distanceStableWindowSeconds` | 0.75 | Continuous in-band dwell required |
| `maxDistanceSDCM` | 5 | Max standard deviation across the dwell window |

Guidance strings: `noFace` → "I can't see you. Step into view." · `tooClose` → "Move farther away" ·
`tooFar` → "Move closer" · `holdSteady` → "Hold still…" · `locked` → "Distance locked".

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

Unscored high-contrast letters so the child learns the task. A clean recognition advances; anything
ambiguous or unrecognized re-presents.

## 4. Acuity staircase

| Parameter | Default | Meaning |
| --- | --- | --- |
| `acuityLevels` | 200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16 | Easiest → hardest |
| `startAcuity` | 40 | Starting level |
| `trialsPerLevel` | 10 | Trials before a pass/fail decision |
| `advanceThreshold` | 6 | Minimum correct to advance |
| `earlySkipCount` | 5 | All-correct run that passes the level immediately |
| `gateAcuity` | 25 | Gate denominator (high contrast only) |

**Rules**

- ≥ 6 of 10 correct → advance to the next finer level.
- First 5 all correct → pass immediately, recorded as a perfect 10/10.
- Otherwise → step back to the next coarser level; if that level was already passed, the threshold
  lies between them and the staircase terminates.
- Terminates at either end of the level list.

**Scoring.** `logMAR = table[finest passed level] + wrong / 100`, where the table is
20/20 → 0.0, 20/25 → 0.1, 20/32 → 0.2, 20/40 → 0.3, 20/50 → 0.4, 20/63 → 0.5, 20/80 → 0.6,
20/100 → 0.7, 20/125 → 0.8, 20/160 → 0.9, 20/200 → 1.0 (and 20/16 → −0.1, 20/12 → −0.2, 20/10 → −0.3).

`reachedGate` is true when the finest passed level is 20/25 or finer. The low-contrast conditions run
with `gateAcuity = nil`, so they are never gated.

## 5. Conditions and contrast

| Condition | Background | Stimulus |
| --- | --- | --- |
| `highContrast` | white | black |
| `lowContrastRed` | red channel at full brightness | red channel × (1 − weber) |
| `lowContrastGreen` | teal (green + blue) | teal × (1 − weber) |

| Parameter | Default | Meaning |
| --- | --- | --- |
| `lowContrastWeber` | 0.05 | 5 % Weber contrast |
| `fallbackWeber` | 0.10 | If 5 % proves too difficult |
| `backgroundBrightness` | 1.0 | Background channel value (0…1) |
| `ContrastPalette.tealBlueFraction` | 1.0 | Blue mixed into the short-wavelength condition |

Weber contrast: `stimulus = background × (1 − weber)`.

The teal condition keeps **red at exactly 0** so no long-wavelength light contaminates the
short-wavelength stimulus — otherwise the duochrome comparison is meaningless. The case name
`lowContrastGreen` is retained for on-disk compatibility; it renders teal.

> These are sRGB channel values, not photometric luminance. Clinical-grade validation would need
> device-specific luminance calibration.

**Order.** The two low-contrast conditions run in randomized order (`.shuffled()`), overridable via
`lowContrastOrderOverride` for tests.

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

Available width is `screenShortSide − 2 × (gap + borderWidth) − 8`. If the worst-case letter plus
margins exceeds it, `optotypeSquareSide` throws `DisplayFitError.screenTooSmall` and setup blocks.

The blue frame is an accommodation-relaxing cue.

## 7. Stimuli and response

| Parameter | Default |
| --- | --- |
| `letterSet` | Sloan 10: C D H K N O R S V Z |
| `recognitionTimeoutSeconds` | 6 |

Consecutive repeats of the same letter are avoided. Responses are spoken and mapped by
`LetterMappingTable`. Ambiguous or unrecognized answers re-present the same letter and are **never**
recorded as trials.

## 7a. Retry and escalation

A trial that produces no usable answer must never re-present forever.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `maxAutoRetriesPerTrial` | 2 | Same-letter retries before handing off to the clinician keypad |
| `stickyManualAfterConsecutiveEscalations` | 2 | Consecutive escalated trials before manual mode sticks |

- `.unrecognized` / `.ambiguous` → retry the same letter, the **first** retry with a spoken
  re-prompt, later retries silent. Past the cap, escalate to the keypad.
- `.serviceFailure` (permissions, model, capture) → escalate **immediately**; retrying cannot fix a
  structural fault.
- After enough consecutive escalations, manual mode is sticky until the clinician explicitly
  restores voice input.
- A distance-pause repeat is **not** an answer attempt and does not consume or reset retries.

Keypad answers score exactly like voice answers; "couldn't answer" records an incorrect trial rather
than silently skipping. Escalation during warm-up records nothing but still advances.

## 7b. Patient-facing audio

| Parameter | Default | Meaning |
| --- | --- | --- |
| `ttsEnabled` | `true` | Master switch for spoken prompts |
| `ttsRate` | 0.5 | `AVSpeechUtterance` rate |
| `categorySettleSeconds` | 0.15 | Settle delay after an audio-session category switch, so the utterance onset is not clipped |
| `listenResumeAfterSpeechSeconds` | 1.0 | Delay before recognition resumes after speech ends |
| `distancePromptMinIntervalSeconds` | 5 | Minimum gap before the *same* guidance prompt repeats |
| `speakEveryTrialPrompt` | `false` | When false, the per-trial prompt is not repeated on every letter |

The spoken catalog is closed (`SpokenPrompt`): "Say the letter you see.", "Say the letter you see out
loud.", "Let's practice. Say each letter out loud.", "Here we go. Say the letter you see.", "Move
closer.", "Move farther away.", "I can't see you. Step back into view.", "Hold still.", "All done.
Great job!"

**Recognition never runs while the app is speaking** — the coordinator gates listening on
`isSpeaking`, which deliberately covers the pre-speech category-switch window as well as the
utterance itself, so the microphone cannot capture the app's own voice. A prompt different from the
last one speaks immediately; the same prompt repeats only after `distancePromptMinIntervalSeconds`.

## 8. Results and interpretation

`duochromeDeltaLogMAR = lowContrastGreen.logMAR − lowContrastRed.logMAR`.

Positive means **red was read better than teal** — the pattern under investigation for subtle myopic
defocus, since shorter wavelengths focus in front of the retina and blur first.

`interpretation` is a free-text research label, never a diagnosis:

| Value | When |
| --- | --- |
| `notComputed` | Session incomplete |
| `highContrastBelowGate` | The 20/25 gate was not reached; low contrast was skipped |
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
