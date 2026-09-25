import Foundation

extension Notification.Name {
    /// Posted whenever the screening settings are saved or reset. Object is the new
    /// `ScreeningSettings` value.
    static let screeningSettingsDidChange = Notification.Name("screeningSettingsDidChange")
}

/// The protocol-approved Weber contrasts for the low-contrast conditions (5 / 10 / 15 / 20 %;
/// 20 % is the protocol default). Modeling the choice as an enum makes invalid contrast values
/// unrepresentable in memory — persistence-layer garbage is rejected on read, never carried into
/// a session. Values are nominal sRGB-channel contrast (see `ContrastPalette`).
enum WeberContrastChoice: Double, CaseIterable, Codable {
    case five = 0.05
    case ten = 0.10
    case fifteen = 0.15
    case twenty = 0.20

    static let defaultChoice: WeberContrastChoice = .twenty

    var label: String {
        switch self {
        case .five: return "5%"
        case .ten: return "10%"
        case .fifteen: return "15%"
        case .twenty: return "20%"
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
/// JSON-encoded record under one key, self-invalidating on read (an undecodable record, an
/// unknown schema, or a weber value outside the approved set is deleted on sight and the
/// defaults returned), with a notification on every save/reset.
///
/// The one exception to delete-on-sight is the **v1 → v2 upgrade** (the 2026-09 change of the
/// protocol default from 10 % to 20 %): a v1 record keeps its audio choice, and its contrast is
/// kept only when it is an explicit non-default pick. `SettingsView` persists BOTH fields on any
/// change, so a v1 record holding the old 10 % default may have been written by the audio toggle
/// alone and is indistinguishable from "never chose" — it moves to the new default; 5 % / 15 %
/// can only have come from the picker and survive. The upgraded record is re-persisted as v2 at
/// once (without a notification — a getter must not fan out UI updates). Rolling back to a
/// schema-1 build discards a v2 record (both controls revert to that build's defaults).
final class ScreeningSettingsProvider: ScreeningSettingsProviding {
    /// The persistence record. `weber` is stored as a raw Double so a future choice-set change
    /// degrades to the default instead of failing to decode the whole record.
    private struct StoredSettings: Codable {
        let weber: Double
        let audioEnabled: Bool
        let schemaVersion: Int
    }

    static let schemaVersion = 2
    /// The schema whose records are upgraded rather than deleted (see the class doc).
    private static let legacySchemaVersion = 1
    /// The default the legacy schema shipped with — the only value the audio toggle could have
    /// persisted implicitly.
    private static let legacyDefaultWeber = 0.10

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
              let choice = WeberContrastChoice.allCases.first(where: {
                  abs($0.rawValue - stored.weber) < 1e-9
              }) else {
            // Invalid records are deleted on sight so they can never resurface.
            defaults.removeObject(forKey: storageKey)
            return ScreeningSettings()
        }
        switch stored.schemaVersion {
        case Self.schemaVersion:
            return ScreeningSettings(weberChoice: choice, audioEnabled: stored.audioEnabled)
        case Self.legacySchemaVersion:
            let upgraded = Self.upgradeFromLegacy(weber: choice, audioEnabled: stored.audioEnabled)
            persist(upgraded)
            return upgraded
        default:
            defaults.removeObject(forKey: storageKey)
            return ScreeningSettings()
        }
    }

    /// The v1 → v2 rule (class doc): audio carries over; the old implicit default moves to the
    /// new default; an explicit non-default pick is kept.
    static func upgradeFromLegacy(weber: WeberContrastChoice, audioEnabled: Bool) -> ScreeningSettings {
        let isLegacyDefault = abs(weber.rawValue - legacyDefaultWeber) < 1e-9
        return ScreeningSettings(weberChoice: isLegacyDefault ? .defaultChoice : weber,
                                 audioEnabled: audioEnabled)
    }

    func save(_ settings: ScreeningSettings) {
        persist(settings)
        notificationCenter.post(name: .screeningSettingsDidChange, object: settings)
    }

    /// Writes the record under the current schema without notifying.
    private func persist(_ settings: ScreeningSettings) {
        let stored = StoredSettings(weber: settings.weberChoice.rawValue,
                                    audioEnabled: settings.audioEnabled,
                                    schemaVersion: Self.schemaVersion)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
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
