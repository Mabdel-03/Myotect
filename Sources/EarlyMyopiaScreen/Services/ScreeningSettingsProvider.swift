import Foundation

extension Notification.Name {
    /// Posted whenever the screening settings are saved or reset. Object is the new
    /// `ScreeningSettings` value.
    static let screeningSettingsDidChange = Notification.Name("screeningSettingsDidChange")
}

/// The protocol-approved Weber contrasts for the low-contrast conditions. Modeling the choice as
/// an enum makes invalid contrast values unrepresentable in memory — persistence-layer garbage is
/// rejected on read, never carried into a session.
enum WeberContrastChoice: Double, CaseIterable, Codable {
    case five = 0.05
    case ten = 0.10
    case fifteen = 0.15

    static let defaultChoice: WeberContrastChoice = .ten

    var label: String {
        switch self {
        case .five: return "5%"
        case .ten: return "10%"
        case .fifteen: return "15%"
        }
    }
}

/// The operator-adjustable screening settings, as one value.
struct ScreeningSettings: Equatable {
    var weberChoice: WeberContrastChoice = .defaultChoice
    /// Patient-facing spoken prompts. Defaults ON — Myotect's child-at-2-m flow depends on
    /// audio guidance (a documented divergence from the gold app's off-by-default).
    var audioEnabled: Bool = true
}

/// Supplies the operator-adjustable screening settings.
///
/// Injected (per Myotect DI style) rather than read from a singleton, so flows and previews are
/// testable with fixed settings.
protocol ScreeningSettingsProviding: AnyObject {
    var settings: ScreeningSettings { get }
    func save(_ settings: ScreeningSettings)
    func reset()
}

/// UserDefaults-backed settings store, following the `ScreenCalibrationProvider` pattern: one
/// JSON-encoded record under one key, self-invalidating on read (an undecodable record, a
/// schema mismatch, or a weber value outside the approved set is deleted on sight and the
/// defaults returned), with a notification on every save/reset.
final class ScreeningSettingsProvider: ScreeningSettingsProviding {
    /// The persistence record. `weber` is stored as a raw Double so a future choice-set change
    /// degrades to the default instead of failing to decode the whole record.
    private struct StoredSettings: Codable {
        let weber: Double
        let audioEnabled: Bool
        let schemaVersion: Int
    }

    static let schemaVersion = 1

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let storageKey = "ScreeningSettings"

    init(defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var settings: ScreeningSettings {
        guard let data = defaults.data(forKey: storageKey) else { return ScreeningSettings() }
        guard let stored = try? JSONDecoder().decode(StoredSettings.self, from: data),
              stored.schemaVersion == Self.schemaVersion,
              let choice = WeberContrastChoice.allCases.first(where: {
                  abs($0.rawValue - stored.weber) < 1e-9
              }) else {
            // Invalid records are deleted on sight so they can never resurface.
            defaults.removeObject(forKey: storageKey)
            return ScreeningSettings()
        }
        return ScreeningSettings(weberChoice: choice, audioEnabled: stored.audioEnabled)
    }

    func save(_ settings: ScreeningSettings) {
        let stored = StoredSettings(weber: settings.weberChoice.rawValue,
                                    audioEnabled: settings.audioEnabled,
                                    schemaVersion: Self.schemaVersion)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
        notificationCenter.post(name: .screeningSettingsDidChange, object: settings)
    }

    func reset() {
        defaults.removeObject(forKey: storageKey)
        notificationCenter.post(name: .screeningSettingsDidChange, object: ScreeningSettings())
    }
}

/// Fixed-settings double for tests and previews. Never touches UserDefaults.
final class StaticScreeningSettingsProvider: ScreeningSettingsProviding {
    private(set) var settings: ScreeningSettings

    init(settings: ScreeningSettings = ScreeningSettings()) {
        self.settings = settings
    }

    func save(_ settings: ScreeningSettings) {
        self.settings = settings
    }

    func reset() {
        settings = ScreeningSettings()
    }
}
