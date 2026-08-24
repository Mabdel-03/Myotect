import SwiftUI

/// Operator settings in the gold Settings-screen format: centered magenta header, sections of
/// header2 title + gray description + control, and a standard Done button. Settings write
/// through to `ScreeningSettingsProvider` immediately; they apply to the NEXT screening (a
/// screening in progress captured its config at launch).
struct SettingsView: View {
    private let settingsProvider: ScreeningSettingsProviding
    @ObservedObject private var calibrationModel: SettingsCalibrationModel
    @Environment(\.dismiss) private var dismiss

    @State private var weberChoice: WeberContrastChoice
    @State private var audioEnabled: Bool
    @State private var showCalibrationSheet = false

    init(settingsProvider: ScreeningSettingsProviding = ScreeningSettingsProvider(),
         calibrationProvider: ScreenCalibrationProviding = ScreenCalibrationProvider()) {
        self.settingsProvider = settingsProvider
        self._calibrationModel = ObservedObject(
            wrappedValue: SettingsCalibrationModel(calibrationProvider))
        let settings = settingsProvider.settings
        self._weberChoice = State(initialValue: settings.weberChoice)
        self._audioEnabled = State(initialValue: settings.audioEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Settings")
                    .myoHeader()
                    .padding(.top, 20)

                contrastSection
                    .padding(.top, 30)

                audioSection
                    .padding(.top, 30)

                calibrationSection
                    .padding(.top, 30)

                Button("Done") { dismiss() }
                    .buttonStyle(.myoPrimary)
                    .padding(.top, 30)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .decorativeDaisies(.myoContentDaisies, over: .white)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showCalibrationSheet) {
            ScreenCalibrationView(provider: calibrationModel.provider)
        }
    }

    // MARK: - Sections (gold rhythm: +30 section, +5 title→description, +15 description→control)

    private var contrastSection: some View {
        VStack(spacing: 0) {
            Text("Low Contrast Level")
                .myoHeader2()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Weber contrast for the two low-contrast conditions. Applies to the next screening; a screening in progress is unaffected.")
                .myoSmallText()
                .multilineTextAlignment(.center)
                .padding(.top, 5)
            Picker("Low contrast level", selection: $weberChoice) {
                ForEach(WeberContrastChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .frame(height: 36)
            .padding(.top, 15)
            .onChange(of: weberChoice) { _, newValue in
                settingsProvider.save(ScreeningSettings(weberChoice: newValue,
                                                        audioEnabled: audioEnabled))
            }
        }
    }

    private var audioSection: some View {
        VStack(spacing: 0) {
            Text("Audio Instructions")
                .myoHeader2()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Spoken prompts and guidance during the screening")
                .myoSmallText()
                .multilineTextAlignment(.center)
                .padding(.top, 5)
            HStack {
                Text("🔊 Enable Audio Instructions")
                    .myoSmallText()
                Spacer()
                Toggle("", isOn: $audioEnabled)
                    .labelsHidden()
                    .tint(.myoTeal)
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.myoSurface))
            .padding(.top, 15)
            .onChange(of: audioEnabled) { _, newValue in
                settingsProvider.save(ScreeningSettings(weberChoice: weberChoice,
                                                        audioEnabled: newValue))
            }
        }
    }

    private var calibrationSection: some View {
        VStack(spacing: 0) {
            Text("Screen Calibration")
                .myoHeader2()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(calibrationStatusText)
                .myoSmallText()
                .multilineTextAlignment(.center)
                .padding(.top, 5)
            Button(calibrationButtonTitle) { showCalibrationSheet = true }
                .buttonStyle(.myoCompact)
                .disabled(!calibrationButtonEnabled)
                .padding(.top, 15)
        }
    }

    // Gold's three calibration states: automatic (button disabled), manual, required.
    private var calibrationStatusText: String {
        switch calibrationModel.status {
        case .validated(let calibration) where calibration.source == .deviceDatabase:
            return "Validated automatically for this display"
        case .validated:
            return "Validated with the 50 mm ruler"
        case .manualCalibrationRequired:
            return "Calibration required before testing"
        }
    }

    private var calibrationButtonTitle: String {
        switch calibrationModel.status {
        case .validated(let calibration) where calibration.source == .deviceDatabase:
            return "Automatic Calibration"
        case .validated:
            return "Recalibrate Screen"
        case .manualCalibrationRequired:
            return "Calibrate Screen"
        }
    }

    private var calibrationButtonEnabled: Bool {
        if case .validated(let calibration) = calibrationModel.status,
           calibration.source == .deviceDatabase {
            return false
        }
        return true
    }
}

/// Republishes the calibration provider's status so the Settings screen refreshes when a manual
/// calibration is saved or cleared (same template as the setup screen's observer).
private final class SettingsCalibrationModel: ObservableObject {
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

#Preview {
    SettingsView(settingsProvider: StaticScreeningSettingsProvider())
}
