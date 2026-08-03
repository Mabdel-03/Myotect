import UIKit

/// Sets a fixed screen brightness for the test and restores the user's original brightness on
/// exit, cancellation, completion, and backgrounding.
///
/// Brightness changes persist until the device locks, so restoration must be reliable. The
/// coordinator calls ``restore()`` on results, abort, and scene-background.
final class BrightnessController {
    private var originalBrightness: CGFloat?

    /// Sets brightness to `level` (0...1), remembering the prior value once.
    func lock(level: CGFloat) {
        if originalBrightness == nil {
            originalBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = max(0, min(1, level))
    }

    /// Restores the brightness captured by the first `lock(level:)`. Safe to call repeatedly.
    func restore() {
        if let original = originalBrightness {
            UIScreen.main.brightness = original
            originalBrightness = nil
        }
    }
}
