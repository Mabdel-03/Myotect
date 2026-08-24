import SwiftUI

/// Results screen in the gold ResultViewController format: gray surface, magenta "Results"
/// header, a white accent-strip card for the clinician/research detail, and standard buttons
/// (Done teal, Share blue). The child sees a simple thank-you; tapping reveals the detail. No
/// medical diagnosis is shown and interpretation thresholds are not set.
struct ResultsView: View {
    let session: MyopiaScreenSession?
    /// When provided, shows a "Done" button that exits the flow. Nil for read-only history detail.
    var onDone: (() -> Void)? = nil
    @State private var showClinicianDetail = false
    @State private var shareURL: URL?
    @State private var showExportError = false

    private let store = SessionStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Results")
                    .myoHeader()
                    .padding(.top, 26)
                Text("Early myopia screening summary")
                    .myoSmallText()

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.myoOkGreen)
                Text("Test complete. Thank you!")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(Color.black)
                    .multilineTextAlignment(.center)

                if showClinicianDetail, let session {
                    clinicianDetail(session)
                }

                VStack(spacing: 16) {
                    if let onDone {
                        Button("Done") { onDone() }
                            .buttonStyle(.myoPrimary)
                    }

                    if let session {
                        Button("Share") { share(session) }
                            .buttonStyle(.myoAction)
                    }

                    Button(showClinicianDetail ? "Hide details" : "Clinician details") {
                        showClinicianDetail.toggle()
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.myoActionBlue)
                }
                .padding(.top, 16)
                .padding(.bottom, 34)
            }
            .padding()
        }
        .decorativeDaisies(.myoResultsDaisies, over: .myoSurface)
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("Export Error", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The session CSV could not be written for sharing.")
        }
    }

    /// Writes the session CSV to a temp file and presents the system share sheet (the gold
    /// Share flow, minus the subject-name prompt Myotect deliberately does not collect). A
    /// failed write surfaces an alert (gold's Export Error), never a silently dead button.
    private func share(_ session: MyopiaScreenSession) {
        do {
            shareURL = try store.temporaryCSVURL(for: session)
        } catch {
            showExportError = true
        }
    }

    @ViewBuilder
    private func clinicianDetail(_ session: MyopiaScreenSession) -> some View {
        MyoCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Research Result")
                    .myoHeader2()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                row("High-contrast acuity", session.highContrast)
                row("Red low-contrast acuity", session.lowContrastRed)
                row("Teal low-contrast acuity", session.lowContrastGreen)
                if let delta = session.duochromeDeltaLogMAR {
                    Text(String(format: "Red-teal delta: %+.2f logMAR", delta))
                        .font(.system(size: 18).monospacedDigit())
                        .foregroundStyle(Color.black)
                }
                Text(String(format: "Low contrast: %.0f%% Weber", session.weberContrast * 100))
                    .font(.system(size: 18).monospacedDigit())
                    .foregroundStyle(Color.myoGrayText)
                let validTrials = session.trials.map(\.distanceCM)
                if !validTrials.isEmpty {
                    let mean = validTrials.reduce(0, +) / Double(validTrials.count)
                    Text(String(format: "Distance mean: %.0f cm (n=%d trials)", mean, validTrials.count))
                        .font(.system(size: 18).monospacedDigit())
                        .foregroundStyle(Color.myoGrayText)
                }
                Text("Interpretation threshold: research-only / TBD")
                    .font(.footnote)
                    .foregroundStyle(Color.myoGrayText)
                    .padding(.top, 4)
            }
        }
    }

    private func row(_ label: String, _ result: AcuityConditionResult?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 18))
                .foregroundStyle(Color.myoGrayText)
            Spacer()
            if let result {
                Text("20/\(result.finestAcuityDenominator)  (logMAR \(String(format: "%.2f", result.logMAR)))")
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("N/A")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.myoGrayText)
            }
        }
    }
}

/// UIKit share-sheet bridge (`UIActivityViewController`) — the gold app's share flow.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
