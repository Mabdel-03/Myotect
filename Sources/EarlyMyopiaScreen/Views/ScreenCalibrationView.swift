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
    /// Vertical chrome (padding) reserved around the line; everything else sits beside it, so the
    /// line can use nearly the whole screen height (matching the gold screen's reach — a short
    /// ceiling would make dense/tall displays impossible to calibrate).
    private static let verticalChromePoints = 60.0

    var body: some View {
        GeometryReader { geo in
            let maxRulerPoints = max(Self.minimumRulerPoints + 1,
                                     geo.size.height - Self.verticalChromePoints)
            HStack(spacing: 24) {
                rulerLine
                    .frame(maxHeight: .infinity)

                VStack(spacing: 16) {
                    Text("Screen Calibration")
                        .myoHeader2()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Hold a physical ruler against the screen and adjust the line until it measures exactly 50 mm, then save.")
                        .myoSmallText()
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Line length")
                            .font(.footnote)
                            .foregroundStyle(Color.myoGrayText)
                        Text(String(format: "%.1f pt", rulerHeightPoints))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(Color.black)
                        Text(String(format: "→ %.3f pt/mm", rulerHeightPoints / Self.referenceMillimeters))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.myoGrayText)
                    }

                    Slider(value: $rulerHeightPoints, in: Self.minimumRulerPoints...maxRulerPoints)
                        .tint(.myoTeal)
                        .padding(.horizontal)

                    Button("Save Calibration") {
                        if let calibration = provider.saveManualCalibration(
                            pointsPerMillimeter: rulerHeightPoints / Self.referenceMillimeters) {
                            onSaved(calibration)
                            dismiss()
                        }
                    }
                    .buttonStyle(.myoCompact)

                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.myoGrayText)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .background(Color.white)
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                let seeded = provider.suggestedPointsPerMillimeter * Self.referenceMillimeters
                rulerHeightPoints = min(max(seeded, Self.minimumRulerPoints), maxRulerPoints)
            }
        }
        // Swiping the sheet away must not skip the explicit Save/Cancel decision.
        .interactiveDismissDisabled(true)
        // Sheet presentation root: pin the light-only design (and the ruler's black-on-white
        // contrast) regardless of the system appearance.
        .preferredColorScheme(.light)
    }

    /// A vertical line with end ticks, pinned to the leading edge so a ruler can rest against it.
    /// The ticks are OVERLAID on the line's ends, so the total visible mark-to-mark extent equals
    /// `rulerHeightPoints` exactly — the length the operator matches to 50 mm and the length the
    /// points-per-millimeter division uses. (Stacking the ticks outside the line would silently
    /// add their thickness to what the operator measures, skewing every optotype small.)
    private var rulerLine: some View {
        ZStack {
            Rectangle()
                .frame(width: 2, height: rulerHeightPoints)
            VStack(spacing: 0) {
                tick
                Spacer(minLength: 0)
                tick
            }
            .frame(height: rulerHeightPoints)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Calibration line")
    }

    private var tick: some View {
        Rectangle().frame(width: 24, height: 2)
    }
}
