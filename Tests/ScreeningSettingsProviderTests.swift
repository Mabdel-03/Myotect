import XCTest
@testable import Myotect

/// Pins the operator-settings store: defaults (10% Weber, audio on), round trips, the
/// self-invalidating read (garbage, schema mismatch, disallowed weber → defaults + record
/// deleted), and the change notification.
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

    func testEmptyDefaultsReturnTenPercentWithAudioOn() {
        let settings = provider.settings
        XCTAssertEqual(settings.weberChoice, .ten)
        XCTAssertTrue(settings.audioEnabled)
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
        let record = #"{"weber":0.2,"audioEnabled":false,"schemaVersion":1}"#
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
}
