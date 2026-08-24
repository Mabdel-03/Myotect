# Data output format

Completed sessions are written by `SessionStore` to the app's **Documents** directory under
`MyopiaSessions/`, retrievable via Finder (device → *Files* → **Myotect**) or the Files app:

```
Documents/MyopiaSessions/
├── <sessionID>.json     complete session record
└── <sessionID>.csv      one row per scored trial
```

`sessionID` is a UUID string. Both files are written atomically at session completion; an aborted
session is not saved unless it reached completion.

**Only scored trials are recorded.** Ambiguous answers, unrecognized answers, and presentations
repeated after a distance pause never produce a row.

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
| `weberContrast` | Double | 0.10 by default; operator-selectable 0.05 / 0.10 / 0.15 in Settings |
| `letterSet` | [String] | Sloan 10 by default |
| `highContrast` | AcuityConditionResult? | Gate result |
| `lowContrastRed` | AcuityConditionResult? | Null if the gate failed |
| `lowContrastGreen` | AcuityConditionResult? | Null if the gate failed |
| `duochromeDeltaLogMAR` | Double? | `green.logMAR − red.logMAR`; null unless **both** are present |
| `interpretation` | String | Research label — see below |
| `trials` | [TrialResult] | Every scored trial, in order |
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
| `reachedGate` | Bool | Only meaningful for `highContrast`; always true for ungated conditions |

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
| `response` | String | Recognized Sloan letter, uppercased |
| `isCorrect` | Bool | |
| `distanceCM` | Double | **Answer-time** measurement from a freshly validated sample |
| `sizingDistanceCM` | Double? | Distance the visible stimulus was last sized for. Optional |
| `responseTimeMS` | Int | Presentation → scored response |
| `trialNumber` | Int | 1-based WITHIN the acuity level in progress (gold `nextTrialNumber` semantics); resets on every level change |
| `timestamp` | ISO-8601 | |
| `provenance` | SizingProvenance? | How the stimulus was sized. Optional |

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

One header row plus one row per scored trial. **19 columns**, comma-separated, no quoting (all values
are numeric, ISO-8601, or single uppercase letters).

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

> **Use a real CSV parser — do not split on commas.** `screen_signature` embeds the device machine
> identifier, which is `iPhone17,1`-shaped on **every real device**, so it almost always contains a
> comma. `SessionStore.csvField` wraps such values in double quotes and doubles any embedded quote,
> per RFC 4180. Naive comma-splitting will misalign every provenance column.
>
> Session-level results (per-condition logMAR, the duochrome delta, the interpretation) are **not**
> in the CSV — read the JSON for those.

### Example

Note the quoted `screen_signature` field:

```csv
session_id,started_at,condition,acuity_20x,shown_letter,response,is_correct,distance_cm,sizing_distance_cm,response_time_ms,trial_number,timestamp,sizing_version,calibration_source,points_per_mm,screen_signature,target_height_mm,rendered_height_points,weber_contrast
5B1E...,2026-08-03T20:15:02Z,highContrast,40,K,K,1,201.4,200.0,1840,1,2026-08-03T20:15:31Z,2,deviceDatabase,6.0367,"iPhone17,1|1206x2622|3.0000",5.818,35.13,0.10
5B1E...,2026-08-03T20:15:02Z,highContrast,40,V,V,1,199.8,199.8,1620,2,2026-08-03T20:15:35Z,2,deviceDatabase,6.0367,"iPhone17,1|1206x2622|3.0000",5.812,35.09,0.10
```

Loading in pandas or R needs no special handling — both honour RFC-4180 quoting by default:

```python
import pandas as pd
df = pd.read_csv("<sessionID>.csv")     # screen_signature comes back intact
```

---

## Interpretation values

| Value | When |
| --- | --- |
| `notComputed` | Session never reached a complete result |
| `highContrastBelowGate` | The 20/25 gate was not reached; low contrast was skipped |
| `redBetterThanGreen_deltaRecorded` | `duochromeDeltaLogMAR > 0` |
| `noRedGreenDifference_deltaRecorded` | `duochromeDeltaLogMAR ≤ 0` |

These are research labels. **No validated diagnostic threshold is applied** — the delta is recorded
raw for later analysis.

---

## Reading sessions back

`SessionStore.loadAllSessions()` returns every decodable session sorted newest-first by
`completedAt ?? startedAt`. Unreadable or undecodable files are skipped, so one corrupt file never
hides the rest. This backs the *Previous results* screen.
