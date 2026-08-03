import SwiftUI

/// Renders a single Sloan optotype centered inside a fixed-size colored square, wrapped by the
/// accommodation-relaxing blue border square, all on a black screen background.
///
/// The colored square is a fixed size (``squareSide``) for every condition and every trial — it
/// does not shrink as the letter shrinks across acuity steps. The side is derived per device from
/// the worst-case letter (see ``ScreenConfig/optotypeSquareSide(calibration:screenShortSidePoints:)``),
/// and the coordinator refuses to present any spec that does not fit, so the glyph is never
/// clipped — a cropped letter that still gets scored would be the worst clinical failure mode.
struct OptotypeView: View {
    let stimulus: MyopiaScreenCoordinator.Stimulus
    /// Side length (points) of the colored square holding the letter, derived by the coordinator.
    let squareSide: Double
    /// Gap (points) on each side between the colored square and the blue border square.
    var borderGap: Double = 14
    /// Line width (points) of the blue border square.
    var borderWidth: Double = 8

    private var borderSide: Double { squareSide + 2 * borderGap }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            stimulus.colors.background
                .frame(width: squareSide, height: squareSide)
                .overlay {
                    Text(stimulus.letter)
                        .font(.custom(FontRegistrar.sloanName, fixedSize: stimulus.fontPoints))
                        .foregroundStyle(stimulus.colors.stimulus)
                }

            // The blue border square wrapping the colored square with a small gap.
            Rectangle()
                .strokeBorder(ContrastPalette.blueFrame, lineWidth: borderWidth)
                .frame(width: borderSide, height: borderSide)
        }
        .onAppear {
            // Belt-and-suspenders: the coordinator's fitsSquare guard makes an oversized glyph
            // unpresentable, so reaching this assertion means that guard regressed.
            assert(Double(stimulus.spec.renderedHeightPoints) <= squareSide,
                   "Optotype cap height exceeds the presentation square")
        }
    }
}
