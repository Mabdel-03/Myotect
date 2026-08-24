import SwiftUI

/// The gold decorative daisy (`DaisyFlowerView` in the sibling app's UIStyle+Text.swift): 16
/// ellipse petals rotated about the center plus a filled center circle. Canvas is the direct
/// translation of the UIKit `draw(_:)` — two fill colors, per-petal rotation, one pass.
struct DaisyFlowerView: View {
    var petals: Int = 16
    let petalColor: Color
    let centerColor: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let minSide = min(size.width, size.height)
            let centerRadius = minSide / 8
            let petalLength = minSide / 2 - centerRadius
            let petalWidth = centerRadius * 0.8

            for i in 0..<petals {
                var petalContext = context
                petalContext.translateBy(x: center.x, y: center.y)
                petalContext.rotate(by: .radians(Double(i) * 2 * .pi / Double(petals)))
                let petalRect = CGRect(x: centerRadius, y: -petalWidth / 2,
                                       width: petalLength, height: petalWidth)
                petalContext.fill(Ellipse().path(in: petalRect), with: .color(petalColor))
            }

            let centerRect = CGRect(x: center.x - centerRadius, y: center.y - centerRadius,
                                    width: centerRadius * 2, height: centerRadius * 2)
            context.fill(Ellipse().path(in: centerRect), with: .color(centerColor))
        }
    }
}

/// One decorative daisy's size, colors, and screen position. Offsets are from the alignment
/// edge (gold's leading/top/trailing/bottom offsets, expressed as alignment + offset).
struct DaisyPlacement {
    var size: CGFloat
    var petal: Color
    var center: Color
    var alpha: Double
    var alignment: Alignment
    var offset: CGSize
}

extension [DaisyPlacement] {
    // Gold color rule: magenta daisies use the header magenta (#C92B5E) for PETALS and #CC3366
    // for the CENTER; teal daisies use brand teal petals with the #406D74 wordmark-teal center.

    /// Gold MainMenu: three daisies.
    static let myoMenuDaisies: [DaisyPlacement] = [
        .init(size: 120, petal: .myoTeal, center: .myoWordmarkTeal, alpha: 0.15,
              alignment: .topLeading, offset: CGSize(width: 10, height: 50)),
        .init(size: 110, petal: .myoMagenta, center: .myoDaisyMagenta, alpha: 0.10,
              alignment: .topTrailing, offset: CGSize(width: -15, height: 130)),
        .init(size: 100, petal: .myoTeal, center: .myoWordmarkTeal, alpha: 0.12,
              alignment: .bottomLeading, offset: CGSize(width: 20, height: -80)),
    ]

    /// Gold Instructions/Settings/DistanceOptimization pattern: top-right magenta, bottom-left teal.
    static let myoContentDaisies: [DaisyPlacement] = [
        .init(size: 110, petal: .myoMagenta, center: .myoDaisyMagenta, alpha: 0.08,
              alignment: .topTrailing, offset: CGSize(width: -20, height: 100)),
        .init(size: 100, petal: .myoTeal, center: .myoWordmarkTeal, alpha: 0.10,
              alignment: .bottomLeading, offset: CGSize(width: 15, height: -120)),
    ]

    /// Gold Results/TestHistory pattern: top-left teal, bottom-right magenta.
    static let myoResultsDaisies: [DaisyPlacement] = [
        .init(size: 115, petal: .myoTeal, center: .myoWordmarkTeal, alpha: 0.14,
              alignment: .topLeading, offset: CGSize(width: 12, height: 70)),
        .init(size: 105, petal: .myoMagenta, center: .myoDaisyMagenta, alpha: 0.11,
              alignment: .bottomTrailing, offset: CGSize(width: -17, height: -90)),
    ]
}

/// A placed daisy with the gold float animation (translationY −4, 2.8 s, autoreverse, staggered
/// 0.12 s per index). The repeat-forever animation is driven INSIDE this leaf view so it can
/// never leak onto sibling layout or phase transitions.
private struct FloatingDaisy: View {
    let placement: DaisyPlacement
    let index: Int
    @State private var floating = false

    var body: some View {
        DaisyFlowerView(petalColor: placement.petal.opacity(placement.alpha),
                        centerColor: placement.center.opacity(placement.alpha * 0.8))
            .frame(width: placement.size, height: placement.size)
            .offset(x: placement.offset.width,
                    y: placement.offset.height + (floating ? -4 : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
            .onAppear {
                // Re-arm on EVERY appearance (gold calls animateDecorativeDaisies from each
                // viewDidAppear): a view re-entering the hierarchy with `floating` still true
                // would otherwise sit frozen at the -4pt offset — the repeat-forever animation
                // only attaches on a state CHANGE, so reset without animation first, then
                // re-attach on the next main-actor turn.
                withTransaction(Transaction(animation: nil)) { floating = false }
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 2.8)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.12)) {
                        floating = true
                    }
                }
            }
    }
}

extension View {
    /// Gold `addDecorativeDaisy` + `animateDecorativeDaisies`: paints the page color with
    /// floating daisies over it, all BEHIND the content (gold's `sendSubviewToBack` keeps
    /// daisies above the view's backgroundColor but below every subview). The page fill lives
    /// INSIDE this modifier so no call-site `.background` ordering can ever occlude the
    /// daisies. Daisies never intercept touches or accessibility.
    func decorativeDaisies(_ placements: [DaisyPlacement], over pageColor: Color) -> some View {
        background {
            ZStack {
                pageColor
                ForEach(Array(placements.enumerated()), id: \.offset) { index, placement in
                    FloatingDaisy(placement: placement, index: index)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
