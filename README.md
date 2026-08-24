# Myotect

Myotect is an iOS research application for **distance-controlled visual acuity screening** in
grade-school children. It presents Sloan optotypes at a target viewing distance of ~2 m, measures
that distance continuously with the TrueDepth front camera, collects spoken letter responses
on-device, and records trial-level data for later analysis.

> **Myotect is a research screening instrument. It does not diagnose an eye condition and does not
> encode a clinically validated diagnostic threshold.** The red/green logMAR difference is recorded
> raw for later analysis; no cut-off is applied.

---

## Table of contents

| Document | What it covers |
| --- | --- |
| This file | Overview, quick start, repository layout, requirements |
| [docs/TESTING.md](docs/TESTING.md) | **Exhaustive testing guide** — unit suite, every test, on-device protocol, troubleshooting |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module-by-module design, the state machine, invariants |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The screening protocol and every tunable in `ScreenConfig` |
| [docs/DATA_FORMAT.md](docs/DATA_FORMAT.md) | JSON and CSV output schema, field by field |

---

## The screening protocol in one page

The flow is a linear state machine:

```
setup → distanceLock → warmup → highContrastGate → lowContrast(×2) → results
```

1. **Setup** — seven pre-flight checks must all pass before *Begin* is enabled: face tracking
   available, camera permission, microphone permission, speech model loaded, screen calibrated,
   Sloan font loaded, and the display physically large enough for the protocol's worst-case letter.
   If only the *voice* path is blocked, a **"Continue with clinician keypad"** fallback starts the
   session in manual mode; the sizing and distance prerequisites are never waivable.
2. **Distance lock** — the child is guided to ~2 m, then the OPERATOR captures the distance: the
   Capture button arms once a fresh reading sits inside **180–240 cm**, tapping it anchors a
   **2.0 s steady hold** (any reading drifting more than **±4 cm** from the tap-instant anchor, or
   losing the face, voids the hold with a spoken "try again"), and the mean of the hold window is
   recorded as `lockedDistanceCM`. Only hold completion advances — steady standing alone never does.
3. **Warm-up** — 5 unscored high-contrast letters at 20/80, so the child learns the task.
4. **High-contrast gate** — a black-on-white acuity staircase. The child must reach **20/25** to
   continue. Failing the gate ends the session with `interpretation = "highContrastBelowGate"`.
5. **Low contrast (duochrome)** — if the gate passes, the two low-contrast conditions run in
   **randomized order** at **10 % Weber contrast** by default (operator-selectable 5 / 10 / 15 %
   in Settings): dark-red-on-red and dark-teal-on-teal.
6. **Results** — the session is written to disk as JSON + CSV, including
   `duochromeDeltaLogMAR = green.logMAR − red.logMAR`.

Throughout, the app speaks short patient-facing prompts ("Say the letter you see.", "Move closer.",
"All done. Great job!"). Recognition never runs while the app is speaking, and repeated guidance is
throttled so it cannot become a chant. A trial that keeps failing to produce an answer gets a bounded
number of same-letter retries and then escalates to a clinician keypad — a dead microphone can never
cause a silent infinite loop.

The acuity staircase runs the ETDRS five-letter protocol (matching the reference app's
`ETDRSProgressionEngine`): 5 trials per level, advancing on ≥ 3 correct (or immediately when the
FIRST 3 are all correct, recorded as a perfect line), stepping back otherwise. The final logMAR is
scored letter-by-letter across BOTH terminal lines: `base(finer terminal line) + misses × 0.02`.
Levels run `200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16`, starting at 20/40.

Every condition draws the letter inside a fixed-size colored square framed by a blue border on a
black background. The square stays fixed across acuity levels; only the glyph changes size.

### Correctness invariants

These are enforced in code and covered by tests — they are the reason the app can claim a letter was
truly the size it says it was:

- **A scored letter is never sized from an assumed distance.** Sizing uses a fresh valid sample
  (never older than 0.5 s) or pauses. There is deliberately no nominal-distance fallback.
- **An answer is only scored against a fresh, in-band distance sample** taken at answer time — not
  the value captured at lock.
- **Sizing provenance is re-validated against the live calibration before scoring.** A mid-session
  calibration change pauses the trial instead of mis-scoring it.
- **A letter is never cropped.** If the glyph would not fit its square, the presentation pauses.
- **Distance leaving the band pauses the trial and cancels in-flight recognition.** Resuming needs
  both re-entry into an inset band (hysteresis) *and* a fresh dwell re-lock, so the boundary cannot
  chatter.
- **Live re-sizing is damped to half a physical pixel,** and a damped candidate never overwrites the
  visible spec — so recorded provenance always describes what was actually on screen.

---

## Quick start

```bash
git clone https://github.com/Mabdel-03/Myotect.git
cd Myotect
xcodegen generate                      # project.yml is the source of truth
open Myotect.xcodeproj                 # or build from the CLI, below
```

Build and run the unit suite:

```bash
xcodebuild -project Myotect.xcodeproj -scheme Myotect \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' test
```

> **Run `xcodegen generate` after every add, delete, or rename of a source file.** Sources are
> globbed from `Sources/` and `Tests/`; a stale `.xcodeproj` fails with
> `error: Build input files cannot be found`. See [docs/TESTING.md](docs/TESTING.md).

Full detail — destination selection, simulator-runtime pitfalls, the on-device protocol, and
per-test documentation — is in **[docs/TESTING.md](docs/TESTING.md)**.

---

## Requirements

| | |
| --- | --- |
| macOS / Xcode | Xcode 16 or later (developed against Xcode 26.6) |
| Deployment target | iOS 17.0 |
| Project generator | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Device (full function) | iPhone/iPad with a **TrueDepth** front camera for ARKit face tracking |
| Network | Required on the Mac for SPM resolution; required on the device on first launch **unless** the Whisper model is vendored (see below) |

Simulator builds compile and run the entire unit suite, and the flow is exercisable end-to-end with
mock providers. **ARKit face tracking and live microphone input do not work in the simulator** — a
physical device is required to validate those.

### Swift Package dependencies

Both are pinned to exact versions in `project.yml`:

| Package | Version | Purpose |
| --- | --- | --- |
| [DevicePpi](https://github.com/Clafou/DevicePpi) | `1.2.25` | Verified physical panel PPI per device model |
| [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) (`WhisperKit`) | `0.18.0` | On-device Whisper speech recognition |

### Speech model (WhisperKit)

The `openai_whisper-base` CoreML model (~140 MB) is **not tracked in this repository** — its
`TextDecoder` weight file alone is 99.3 MiB, within a rounding error of GitHub's 100 MiB hard limit.
This mirrors the sibling `VisualAcuityTest_ETDRS` app.

`WhisperKitLetterRecognitionService` prefers a bundled model at
`Sources/Resources/WhisperModels/openai_whisper-base/` and **falls back to
`WhisperKit.download(variant:)` on first launch** when it is absent. So a fresh clone works out of
the box provided the device has network access on first run. To run fully offline, drop the model
folder in and rebuild — `project.yml` already references `WhisperModels` as a *folder reference*
(not a glob) so the `.mlmodelc` directory tree is preserved in the bundle rather than flattened.

---

## Repository layout

```text
Myotect/
├── project.yml                  XcodeGen manifest — THE source of truth for the project
├── Myotect.xcodeproj/           Generated output (git-ignored; never edit by hand)
├── docs/                        Extended documentation
├── Sources/
│   ├── MyotectApp.swift         @main entry; registers the Sloan font at launch
│   ├── ContentView.swift        Main menu (Visinear format): Test, History, Settings
│   ├── Assets.xcassets/
│   ├── Resources/
│   │   ├── Sloan.otf            Optotype font (PostScript name "Sloan")
│   │   └── WhisperModels/       Model folder reference (contents git-ignored)
│   └── EarlyMyopiaScreen/
│       ├── Models/              MyopiaScreenSession, TrialResult, ColorCondition,
│       │                        ScreenPhase, SloanLetter, AcuityConditionResult
│       ├── Services/            OptotypeSizing, ScreenCalibrationProvider, ContrastPalette,
│       │                        SessionStore, BrightnessController, FontRegistrar
│       ├── Engine/              AcuityStaircaseEngine
│       ├── Distance/            DistanceProvider, DistanceModels, DistanceStabilityEvaluator,
│       │                        DistanceBandGate, DistanceGuidanceState,
│       │                        ARKitDistanceProvider, MockDistanceProvider
│       ├── Speech/              LetterRecognitionService, LetterMappingTable,
│       │                        WhisperKitLetterRecognitionService,
│       │                        ManualClinicianService, MockLetterRecognitionService
│       ├── Audio/               SpeechAnnouncer (patient-facing TTS), PromptThrottle
│       ├── Coordinator/         ScreenConfig, MyopiaScreenCoordinator, RetryEscalationPolicy
│       └── Views/               ScreeningRootView + one view per phase, OptotypeView,
│                                DistanceGuidancePill, ScreenCalibrationView, ResultsView,
│                                PreviousResultsView
└── Tests/                       174 XCTest unit tests across 18 files
```

Architecture is SwiftUI-first. ARKit/UIKit are isolated to the distance provider; all protocol logic
is view-agnostic and unit tested. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Data output

Completed sessions are written to the app's **Documents** directory under `MyopiaSessions/`,
retrievable via Finder or the Files app:

- `<sessionID>.json` — the complete session record, including the calibration in force and
  per-trial sizing provenance.
- `<sessionID>.csv` — one header row plus one row per scored trial (19 columns).

By default **no raw audio buffers and no face geometry are persisted** — only the derived
eye-to-screen distance scalar per trial. `ScreenConfig.persistRawSignals` is `false` by default and
should only be enabled under an approved research protocol with appropriate participant privacy
documentation.

Full schema: [docs/DATA_FORMAT.md](docs/DATA_FORMAT.md).

---

## Screen calibration

Optotype sizing needs a true points-to-millimeters conversion, so it cannot use a hard-coded scale.

- **Verified devices** calibrate automatically from the DevicePpi database:
  `pointsPerMillimeter = ppi / nativeScale / 25.4`.
- **Unknown devices** require a one-time operator ruler measurement (*Settings → Screen
  Calibration*): adjust an on-screen line until it measures exactly 50 mm against a physical ruler.

Calibration is bound to an exact screen signature (`machineIdentifier|WxH|nativeScale`) and schema
version. A stored record whose signature, native scale, or schema no longer matches is **deleted on
sight** so it can never resurface against different hardware.

`nativeScale` (not the logical `scale`) is deliberate: on downsampled Plus-class displays the
logical scale renders optotypes ~13 % undersized, a systematic acuity overestimate of roughly a full
line.

---

## Privacy and clinical positioning

- Front-camera video is used **only** to derive an eye-to-screen distance; no video is recorded.
- Audio is processed on-device for letter recognition and is not saved.
- Usage-description strings for camera, microphone, and speech are declared in `project.yml`.
- Before distribution, add a `UIRequiredDeviceCapabilities` entry if installation should be limited
  to ARKit-capable devices, and provide participant-facing privacy documentation.

---

## Status

The unit suite is **green: 174 tests, 0 failures** (iPhone 16 Pro / iOS 18.2, ~0.7 s).

Behavior that still requires validation on physical hardware — ARKit distance stability at 2 m,
audio-session coexistence between WhisperKit, the TTS announcer, and face tracking, and real
spoken-letter accuracy — is listed in
[docs/TESTING.md § On-device validation](docs/TESTING.md#part-3--on-device-validation).
