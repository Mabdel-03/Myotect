import XCTest
@testable import Myotect

/// A FileManager that redirects the Documents directory to a per-test temp directory, so
/// `SessionStore` reads and writes in isolation without touching the real app sandbox.
private final class TempDocumentsFileManager: FileManager {
    let root: URL
    init(root: URL) {
        self.root = root
        super.init()
    }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .documentDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

final class SessionStoreTests: XCTestCase {

    private func makeSession(trials: [TrialResult] = [],
                             red: AcuityConditionResult? = nil,
                             green: AcuityConditionResult? = nil) -> MyopiaScreenSession {
        var s = MyopiaScreenSession(
            sessionID: "test-session",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_100),
            appVersion: "1.0",
            deviceModel: "iPhone",
            ppiUsed: 326,
            targetDistanceCM: 200,
            weberContrast: 0.05,
            letterSet: SloanLetter.all,
            highContrast: nil,
            lowContrastRed: red,
            lowContrastGreen: green,
            duochromeDeltaLogMAR: nil,
            interpretation: "test",
            trials: trials,
            aborted: false,
            abortReason: nil)
        s.recomputeDelta()
        return s
    }

    private func trial(_ condition: ColorCondition, n: Int) -> TrialResult {
        TrialResult(condition: condition, acuityDenominator: 25, shownLetter: "C",
                    response: "C", isCorrect: true, distanceCM: 200, responseTimeMS: 800,
                    trialNumber: n, timestamp: Date(timeIntervalSince1970: 1_700_000_050))
    }

    func testJSONRoundTrip() throws {
        let store = SessionStore()
        let session = makeSession(trials: [trial(.highContrast, n: 1)])
        let data = try store.encodeJSON(session)
        var decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(MyopiaScreenSession.self, from: data)
        XCTAssertEqual(restored.sessionID, session.sessionID)
        XCTAssertEqual(restored.trials.count, 1)
        XCTAssertEqual(restored.trials.first?.shownLetter, "C")
    }

    func testCSVRowCountMatchesTrials() {
        let store = SessionStore()
        let trials = (1...3).map { trial(.lowContrastRed, n: $0) }
        let csv = store.csv(for: makeSession(trials: trials))
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 4) // header + 3 trials
        XCTAssertTrue(lines[0].contains("session_id"))
        // Provenance and sizing-distance columns are always present; legacy trials leave them empty.
        for column in ["sizing_distance_cm", "sizing_version", "calibration_source",
                       "points_per_mm", "screen_signature", "target_height_mm",
                       "rendered_height_points"] {
            XCTAssertTrue(lines[0].contains(column), "missing CSV column \(column)")
        }
        let headerFieldCount = lines[0].split(separator: ",", omittingEmptySubsequences: false).count
        for row in lines.dropFirst() {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                           headerFieldCount)
        }
    }

    func testDeltaIsGreenMinusRed() {
        let red = AcuityConditionResult(condition: .lowContrastRed, finestAcuityDenominator: 25, logMAR: 0.10, reachedGate: true)
        let green = AcuityConditionResult(condition: .lowContrastGreen, finestAcuityDenominator: 32, logMAR: 0.20, reachedGate: true)
        let session = makeSession(red: red, green: green)
        XCTAssertEqual(session.duochromeDeltaLogMAR ?? 0, 0.10, accuracy: 1e-9)
    }

    func testDeltaNilWhenMissingCondition() {
        let red = AcuityConditionResult(condition: .lowContrastRed, finestAcuityDenominator: 25, logMAR: 0.10, reachedGate: true)
        XCTAssertNil(makeSession(red: red, green: nil).duochromeDeltaLogMAR)
    }

    func testDecodeJSONRoundTrip() throws {
        let store = SessionStore()
        let session = makeSession(trials: [trial(.highContrast, n: 1)])
        let restored = try store.decodeJSON(store.encodeJSON(session))
        XCTAssertEqual(restored, session)
    }

    func testLoadAllSessionsReturnsSavedSessionsNewestFirst() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(fileManager: TempDocumentsFileManager(root: root))
        XCTAssertTrue(store.loadAllSessions().isEmpty)   // empty state

        var older = makeSession()
        older = with(older, id: "older", completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var newer = makeSession()
        newer = with(newer, id: "newer", completedAt: Date(timeIntervalSince1970: 1_700_000_500))
        try store.save(older)
        try store.save(newer)

        let loaded = store.loadAllSessions()
        XCTAssertEqual(loaded.map(\.sessionID), ["newer", "older"])
    }

    /// Returns a copy of `session` with a new id and completion date (the fields the loader sorts by).
    private func with(_ session: MyopiaScreenSession, id: String, completedAt: Date) -> MyopiaScreenSession {
        MyopiaScreenSession(
            sessionID: id,
            startedAt: session.startedAt,
            completedAt: completedAt,
            appVersion: session.appVersion,
            deviceModel: session.deviceModel,
            ppiUsed: session.ppiUsed,
            targetDistanceCM: session.targetDistanceCM,
            weberContrast: session.weberContrast,
            letterSet: session.letterSet,
            highContrast: session.highContrast,
            lowContrastRed: session.lowContrastRed,
            lowContrastGreen: session.lowContrastGreen,
            duochromeDeltaLogMAR: session.duochromeDeltaLogMAR,
            interpretation: session.interpretation,
            trials: session.trials,
            aborted: session.aborted,
            abortReason: session.abortReason)
    }
}
