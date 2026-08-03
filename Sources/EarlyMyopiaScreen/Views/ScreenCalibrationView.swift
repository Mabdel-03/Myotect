import SwiftUI

/// Manual screen calibration for devices without a verified DevicePpi entry: the operator holds a
/// physical ruler against the screen and adjusts an on-screen line until it is exactly 50 mm,
/// which yields points-per-millimeter. SwiftUI port of the sibling app's ruler screen.
struct ScreenCalibrationView: View {
    let provider: ScreenCalibrationProviding
    var onSaved: (ScreenCalibration) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var rulerHeightPoints: Double = 220
    @State private var didSeed = false

    /// The physical length the operator matches the line against.
    private static let referenceMillimeters = 50.0
    private static let minimumRulerPoints = 180.0

    var body: some View {
        GeometryReader { geo in
            let maxRulerPoints = max(Self.minimumRulerPoints + 1, geo.size.height - 240)
            VStack(spacing: 16) {
                Text("Screen calibration")
                    .font(.title2.bold())
                Text("Hold a physical ruler against the screen and adjust the line until it measures exactly 50 mm, then save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 24) {
                    rulerLine
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Line length")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f pt", rulerHeightPoints))
                            .font(.title3.monospacedDigit())
                        Text(String(format: "→ %.3f pt/mm", rulerHeightPoints / Self.referenceMillimeters))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity)

                Slider(value: $rulerHeightPoints, in: Self.minimumRulerPoints...maxRulerPoints)
                    .padding(.horizontal)

                Button("Save calibration") {
                    if let calibration = provider.saveManualCalibration(
                        pointsPerMillimeter: rulerHeightPoints / Self.referenceMillimeters) {
                        onSaved(calibration)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding()
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                let seeded = provider.suggestedPointsPerMillimeter * Self.referenceMillimeters
                rulerHeightPoints = min(max(seeded, Self.minimumRulerPoints), maxRulerPoints)
            }
        }
        // Swiping the sheet away must not skip the explicit Save/Cancel decision.
        .interactiveDismissDisabled(true)
    }

    /// A vertical line with end ticks, pinned to the leading edge so a ruler can rest against it.
    private var rulerLine: some View {
        VStack(spacing: 0) {
            tick
            Rectangle()
                .frame(width: 2, height: rulerHeightPoints)
            tick
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Calibration line")
    }

    private var tick: some View {
        Rectangle().frame(width: 24, height: 2)
    }
}
