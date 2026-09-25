import SwiftUI
import XCTest
@testable import Myotect

final class ContrastPaletteTests: XCTestCase {
    func testWeberFivePercent() {
        XCTAssertEqual(ContrastPalette.stimulusBrightness(background: 1.0, weber: 0.05), 0.95, accuracy: 1e-9)
    }

    func testWeberTenPercent() {
        XCTAssertEqual(ContrastPalette.stimulusBrightness(background: 1.0, weber: 0.10), 0.90, accuracy: 1e-9)
    }

    func testWeberMatchesMeetingExample() {
        // Meeting example: background 50%, stimulus 47.5% -> 5% Weber.
        XCTAssertEqual(ContrastPalette.stimulusBrightness(background: 0.50, weber: 0.05), 0.475, accuracy: 1e-9)
    }

    func testWeberFifteenPercent() {
        // 15% is a protocol-selectable value (Settings: 5/10/15/20%).
        XCTAssertEqual(ContrastPalette.stimulusBrightness(background: 1.0, weber: 0.15), 0.85, accuracy: 1e-9)
    }

    func testWeberTwentyPercent() {
        // 20% is the protocol default (nominal sRGB-channel contrast).
        XCTAssertEqual(ContrastPalette.stimulusBrightness(background: 1.0, weber: 0.20), 0.80, accuracy: 1e-9)
    }

    func testContrastConfigDefaultIsTwentyPercent() {
        // The protocol default is 20% Weber; the type default is pinned deliberately so it can
        // never silently drift from `ScreenConfig.lowContrastWeber` or the settings default.
        XCTAssertEqual(ContrastConfig().weber, 0.20, accuracy: 1e-9)
        XCTAssertEqual(ScreenConfig().lowContrastWeber, 0.20, accuracy: 1e-9)
        XCTAssertEqual(WeberContrastChoice.defaultChoice.rawValue, 0.20, accuracy: 1e-9)
    }

    func testHighContrastIsBlackOnWhite() {
        let colors = ContrastPalette.colors(for: .highContrast, config: ContrastConfig())
        XCTAssertEqual(colors.background, .white)
        XCTAssertEqual(colors.stimulus, .black)
    }

    func testRedConditionIsolatesRedChannel() {
        // Pins the behavior against an EXPLICIT weber, not the type default.
        let colors = ContrastPalette.colors(for: .lowContrastRed,
                                            config: ContrastConfig(weber: 0.10))
        let bg = colors.background.sRGBComponents
        let stim = colors.stimulus.sRGBComponents
        XCTAssertEqual(bg.green, 0, accuracy: 1e-6)
        XCTAssertEqual(bg.blue, 0, accuracy: 1e-6)
        XCTAssertEqual(stim.green, 0, accuracy: 1e-6)
        XCTAssertEqual(stim.red, 0.90, accuracy: 1e-3)
    }

    func testTealConditionIsBlueGreen() {
        // Short-wavelength condition is teal: green channel plus a matching fraction in blue, red at 0.
        // Weber contrast is preserved per channel (stimulus green is 0.90 of background at 10% Weber).
        let colors = ContrastPalette.colors(for: .lowContrastGreen,
                                            config: ContrastConfig(weber: 0.10))
        let bg = colors.background.sRGBComponents
        let stim = colors.stimulus.sRGBComponents
        let f = ContrastPalette.tealBlueFraction
        XCTAssertEqual(bg.red, 0, accuracy: 1e-6)
        XCTAssertEqual(Double(bg.green), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Double(bg.blue), 1.0 * f, accuracy: 1e-3)
        XCTAssertEqual(stim.red, 0, accuracy: 1e-6)
        XCTAssertEqual(Double(stim.green), 0.90, accuracy: 1e-3)
        XCTAssertEqual(Double(stim.blue), 0.90 * f, accuracy: 1e-3)
    }
}

private extension Color {
    /// Extracts sRGB components for assertions (test-only helper).
    var sRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
