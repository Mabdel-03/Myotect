import SwiftUI

/// Shared trial UI for the high-contrast gate and the low-contrast conditions.
///
/// Shows the optotype with no scored correctness feedback to the child. Overlays a distance-pause
/// banner, an optional clinician keypad (when the manual service is in use), the operator-only
/// "Heard" line at the top in voice mode (`HeardDiagnosticLine`), and a debug panel gated behind
/// a developer flag.
struct AcuityTrialView: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator
    /// The manual clinician service, if that recognition path is active.
    var clinician: ManualClinicianService?
    /// Developer-only overlay (expected letter, etc.). Never shown to participants by default.
    var showDebugOverlay = false
    /// Hosts that already show a top pill (the warm-up) pass `false` and place the line
    /// themselves so the two never overlap.
    var showsHeardLine = true

    var body: some View {
        ZStack {
            if let stimulus = coordinator.currentStimulus {
                OptotypeView(
                    stimulus: stimulus,
                    squareSide: coordinator.squareSidePoints,
                    isBlanked: coordinator.isBlankInterval,
                    borderGap: coordinator.config.optotypeBorderGap,
                    borderWidth: coordinator.config.optotypeBorderWidth)
            } else {
                Color.black.ignoresSafeArea()
            }

            if coordinator.isPausedForDistance {
                DistanceGuidancePill(state: coordinator.guidance)
            }

            if let clinician, clinician.isAwaitingInput, !coordinator.isPausedForDistance {
                clinicianKeypad
            }

            if showOperatorStatus {
                operatorStatusStrip
            }

            if showsHeardLine {
                heardLine
            }

            if showDebugOverlay {
                debugOverlay
            }
        }
    }

    /// The operator strip appears in the debug overlay or whenever voice input has escalated —
    /// the clinician needs to see WHY the keypad appeared. Never meaningful to the child.
    private var showOperatorStatus: Bool {
        showDebugOverlay || coordinator.inputMode != .voice
    }

    /// Gold "VOICE INPUT ACTIVE" mic-pill treatment: mist surface with teal black-weight text —
    /// strong contrast over the black stimulus field without lightening it.
    private var operatorStatusStrip: some View {
        VStack {
            Spacer()
            MyoMicPill {
                HStack(spacing: 12) {
                    Text(operatorStatusText)
                    if case .manualFallback(sticky: true) = coordinator.inputMode {
                        Button("Resume voice input") { coordinator.clinicianRestoreVoiceInput() }
                            .foregroundStyle(Color.myoActionBlue)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Top-anchored below the Back/Next capsule row (`ScreeningRootView` overlays, ~90–100 pt at
    /// each top corner), so it never sits over the centred optotype and never meets the
    /// bottom-anchored keypad or operator strip.
    private var heardLine: some View {
        VStack {
            HeardDiagnosticLine(coordinator: coordinator)
                .padding(.top, 56)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var operatorStatusText: String {
        switch coordinator.listeningStatus {
        case .idle: return ""
        case .listening: return "Listening…"
        case .heardFiller: return "Heard hesitation (\"um\")"
        case .heardNothing: return "Heard nothing"
        case .heardUnintelligible: return "Heard speech — no letter"
        case .ambiguousAnswer: return "Heard more than one letter"
        case .speaking: return "Playing instructions"
        case .escalatedToClinician: return "Voice input paused — use keypad"
        case .micUnavailable: return "Microphone unavailable"
        }
    }

    private var clinicianKeypad: some View {
        VStack {
            Spacer()
            Text("Tap the letter the child said")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.bottom, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                ForEach(SloanLetter.all, id: \.self) { letter in
                    Button(letter) { coordinator.submitManual(letter: letter) }
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
            }
            Button("No response") { clinician?.submitNoResponse() }
                .padding(.top, 8)
                .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.6))
    }

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = coordinator.currentStimulus {
                Text("expected: \(s.letter)")
                Text("acuity: 20/\(s.acuityDenominator)")
                Text("font pt: \(Int(s.fontPoints))")
                Text(String(format: "target: %.2f mm", s.spec.targetHeightMillimeters))
                Text("calibration: \(s.spec.calibration.source.rawValue)")
            }
            Text(String(format: "dist: %.0f cm", coordinator.liveDistanceCM))
        }
        .font(.caption.monospaced())
        .foregroundStyle(.yellow)
        .padding(8)
        .background(.black.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
