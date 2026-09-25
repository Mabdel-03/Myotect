import ARKit
import SwiftUI

/// Root of the screening flow. Builds the coordinator with device-appropriate providers, switches
/// on `coordinator.phase`, and restores brightness on background / disappear.
struct ScreeningRootView: View {
    @StateObject private var coordinator: MyopiaScreenCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// The scored phase a pending Next confirmation would skip. Captured when the dialog opens,
    /// so a condition that finishes on its own while the dialog is up can never hand the Skip
    /// to the NEXT condition.
    @State private var pendingSkipPhase: ScreenPhase?
    @State private var showSkipConfirmation = false

    private let clinician: ManualClinicianService?
    private let whisperService: WhisperKitLetterRecognitionService?
    private let calibrationProvider: ScreenCalibrationProviding
    private let usingMocks: Bool

    /// `config` carries the operator-adjustable settings (contrast, TTS) sampled by the caller
    /// at presentation time; the coordinator freezes it for the whole session.
    init(config: ScreenConfig = ScreenConfig()) {
        // Calibration owns the pixels→points→millimeters conversion (built on nativeScale, so
        // downsampled Plus-class displays size correctly). DevicePpi resolves in the simulator
        // too, so the real provider serves both branches; unknown devices go through the manual
        // ruler flow gated in setup.
        let calibration = ScreenCalibrationProvider()
        let shortSide = Double(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height))
        calibrationProvider = calibration

        // Real ARKit + WhisperKit voice on supported hardware; mocks otherwise (simulator / unsupported).
        // The distance provider is headless and coordinator-owned: it runs from beginAfterSetup()
        // to teardown(), so live distance keeps flowing through warm-up and every trial.
        // The clinician keypad is always wired: it is the escalation target when voice input
        // fails repeatedly, and the sticky-manual fallback for a dead microphone.
        let manual = ManualClinicianService()

        let announcer = SpeechAnnouncer(config: config)

        if ARFaceTrackingConfiguration.isSupported {
            let ar = ARKitDistanceProvider(config: config)
            let speech = WhisperKitLetterRecognitionService(config: config)
            _coordinator = StateObject(wrappedValue: MyopiaScreenCoordinator(
                config: config, distance: ar, speech: speech, fallback: manual,
                announcer: announcer,
                calibration: calibration, screenShortSidePoints: shortSide))
            clinician = manual
            whisperService = speech
            usingMocks = false
        } else {
            let mock = MockDistanceProvider(steadyDistanceCM: config.targetDistanceCM, config: config)
            let mockSpeech = MockLetterRecognitionService()
            let coord = MyopiaScreenCoordinator(
                config: config, distance: mock, speech: mockSpeech, fallback: manual,
                announcer: announcer,
                calibration: calibration, screenShortSidePoints: shortSide)
            // In the simulator, answer correctly for whatever letter is shown so the flow runs.
            mockSpeech.setCorrectLetterProvider { [weak coord] in coord?.currentStimulus?.letter }
            _coordinator = StateObject(wrappedValue: coord)
            clinician = manual
            whisperService = nil
            usingMocks = true
        }
    }

    var body: some View {
        content
            .preferredColorScheme(.light)
            .overlay(alignment: .topLeading) { backButton }
            .overlay(alignment: .topTrailing) { nextButton }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background: coordinator.handleBackground()
                case .active: coordinator.handleForeground()
                default: break
                }
            }
            .onDisappear { coordinator.teardown() }
            .alert("Voice input unavailable",
                   isPresented: Binding(
                       get: { coordinator.serviceAlert != nil },
                       set: { if !$0 { coordinator.serviceAlert = nil } })) {
                if case .microphonePermissionDenied = coordinator.serviceAlert {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Use keypad", role: .cancel) {}
            } message: {
                Text(serviceAlertMessage)
            }
            .confirmationDialog("Skip this test?",
                                isPresented: $showSkipConfirmation,
                                titleVisibility: .visible,
                                presenting: pendingSkipPhase) { phase in
                Button("Skip", role: .destructive) {
                    // Only the phase the operator was looking at when the dialog opened.
                    if coordinator.phase == phase { coordinator.goNext() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { phase in
                Text("No result will be recorded for the \(skipTargetName(phase)) test.")
            }
    }

    /// Dialog wording: "high contrast", "low-contrast red", "low-contrast teal".
    private func skipTargetName(_ phase: ScreenPhase) -> String {
        phase.scoredCondition?.displayName.lowercased() ?? "current"
    }

    private var serviceAlertMessage: String {
        switch coordinator.serviceAlert {
        case .microphonePermissionDenied:
            return "Microphone access was turned off. The screening continues with the clinician keypad; enable the microphone in Settings to restore voice input."
        case .modelUnavailable(let message):
            return "The speech model is unavailable (\(message)). The screening continues with the clinician keypad."
        case .audioCaptureFailed(let message):
            return "Audio capture failed (\(message)). The screening continues with the clinician keypad."
        case nil:
            return ""
        }
    }

    /// A single Back control shared across the in-flow screens. Restarts the previous phase; from
    /// `.setup` (no predecessor) it dismisses the whole flow back to the main menu.
    @ViewBuilder
    private var backButton: some View {
        if showsBackButton {
            Button {
                if !coordinator.goBack() { dismiss() }
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .modifier(MyoFlowCapsule())
            }
            .padding()
        }
    }

    /// A single Next control shared across the in-flow test screens. Skips the current test (no
    /// result recorded) and advances to the start of the next phase. On a scored condition the
    /// skip is confirmed first — a dropped result is permanent, and a distance pause renders
    /// every phase as the same black field, so "unstick it" and "skip it" must not be the same
    /// gesture. Distance-lock and warm-up advance immediately. Not shown on `.setup`, where the
    /// permission-gated "Begin" button handles the transition.
    @ViewBuilder
    private var nextButton: some View {
        if showsNextButton {
            Button {
                if coordinator.phase.scoredCondition != nil {
                    pendingSkipPhase = coordinator.phase
                    showSkipConfirmation = true
                } else {
                    coordinator.goNext()
                }
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .modifier(MyoFlowCapsule())
            }
            .padding()
        }
    }

    private var showsBackButton: Bool {
        switch coordinator.phase {
        case .setup, .distanceLock, .warmup, .highContrastGate, .lowContrast:
            return true
        case .results, .aborted:
            return false
        }
    }

    private var showsNextButton: Bool {
        switch coordinator.phase {
        case .distanceLock, .warmup, .highContrastGate, .lowContrast:
            return true
        case .setup, .results, .aborted:
            return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .setup:
            SetupPermissionsView(coordinator: coordinator, usingMocks: usingMocks,
                                 whisperService: whisperService,
                                 calibrationProvider: calibrationProvider)
        case .distanceLock:
            DistanceLockView(coordinator: coordinator)
        case .warmup:
            WarmupView(coordinator: coordinator, clinician: clinician)
        case .highContrastGate, .lowContrast:
            AcuityTrialView(coordinator: coordinator, clinician: clinician)
        case .results:
            ResultsView(session: coordinator.session, onDone: { dismiss() })
        case .aborted(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.myoDestructive)
                Text("Screening Stopped")
                    .myoHeader()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(reason)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.myoGrayText)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .decorativeDaisies(.myoContentDaisies, over: .white)
        }
    }
}

/// The flow's Back/Next chrome: a light capsule that reads over both the white setup screens
/// and the black trial field (gold card border + soft shadow, teal label).
private struct MyoFlowCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.myoTeal)
            .padding(8)
            .background(Capsule().fill(Color.white.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.myoGrayBorder.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}
