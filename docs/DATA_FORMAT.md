# Data output format

Completed sessions are written by `SessionStore` to the app's **Documents** directory under
`MyopiaSessions/`, retrievable via Finder (device → *Files* → **Myotect**) or the Files app:

```
Documents/MyopiaSessions/
├── <sessionID>.json     complete session record
└── <sessionID>.csv      one row per recorded trial
```

`sessionID` is a UUID string. Both files are written atomically at session completion; an aborted
session is not saved unless it reached completion.

**Recorded ≠ counted.** Ambiguous, filler, and unintelligible answers, and presentations repeated
after a distance pause, never produce a row. A spoken **skip** and a keypad **No response** produce
incorrect rows that count toward the staircase. A voice **no-input** (the soft ~10 s window with no
speech-length sound and no usable text from an armed microphone) produces an incorrect row with
`countsTowardStaircase = false` that the staircase never saw — a fresh letter replaced it at the
same level (since 2026-09-03; between 2026-09-02 and then such rows counted as misses and carry no
flag). Filter on the flag — not on the `response` sentinel — before computing anything per level.

**No raw audio and no face geometry are persisted** by default — only the derived eye-to-screen
distance scalar per trial (`ScreenConfig.persistRawSignals`, default `false`).

---

## JSON — session record

Encoded with `.prettyPrinted`, `.sortedKeys`, and ISO-8601 dates.

| Field | Type | Notes |
| --- | --- | --- |
| `sessionID` | String | UUID; matches the filename |
| `startedAt` | ISO-8601 | Session construction time |
| `completedAt` | ISO-8601? | Null if never completed |
| `appVersion` | String | `CFBundleShortVersionString` |
| `deviceModel` | String | `UIDevice.current.model` |
| `ppiUsed` | Double | Derived: `pointsPerMillimeter × nativeScale × 25.4`. `0` until the session begins |
| `targetDistanceCM` | Double | 200 by default |
| `weberContrast` | Double | 0.20 by default (nominal sRGB-channel Weber, not photometric); operator-selectable 0.05 / 0.10 / 0.15 / 0.20 in Settings |
| `letterSet` | [String] | Sloan 10 by default |
| `highContrast` | AcuityConditionResult? | High-contrast result (`reachedGate` is informational) |
| `lowContrastRed` | AcuityConditionResult? | Null only when the operator skipped the condition (sessions before 2026-09-03: also null when the 20/25 gate ended the session) |
| `lowContrastGreen` | AcuityConditionResult? | Null only when the operator skipped the condition (sessions before 2026-09-03: also null when the 20/25 gate ended the session) |
| `duochromeDeltaLogMAR` | Double? | `green.logMAR − red.logMAR`; null unless **both** are present |
| `interpretation` | String | Research label — see below |
| `trials` | [TrialResult] | Every recorded trial, in order (counted and uncounted — see `countsTowardStaircase`) |
| `aborted` | Bool | |
| `abortReason` | String? | |
| `calibration` | ScreenCalibration? | The calibration in force when the session began. Optional so pre-upgrade JSON decodes |
| `lockedDistanceCM` | Double? | Mean of the operator-initiated capture hold — where the subject actually locked, as distinct from `targetDistanceCM`. Optional so pre-upgrade JSON decodes; nil when the lock phase was skipped manually |
| `staircaseProtocol` | StaircaseProtocolMetadata? | The staircase parameters in force (`trialsPerLevel`, `advanceThreshold`, `earlySkipCount`, `lineLogMARIncrement`, `logMARPerLetter`). Optional so pre-upgrade JSON decodes |

### `AcuityConditionResult`

| Field | Type | Notes |
| --- | --- | --- |
| `condition` | String | `highContrast` \| `lowContrastRed` \| `lowContrastGreen` |
| `finestAcuityDenominator` | Int | The `x` in `20/x` — the finest level actually PASSED. When nothing was passed, falls back to the coarser terminal line (the level near threshold), never a finer/untested one |
| `logMAR` | Double | `table[primaryAcuity] + (primaryMisses + secondaryMisses) × 0.02` — two-terminal-line ETDRS letter scoring (see PROTOCOL.md §4) |
| `reachedGate` | Bool | Only meaningful for `highContrast`; always true for ungated conditions. Recorded for analysis; since 2026-09-03 it does not gate the flow — the low-contrast conditions always run |

`snellenEquivalent` (`20 × 10^logMAR`) is a computed convenience and is **not** encoded.

### `ScreenCalibration`

| Field | Type | Notes |
| --- | --- | --- |
| `pointsPerMillimeter` | Double | The conversion used for all sizing |
| `nativeScale` | Double | `UIScreen.main.nativeScale` — physical pixels per point |
| `source` | String | `deviceDatabase` \| `manual` \| `legacyUnknown` (never valid for sizing) |
| `screenSignature` | String | `machineIdentifier\|WxH\|nativeScale` |
| `schemaVersion` | Int | Currently `1` |

### `TrialResult`

| Field | Type | Notes |
| --- | --- | --- |
| `condition` | String | |
| `acuityDenominator` | Int | Level at presentation |
| `shownLetter` | String | |
| `response` | String | Recognized Sloan letter, uppercased — or one of the `TrialResult.NonLetterResponse` sentinels: `-` (clinician keypad "No response"), `skip` (spoken skip), `no input registered` (the voice no-input window elapsed). All three are incorrect by construction; `no input registered` additionally has `countsTowardStaircase = false` |
| `isCorrect` | Bool | |
| `distanceCM` | Double | **Answer-time** measurement from a freshly validated sample |
| `sizingDistanceCM` | Double? | Distance the visible stimulus was last sized for. Optional |
| `responseTimeMS` | Int | Recognition arming (after the inter-stimulus blank and any spoken prompt) → resolved response. For a `no input registered` row this is ≈ the 10 s soft window, extended by however long the deadline was deferred while sound was still being collected (≈ 10–13 s, at most ~15 s); for a `skip` row, the time to say "skip" |
| `trialNumber` | Int | 1-based WITHIN the acuity level in progress (gold `nextTrialNumber` semantics); resets on every level change. A `no input registered` row shares its number with the letter that replaced it (the engine was not fed), so the number is unique within a level only among rows with `countsTowardStaircase` true |
| `timestamp` | ISO-8601 | |
| `provenance` | SizingProvenance? | How the stimulus was sized. Optional |
| `countsTowardStaircase` | Bool? | `false` for a voice no-input row: recorded but never fed to the staircase. Written explicitly (`true` / `false`) on every row since 2026-09-03; absent on rows written before that, and absent means `true` (every earlier row was counted, including the 2026-09-02 `no input registered` misses). The results screen's distance-mean `n` counts only rows where this is true |

`distanceCM` and `sizingDistanceCM` differ when the child drifted (in-band) between presentation and
response: the letter was sized for one distance and answered at another. Both are recorded so the
angular size actually presented can be reconstructed exactly.

### `SizingProvenance`

Re-validated against the live calibration immediately before scoring; a mismatch pauses the trial
rather than recording a mis-sized result.

| Field | Type | Notes |
| --- | --- | --- |
| `sizingVersion` | Int | Currently `2` |
| `calibrationSource` | String | |
| `pointsPerMillimeter` | Double | |
| `screenSignature` | String | |
| `targetHeightMillimeters` | Double | Intended physical cap height |
| `renderedHeightPoints` | Double | Points actually drawn |

---

## CSV — trial rows

One header row plus one row per recorded trial. **20 columns**, comma-separated, no quoting except
`screen_signature` (below): values are numeric, ISO-8601, single uppercase letters, or the
`response` sentinels `-` / `skip` / `no input registered` — which may contain spaces but never a
comma, quote, or newline, so they are written verbatim, unquoted.

| # | Column | Source | Format |
| ---: | --- | --- | --- |
| 1 | `session_id` | session | |
| 2 | `started_at` | session | ISO-8601 |
| 3 | `condition` | trial | raw enum value |
| 4 | `acuity_20x` | trial | Int denominator |
| 5 | `shown_letter` | trial | |
| 6 | `response` | trial | |
| 7 | `is_correct` | trial | `1` / `0` |
| 8 | `distance_cm` | trial | `%.1f` |
| 9 | `sizing_distance_cm` | trial | `%.1f`, empty if absent |
| 10 | `response_time_ms` | trial | Int |
| 11 | `trial_number` | trial | Int |
| 12 | `timestamp` | trial | ISO-8601 |
| 13 | `sizing_version` | provenance | Int, empty if absent |
| 14 | `calibration_source` | provenance | empty if absent |
| 15 | `points_per_mm` | provenance | `%.4f`, empty if absent |
| 16 | `screen_signature` | provenance | **RFC-4180 quoted when it contains a comma**; empty if absent |
| 17 | `target_height_mm` | provenance | `%.3f`, empty if absent |
| 18 | `rendered_height_points` | provenance | `%.2f`, empty if absent |
| 19 | `weber_contrast` | session | `%.2f` — session-level constant repeated on every row |
| 20 | `counts_toward_staircase` | trial | `1` / `0` — `0` on a voice no-input row (recorded, not counted, replaced by a fresh letter). Rows written before the field existed read `1` |

> **Use a real CSV parser — do not split on commas.** `screen_signature` embeds the device machine
> identifier, which is `iPhone17,1`-shaped on **every real device**, so it almost always contains a
> comma. `SessionStore.csvField` wraps such values in double quotes and doubles any embedded quote,
> per RFC 4180. Naive comma-splitting will misalign every provenance column.
>
> Session-level results (per-condition logMAR and `reachedGate`, the duochrome delta, the
> interpretation) are **not** in the CSV — read the JSON for those.
>
> New columns are **appended**, never inserted, so every existing column keeps its position across
> versions (columns 1–19 are frozen; `counts_toward_staircase` was appended as column 20 on
> 2026-09-03, so `weber_contrast` is no longer the last column — scripts that read "the last
> column" as Weber must index column 19).

### Example

Note the quoted `screen_signature` field, and the uncounted `no input registered` row (third) that
shares `trial_number` 3 with the fresh letter that replaced it (fourth):

```csv
session_id,started_at,condition,acuity_20x,shown_letter,response,is_correct,distance_cm,sizing_distance_cm,response_time_ms,trial_number,timestamp,sizing_version,calibration_source,points_per_mm,screen_signature,target_height_mm,rendered_height_points,weber_contrast,counts_toward_staircase
5B1E...,2026-08-03T20:15:02Z,highContrast,40,K,K,1,201.4,200.0,1840,1,2026-08-03T20:15:31Z,2,deviceDatabase,6.0367,"iPhone17,1|1206x2622|3.0000",5.818,35.13,0.20,1
5B1E...,2026-08-03T20:15:02Z,highContrast,40,V,V,1,199.8,199.8,1620,2,2026-08-03T20:15:35Z,2,deviceDatabase,6.0367,"iPhone17,1|1206x2622|3.0000",5.812,35.09,0.20,1
5B1E...,2026-08-03T20:15:02Z,highContrast,40,H,no input registered,0,200.3,200.3,10412,3,2026-08-03T20:15:49Z,2,deviceDatabase,6.0367,"iPhone17,1|1206x2622|3.0000",5.818,35.13,0.20,0
5B1E...,2026-08-03T20:15:02Z,highContrast,40,Z,Z,1,200.1,200.1,1510,3,2026-08-03T20:15:52Z,2,deviceDatabase,6.0367,"iPhone17,1|1206x2622|3.0000",5.821,35.15,0.20,1
```

Loading in pandas or R needs no special handling — both honour RFC-4180 quoting by default:

```python
import pandas as pd
df = pd.read_csv("<sessionID>.csv")     # screen_signature comes back intact
counted = df[df.counts_toward_staircase == 1]   # the rows the staircase actually consumed
```

---

## Interpretation values

| Value | When |
| --- | --- |
| `notComputed` | Session incomplete, or a low-contrast condition skipped by the operator (delta unavailable) |
| `highContrastBelowGate` | Legacy — sessions saved before 2026-09-03, when a below-20/25 high-contrast result ended the session before low contrast ran; no longer written |
| `redBetterThanGreen_deltaRecorded` | `duochromeDeltaLogMAR > 0` |
| `noRedGreenDifference_deltaRecorded` | `duochromeDeltaLogMAR ≤ 0` |

These are research labels. **No validated diagnostic threshold is applied** — the delta is recorded
raw for later analysis.

---

## Reading sessions back

`SessionStore.loadAllSessions()` returns every decodable session sorted newest-first by
`completedAt ?? startedAt`. Unreadable or undecodable files are skipped, so one corrupt file never
hides the rest. This backs the *Previous results* screen.
