import SwiftUI

/// Results screen. The child sees a simple thank-you; tapping reveals the clinician/research
/// detail. No medical diagnosis is shown and interpretation thresholds are not set.
struct ResultsView: View {
    let session: MyopiaScreenSession?
    /// When provided, shows a "Done" button that exits the flow. Nil for read-only history detail.
    var onDone: (() -> Void)? = nil
    @State private var showClinicianDetail = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            Text("Test complete. Thank you!")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Spacer()

            if showClinicianDetail, let session {
                clinicianDetail(session)
            }

            if let onDone {
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
            }

            Button(showClinicianDetail ? "Hide details" : "Clinician details") {
                showClinicianDetail.toggle()
            }
            .font(.footnote)
            .padding(.bottom)
        }
        .padding()
    }

    @ViewBuilder
    private func clinicianDetail(_ session: MyopiaScreenSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Research result")
                .font(.headline)
            row("High-contrast acuity", session.highContrast)
            row("Red low-contrast acuity", session.lowContrastRed)
            row("Teal low-contrast acuity", session.lowContrastGreen)
            if let delta = session.duochromeDeltaLogMAR {
                Text(String(format: "Red-teal delta: %+.2f logMAR", delta))
            }
            let validTrials = session.trials.map(\.distanceCM)
            if !validTrials.isEmpty {
                let mean = validTrials.reduce(0, +) / Double(validTrials.count)
                Text(String(format: "Distance mean: %.0f cm (n=%d trials)", mean, validTrials.count))
                    .foregroundStyle(.secondary)
            }
            Text("Interpretation threshold: research-only / TBD")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ result: AcuityConditionResult?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let result {
                Text("20/\(result.finestAcuityDenominator)  (logMAR \(String(format: "%.2f", result.logMAR)))")
            } else {
                Text("N/A").foregroundStyle(.secondary)
            }
        }
    }
}
