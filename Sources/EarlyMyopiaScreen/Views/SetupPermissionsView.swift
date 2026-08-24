import ARKit
import AVFoundation
import Combine
import SwiftUI

/// Pre-test setup: distance-test instructions, device/permission status rows, and the gate to
/// begin. Uses distance-test language only, with no near-test "hold the phone / flower" copy and no
/// swipe instructions.
///
/// Voice recognition is powered by WhisperKit (no Apple speech-recognition authorization needed).
/// The "Speech model" row reflects ``WhisperKitLetterRecognitionService/modelState`` and "Begin"
/// stays disabled until the model is loaded, so the first (warm-up) letter has a warm model.
struct SetupPermissionsView: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator
    /// True when running with mock providers (simulator); skips real permission requirements.
    var usingMocks: Bool
    /// The live WhisperKit service on real hardware; nil under mocks. Observed for `modelState`.
    @ObservedObject private var whisper: WhisperModelObserver
    /// Screen-calibration status, refreshed on `.screenCalibrationDidChange`.
    @ObservedObject private var calibrationModel: CalibrationStatusModel

    @State private var cameraGranted = false
    @State private var micGranted = false
    @State private var showCalibrationSheet = false

    init(coordinator: MyopiaScreenCoordinator,
         usingMocks: Bool,
         whisperService: WhisperKitLetterRecognitionService?,
         calibrationProvider: ScreenCalibrationProviding) {
        self.coordinator = coordinator
        self.usingMocks = usingMocks
        self._whisper = ObservedObject(wrappedValue: WhisperModelObserver(whisperService))
        self._calibrationModel = ObservedObject(wrappedValue: CalibrationStatusModel(calibrationProvider))
    }

    private var faceTrackingSupported: Bool {
        usingMocks || ARFaceTrackingConfiguration.isSupported
    }

    private var speechModelReady: Bool {
        usingMocks || whisper.modelState == .ready
    }

    private var speechModelRowTitle: String {
        if usingMocks { return "Speech model ready" }
        switch whisper.modelState {
        case .ready: return "Speech model ready"
        case .failed: return "Speech model failed to load"
        case .preparing(let phase): return "Preparing speech model — \(phase.label)…"
        case .none: return "Preparing speech model…"
        }
    }

    private var modelPrepFraction: Double? {
        guard !usingMocks, case .preparing(let phase)? = whisper.modelState else { return nil }
        // The download is the one long, measurable phase: interpolate its live fraction toward
        // the next phase's baseline so the bar moves through the whole ~140 MB fetch.
        if phase == .downloading {
            let next = WhisperKitLetterRecognitionService.ModelPrepPhase.initializing.fraction
            let span = next - phase.fraction
            return phase.fraction + span * min(max(whisper.downloadFraction, 0), 1)
        }
        return phase.fraction
    }

    /// Everything the keypad-only path still needs: sizing correctness + distance tracking +
    /// camera. Voice requirements (mic, model) deliberately excluded.
    private var canBeginWithKeypadOnly: Bool {
        faceTrackingSupported
            && isCalibrated
            && FontRegistrar.sloanAvailable
            && displayFits
            && (usingMocks || cameraGranted)
    }

    private var voicePathBlocked: Bool {
        guard !usingMocks else { return false }
        if case .failed = whisper.modelState { return true }
        return !micGranted
    }

    private var isCalibrated: Bool {
        if case .validated = calibrationModel.status { return true }
        return false
    }

    private var displayFits: Bool {
        coordinator.displayFitProblem == nil
    }

    /// Calibration, the optotype font, and the display fit are hard requirements even under
    /// mocks: sizing correctness does not depend on which providers are live.
    private var canBegin: Bool {
        faceTrackingSupported
            && isCalibrated
            && FontRegistrar.sloanAvailable
            && displayFits
            && (usingMocks || (cameraGranted && micGranted && speechModelReady))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Gold two-line screen title: 36pt bold black over a kerned magenta caps line.
                VStack(spacing: 4) {
                    Text("Early Myopia Screen")
                        .myoScreenTitle()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Screening Setup")
                        .myoTestTypeTitle()
                }
                .frame(maxWidth: .infinity)

                instructions

                VStack(spacing: 10) {
                    statusRow("Distance tracking available", ok: faceTrackingSupported)
                    statusRow("Camera permission", ok: cameraGranted || usingMocks)
                    statusRow("Microphone permission", ok: micGranted || usingMocks)
                    statusRow(speechModelRowTitle, ok: speechModelReady)
                    statusRow("Screen calibrated", ok: isCalibrated)
                    statusRow("Sloan optotype font loaded", ok: FontRegistrar.sloanAvailable)
                    statusRow("Display fits protocol letters", ok: displayFits)
                }

                // Informational, not a gate: the contrast the captured config will actually run
                // (the coordinator froze it at flow launch — not the live Settings value).
                Text("Low contrast: \(Int((coordinator.config.lowContrastWeber * 100).rounded()))% Weber")
                    .font(.footnote)
                    .foregroundStyle(Color.myoGrayText)

                if !isCalibrated {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This display is not in the verified device database. A one-time ruler measurement is required before testing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Calibrate screen") { showCalibrationSheet = true }
                            .buttonStyle(.bordered)
                            .tint(.myoActionBlue)
                    }
                }

                if !faceTrackingSupported {
                    Text("This device does not support front-camera face tracking, which is required to measure distance.")
                        .font(.footnote)
                        .foregroundStyle(Color.myoDestructive)
                }

                if !FontRegistrar.sloanAvailable {
                    Text("The Sloan optotype font failed to load; the test cannot render valid letters.")
                        .font(.footnote)
                        .foregroundStyle(Color.myoDestructive)
                }

                if let fitProblem = coordinator.displayFitProblem {
                    Text(fitProblem)
                        .font(.footnote)
                        .foregroundStyle(Color.myoDestructive)
                }

                if let fraction = modelPrepFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.myoTeal)
                }

                if !usingMocks, case .failed(let message) = whisper.modelState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speech model error: \(message)")
                            .font(.footnote)
                            .foregroundStyle(Color.myoDestructive)
                        Button("Retry loading") { coordinator.retryWhisperModelPreparation() }
                            .buttonStyle(.bordered)
                            .tint(.myoActionBlue)
                    }
                }

                if !usingMocks, !micGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Without microphone access the child's spoken answers cannot be heard.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.myoActionBlue)
                    }
                }

                Button("Begin") { coordinator.beginAfterSetup() }
                    .buttonStyle(.myoPrimary)
                    .disabled(!canBegin)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                if voicePathBlocked, canBeginWithKeypadOnly {
                    Button("Continue with clinician keypad") {
                        coordinator.beginAfterSetup(startInManualMode: true)
                    }
                    // Flexible width: this title is the app's longest and sits exactly at the
                    // 242pt style's scale floor — let it size to its content instead.
                    .buttonStyle(MyoPrimaryButtonStyle(background: .myoActionBlue, width: nil))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .decorativeDaisies(.myoContentDaisies, over: .white)
        .onAppear(perform: requestPermissions)
        .sheet(isPresented: $showCalibrationSheet) {
            ScreenCalibrationView(provider: calibrationModel.provider)
        }
    }

    private var instructions: some View {
        // Gold card treatment; body stays 16-18pt (not the 30pt drawInstruction — these lines
        // are long) with teal-tinted icons.
        MyoCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Place the phone on a stable stand with the screen facing the child.", systemImage: "iphone")
                Label("Have the child stand or sit about 2 meters away.", systemImage: "figure.stand")
                Label("The app will guide you closer or farther.", systemImage: "arrow.left.and.right")
                Label("Say each letter out loud when it appears.", systemImage: "mic")
                Text("This is a research screening test and does not diagnose an eye condition.")
                    .font(.footnote)
                    .foregroundStyle(Color.myoGrayText)
                    .padding(.top, 4)
            }
            .font(.callout)
            .foregroundStyle(Color.black)
            .tint(.myoTeal)
        }
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        // Gold Settings-row treatment: gray surface, radius 8.
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.myoOkGreen : Color.myoGrayText)
            Text(title)
                .foregroundStyle(Color.black)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.myoSurface))
    }

    private func requestPermissions() {
        guard !usingMocks else { return }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { cameraGranted = granted }
        }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }
}

/// Republishes the calibration provider's status so the setup view refreshes when a manual
/// calibration is saved or cleared.
private final class CalibrationStatusModel: ObservableObject {
    let provider: ScreenCalibrationProviding
    @Published private(set) var status: ScreenCalibrationStatus
    private var observer: NSObjectProtocol?

    init(_ provider: ScreenCalibrationProviding) {
        self.provider = provider
        self.status = provider.status
        observer = NotificationCenter.default.addObserver(
            forName: .screenCalibrationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.status = self.provider.status
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Republishes an optional `@MainActor` ``WhisperKitLetterRecognitionService``'s state so the setup
/// view can observe `modelState` through a non-optional `@ObservedObject`. Nil under mocks.
private final class WhisperModelObserver: ObservableObject {
    @Published private(set) var modelState: WhisperKitLetterRecognitionService.ModelState?
    /// Mirrors the service's download progress (meaningful only in `.preparing(.downloading)`).
    @Published private(set) var downloadFraction: Double = 0
    private var cancellables: [AnyCancellable] = []

    @MainActor
    init(_ service: WhisperKitLetterRecognitionService?) {
        self.modelState = service?.modelState
        self.downloadFraction = service?.downloadFraction ?? 0
        service?.$modelState.sink { [weak self] state in
            self?.modelState = state
        }.store(in: &cancellables)
        service?.$downloadFraction.sink { [weak self] fraction in
            self?.downloadFraction = fraction
        }.store(in: &cancellables)
    }
}
