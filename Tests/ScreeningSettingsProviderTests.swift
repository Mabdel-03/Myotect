import XCTest
@testable import Myotect

/// Pins the operator-settings store: defaults (20% Weber, audio on), round trips, the
/// self-invalidating read (garbage, unknown schema, disallowed weber → defaults + record
/// deleted), the one-time v1 → v2 upgrade, and the change notification.
final class ScreeningSettingsProviderTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var center: NotificationCenter!
    private var provider: ScreeningSettingsProvider!

    override func setUp() {
        super.setUp()
        suiteName = "ScreeningSettingsProviderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        center = NotificationCenter()
        provider = ScreeningSettingsProvider(defaults: defaults, notificationCenter: center)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEmptyDefaultsReturnTwentyPercentWithAudioOn() {
        let settings = provider.settings
        XCTAssertEqual(settings.weberChoice, .twenty)
        XCTAssertTrue(settings.audioEnabled)
    }

    func testTwentyPercentIsAnApprovedChoiceAndTheDefault() {
        XCTAssertTrue(WeberContrastChoice.allCases.contains(.twenty))
        XCTAssertEqual(WeberContrastChoice.twenty.rawValue, 0.20, accuracy: 1e-9)
        XCTAssertEqual(WeberContrastChoice.twenty.label, "20%")
        XCTAssertEqual(WeberContrastChoice.defaultChoice, .twenty)
        XCTAssertEqual(WeberContrastChoice.allCases.map(\.label), ["5%", "10%", "15%", "20%"])
    }

    func testSaveReadRoundTripForAllChoices() {
        for choice in WeberContrastChoice.allCases {
            for audio in [true, false] {
                provider.save(ScreeningSettings(weberChoice: choice, audioEnabled: audio))
                let settings = provider.settings
                XCTAssertEqual(settings.weberChoice, choice)
                XCTAssertEqual(settings.audioEnabled, audio)
            }
        }
    }

    func testGarbageRecordReturnsDefaultsAndDeletes() {
        defaults.set(Data("not json".utf8), forKey: "ScreeningSettings")
        XCTAssertEqual(provider.settings, ScreeningSettings())
        XCTAssertNil(defaults.data(forKey: "ScreeningSettings"),
                     "invalid record must be deleted on sight")
    }

    func testDisallowedWeberReturnsDefaultsAndDeletes() {
        // 0.3 is outside the approved set (0.2 became a valid choice with the 20% default).
        let record = #"{"weber":0.3,"audioEnabled":false,"schemaVersion":2}"#
        defaults.set(Data(record.utf8), forKey: "ScreeningSettings")
        XCTAssertEqual(provider.settings, ScreeningSettings())
        XCTAssertNil(defaults.data(forKey: "ScreeningSettings"))
    }

    func testSchemaMismatchReturnsDefaultsAndDeletes() {
        let record = #"{"weber":0.05,"audioEnabled":true,"schemaVersion":99}"#
        defaults.set(Data(record.utf8), forKey: "ScreeningSettings")
        XCTAssertEqual(provider.settings, ScreeningSettings())
        XCTAssertNil(defaults.data(forKey: "ScreeningSettings"))
    }

    func testSavePostsChangeNotificationWithNewSettings() {
        var received: ScreeningSettings?
        let observer = center.addObserver(forName: .screeningSettingsDidChange,
                                          object: nil, queue: nil) { note in
            received = note.object as? ScreeningSettings
        }
        defer { center.removeObserver(observer) }

        let saved = ScreeningSettings(weberChoice: .fifteen, audioEnabled: false)
        provider.save(saved)
        XCTAssertEqual(received, saved)
    }

    func testResetRestoresDefaultsAndNotifies() {
        provider.save(ScreeningSettings(weberChoice: .five, audioEnabled: false))
        var received: ScreeningSettings?
        let observer = center.addObserver(forName: .screeningSettingsDidChange,
                                          object: nil, queue: nil) { note in
            received = note.object as? ScreeningSettings
        }
        defer { center.removeObserver(observer) }

        provider.reset()
        XCTAssertEqual(provider.settings, ScreeningSettings())
        XCTAssertEqual(received, ScreeningSettings())
    }

    // MARK: - v1 → v2 upgrade (protocol default 10% → 20%)

    private func store(_ json: String) {
        defaults.set(Data(json.utf8), forKey: "ScreeningSettings")
    }

    private func storedSchemaVersion() -> Int? {
        guard let data = defaults.data(forKey: "ScreeningSettings"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["schemaVersion"] as? Int
    }

    func testLegacyImplicitTenPercentMovesToNewDefaultAndKeepsAudio() {
        // A v1 10% may have been written by the audio toggle alone (SettingsView persists both
        // fields on any change), so it is treated as "never chose": contrast → 20%, audio kept.
        store(#"{"weber":0.10,"audioEnabled":false,"schemaVersion":1}"#)
        let settings = provider.settings
        XCTAssertEqual(settings.weberChoice, .twenty)
        XCTAssertFalse(settings.audioEnabled)
        // Re-persisted under the current schema, so the upgrade runs exactly once.
        XCTAssertEqual(storedSchemaVersion(), ScreeningSettingsProvider.schemaVersion)
        XCTAssertEqual(provider.settings, settings)
    }

    func testLegacyExplicitChoicesSurviveTheUpgrade() {
        // 5% / 15% can only have come from the picker: an explicit study choice is kept.
        store(#"{"weber":0.05,"audioEnabled":true,"schemaVersion":1}"#)
        XCTAssertEqual(provider.settings, ScreeningSettings(weberChoice: .five, audioEnabled: true))
        XCTAssertEqual(storedSchemaVersion(), ScreeningSettingsProvider.schemaVersion)
        store(#"{"weber":0.15,"audioEnabled":false,"schemaVersion":1}"#)
        XCTAssertEqual(provider.settings, ScreeningSettings(weberChoice: .fifteen, audioEnabled: false))
    }

    func testLegacyRecordWithDisallowedWeberIsDeleted() {
        store(#"{"weber":0.3,"audioEnabled":false,"schemaVersion":1}"#)
        XCTAssertEqual(provider.settings, ScreeningSettings())
        XCTAssertNil(defaults.data(forKey: "ScreeningSettings"))
    }

    func testUnknownSchemaVersionsAreDeletedOnSight() {
        for version in [0, ScreeningSettingsProvider.schemaVersion + 1] {
            store(#"{"weber":0.05,"audioEnabled":true,"schemaVersion":\#(version)}"#)
            XCTAssertEqual(provider.settings, ScreeningSettings(), "schema \(version)")
            XCTAssertNil(defaults.data(forKey: "ScreeningSettings"), "schema \(version)")
        }
    }

    func testUpgradeDoesNotPostChangeNotification() {
        var received = 0
        let observer = center.addObserver(forName: .screeningSettingsDidChange,
                                          object: nil, queue: nil) { _ in received += 1 }
        defer { center.removeObserver(observer) }
        store(#"{"weber":0.10,"audioEnabled":true,"schemaVersion":1}"#)
        _ = provider.settings
        XCTAssertEqual(received, 0, "a getter must not fan out UI updates")
    }
}
