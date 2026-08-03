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
                Text("Early Myopia Screen")
                    .font(.largeTitle.bold())

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

                if !isCalibrated {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This display is not in the verified device database. A one-time ruler measurement is required before testing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Calibrate screen") { showCalibrationSheet = true }
                            .buttonStyle(.bordered)
                    }
                }

                if !faceTrackingSupported {
                    Text("This device does not support front-camera face tracking, which is required to measure distance.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if !FontRegistrar.sloanAvailable {
                    Text("The Sloan optotype font failed to load; the test cannot render valid letters.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let fitProblem = coordinator.displayFitProblem {
                    Text(fitProblem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let fraction = modelPrepFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }

                if !usingMocks, case .failed(let message) = whisper.modelState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speech model error: \(message)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Retry loading") { coordinator.retryWhisperModelPreparation() }
                            .buttonStyle(.bordered)
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
                    }
                }

                Button("Begin") { coordinator.beginAfterSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canBegin)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                if voicePathBlocked, canBeginWithKeypadOnly {
                    Button("Continue with clinician keypad") {
                        coordinator.beginAfterSetup(startInManualMode: true)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .onAppear(perform: requestPermissions)
        .sheet(isPresented: $showCalibrationSheet) {
            ScreenCalibrationView(provider: calibrationModel.provider)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Place the phone on a stable stand with the screen facing the child.", systemImage: "iphone")
            Label("Have the child stand or sit about 2 meters away.", systemImage: "figure.stand")
            Label("The app will guide you closer or farther.", systemImage: "arrow.left.and.right")
            Label("Say each letter out loud when it appears.", systemImage: "mic")
            Text("This is a research screening test and does not diagnose an eye condition.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .font(.callout)
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(title)
            Spacer()
        }
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
    private var cancellable: AnyCancellable?

    @MainActor
    init(_ service: WhisperKitLetterRecognitionService?) {
        self.modelState = service?.modelState
        cancellable = service?.$modelState.sink { [weak self] state in
            self?.modelState = state
        }
    }
}
