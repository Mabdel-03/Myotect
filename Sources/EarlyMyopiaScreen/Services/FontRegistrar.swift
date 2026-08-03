import CoreText
import UIKit

/// Registers the bundled Sloan optotype font at launch.
///
/// We register programmatically rather than via Info.plist `UIAppFonts` because Myotect uses
/// `GENERATE_INFOPLIST_FILE: YES`, where the synthesized array key is unreliable. Call once from
/// `MyotectApp.init()`. After registration the font is available as `Font.custom("Sloan", size:)`.
///
/// Registration failure is observable (`status` / `sloanAvailable`) and gates the setup screen:
/// a silent system-font fallback would render non-optotype glyphs and invalidate the whole test,
/// so the failure must be loud. `OptotypeSizing.sloanBaseFont()` is the runtime backstop.
enum FontRegistrar {
    /// PostScript / family name of the bundled font (verified from Sloan.otf).
    static let sloanName = "Sloan"

    enum Status: Equatable {
        case unregistered
        case registered
        case failed(String)
    }

    private(set) static var status: Status = .unregistered

    /// True only when registration succeeded AND the font actually resolves by name — a
    /// registration "success" under a wrong PostScript name must not pass.
    static var sloanAvailable: Bool {
        status == .registered && UIFont(name: sloanName, size: 12) != nil
    }

    static func register() {
        guard status == .unregistered else { return }

        guard let url = Bundle.main.url(forResource: "Sloan", withExtension: "otf") else {
            status = .failed("Sloan.otf not found in the app bundle")
            return
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !registered, let error = error?.takeUnretainedValue() {
            // Already-registered is not fatal; anything else is only accepted if the font
            // still resolves below.
            print("Sloan font registration warning: \(error)")
        }
        if UIFont(name: sloanName, size: 12) != nil {
            status = .registered
        } else {
            status = .failed("The Sloan font did not resolve after registration")
        }
    }
}
