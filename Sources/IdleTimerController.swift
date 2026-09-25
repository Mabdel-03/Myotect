import UIKit

/// Keeps the display awake for as long as the app is in the foreground, and restores the system
/// setting when it leaves.
///
/// The screening has long stretches with no touch input at all — the child stands 2 m away reading
/// letters aloud — so the system idle timer would dim and lock the screen mid-test, taking the
/// brightness lock the optotype sizing depends on with it. Scoped to the whole app rather than a
/// session: the menu, calibration, and results screens must stay lit too.
///
/// Mirrors ``BrightnessController``: a small UIKit-touching service with a disable/restore pair
/// that remembers the prior value once, so restoration is faithful and repeatable.
final class IdleTimerController {
    /// Whether the idle timer was already disabled before we touched it. Captured once.
    private var wasDisabled: Bool?

    /// Disables the system idle timer. Safe to call repeatedly — iOS can reset the flag across
    /// scene transitions, so it is re-asserted on every return to the foreground.
    func disableSleep() {
        if wasDisabled == nil {
            wasDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Restores the value captured by the first `disableSleep()`. Safe to call repeatedly.
    func restore() {
        if let wasDisabled {
            UIApplication.shared.isIdleTimerDisabled = wasDisabled
        }
        wasDisabled = nil
    }
}
