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
            weberContrast: 0.10,
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

    /// `countsTowardStaircase` defaults to nil so every existing call site stays legacy-shaped
    /// (a row written before the flag existed).
    private func trial(_ condition: ColorCondition, n: Int,
                       response: String = "C", isCorrect: Bool = true,
                       countsTowardStaircase: Bool? = nil) -> TrialResult {
        TrialResult(condition: condition, acuityDenominator: 25, shownLetter: "C",
                    response: response, isCorrect: isCorrect, distanceCM: 200, responseTimeMS: 800,
                    trialNumber: n, timestamp: Date(timeIntervalSince1970: 1_700_000_050),
                    countsTowardStaircase: countsTowardStaircase)
    }

    func testJSONRoundTrip() throws {
        let store = SessionStore()
        let session = makeSession(trials: [trial(.highContrast, n: 1)])
        let data = try store.encodeJSON(session)
        let decoder = JSONDecoder()
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
                       "rendered_height_points", "weber_contrast", "counts_toward_staircase"] {
            XCTAssertTrue(lines[0].contains(column), "missing CSV column \(column)")
        }
        let headerFieldCount = lines[0].split(separator: ",", omittingEmptySubsequences: false).count
        for row in lines.dropFirst() {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                           headerFieldCount)
        }
    }

    func testCommaBearingScreenSignatureStaysAlignedInCSV() {
        // Real device identifiers contain commas ("iPhone15,3"); unquoted they would misalign
        // every provenance row.
        let provenance = SizingProvenance(
            sizingVersion: SizingProvenance.currentVersion,
            calibrationSource: .deviceDatabase,
            pointsPerMillimeter: 4.2782,
            screenSignature: "iPhone15,3|2796x1290|3.0000",
            targetHeightMillimeters: 5.818,
            renderedHeightPoints: 24.89)
        let trial = TrialResult(condition: .highContrast, acuityDenominator: 40, shownLetter: "C",
                                response: "C", isCorrect: true, distanceCM: 200,
                                responseTimeMS: 800, trialNumber: 1,
                                timestamp: Date(timeIntervalSince1970: 1_700_000_050),
                                provenance: provenance)
        let csv = SessionStore().csv(for: makeSession(trials: [trial]))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"iPhone15,3|2796x1290|3.0000\""))

        // Quote-aware field count of the data row must equal the header's.
        func fields(_ row: String) -> [String] {
            var out: [String] = []
            var current = ""
            var inQuotes = false
            for ch in row {
                if ch == "\"" { inQuotes.toggle() } else if ch == ",", !inQuotes {
                    out.append(current); current = ""
                } else { current.append(ch) }
            }
            out.append(current)
            return out
        }
        XCTAssertEqual(fields(lines[1]).count, fields(lines[0]).count)
    }

    func testCSVCarriesSessionWeberContrastOnEveryRow() {
        // With contrast operator-selectable, every trial row must carry the Weber value that
        // produced it (the JSON has it session-level; the CSV repeats it per row).
        var session = makeSession(trials: (1...2).map { trial(.lowContrastRed, n: $0) })
        session = MyopiaScreenSession(
            sessionID: session.sessionID, startedAt: session.startedAt,
            completedAt: session.completedAt, appVersion: session.appVersion,
            deviceModel: session.deviceModel, ppiUsed: session.ppiUsed,
            targetDistanceCM: session.targetDistanceCM, weberContrast: 0.15,
            letterSet: session.letterSet, highContrast: session.highContrast,
            lowContrastRed: session.lowContrastRed, lowContrastGreen: session.lowContrastGreen,
            duochromeDeltaLogMAR: session.duochromeDeltaLogMAR,
            interpretation: session.interpretation, trials: session.trials,
            aborted: session.aborted, abortReason: session.abortReason)

        let lines = SessionStore().csv(for: session).split(separator: "\n").map(String.init)
        // Column 19 is frozen; `counts_toward_staircase` was appended after it (column 20), so
        // the pin is positional, and the append-last rule is itself pinned.
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(String(header[18]), "weber_contrast")
        XCTAssertTrue(lines[0].hasSuffix(",counts_toward_staircase"))
        for row in lines.dropFirst() {
            XCTAssertEqual(String(row.split(separator: ",", omittingEmptySubsequences: false)[18]),
                           "0.15", "row missing weber contrast: \(row)")
        }
    }

    func testDeleteAllSessionsRemovesEverything() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(fileManager: TempDocumentsFileManager(root: root))
        try store.save(with(makeSession(), id: "a", completedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        try store.save(with(makeSession(), id: "b", completedAt: Date(timeIntervalSince1970: 1_700_000_500)))
        XCTAssertEqual(store.loadAllSessions().count, 2)

        store.deleteAllSessions()
        XCTAssertTrue(store.loadAllSessions().isEmpty)
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

    func testNonLetterResponseSentinelsStayUnquotedAndAlignedInCSVAndJSON() throws {
        // The sentinels are written verbatim; they contain spaces but never a comma, quote, or
        // newline, so the CSV stays 20 plain columns even for a parser that is not quote-aware.
        let sentinels = [TrialResult.NonLetterResponse.clinicianNoResponse,
                         TrialResult.NonLetterResponse.skipped,
                         TrialResult.NonLetterResponse.noInput]
        let trials = sentinels.enumerated().map { index, sentinel in
            trial(.highContrast, n: index + 1, response: sentinel, isCorrect: false)
        }
        let store = SessionStore()
        let session = makeSession(trials: trials)

        let lines = store.csv(for: session).split(separator: "\n").map(String.init)
        let headerCount = lines[0].split(separator: ",", omittingEmptySubsequences: false).count
        XCTAssertEqual(headerCount, 20)
        for (index, sentinel) in sentinels.enumerated() {
            let fields = lines[index + 1].split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            XCTAssertEqual(fields.count, headerCount, "row for \"\(sentinel)\" is misaligned")
            XCTAssertEqual(fields[5], sentinel)
            XCTAssertEqual(fields[6], "0")
            XCTAssertEqual(fields[19], "1", "a row without the flag is a counted legacy row")
            XCTAssertFalse(lines[index + 1].contains("\""), "\"\(sentinel)\" must not be quoted")
        }

        let restored = try store.decodeJSON(store.encodeJSON(session))
        XCTAssertEqual(restored.trials.map(\.response), sentinels)
        XCTAssertTrue(restored.trials.allSatisfy { !$0.isCorrect })
    }

    // MARK: - counts_toward_staircase (column 20)

    func testCountsTowardStaircaseRoundTripsThroughJSONAndCSVWithLegacyNilReadingAsOne() throws {
        let trials = [
            trial(.highContrast, n: 1, countsTowardStaircase: true),
            trial(.highContrast, n: 2, response: TrialResult.NonLetterResponse.noInput,
                  isCorrect: false, countsTowardStaircase: false),
            trial(.highContrast, n: 2),                       // legacy shape: flag absent
        ]
        let store = SessionStore()
        let session = makeSession(trials: trials)

        let lines = store.csv(for: session).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix(",counts_toward_staircase"))
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) },
                       ["1", "0", "1"])

        let restored = try store.decodeJSON(store.encodeJSON(session))
        XCTAssertEqual(restored.trials.map(\.countsTowardStaircase), [true, false, nil])
        XCTAssertEqual(restored, session)
    }

    /// A trial written before 2026-09-03 has no `countsTowardStaircase` key: it decodes as nil
    /// and is treated as counted — including the 09-02-era `no input registered` misses.
    func testLegacyTrialJSONWithoutTheFlagDecodesAsNilAndExportsAsCounted() throws {
        let legacy = """
        {"condition":"highContrast","acuityDenominator":40,"shownLetter":"C",
         "response":"no input registered","isCorrect":false,"distanceCM":200.0,
         "responseTimeMS":5200,"trialNumber":3,"timestamp":"2026-09-02T18:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let trial = try decoder.decode(TrialResult.self, from: Data(legacy.utf8))
        XCTAssertNil(trial.countsTowardStaircase)
        XCTAssertEqual(trial.response, TrialResult.NonLetterResponse.noInput)

        let store = SessionStore()
        let session = makeSession(trials: [trial])
        let lines = store.csv(for: session).split(separator: "\n")
        XCTAssertTrue(lines[1].hasSuffix(",1"), "legacy no-input rows were counted misses")
        // Re-encoding keeps the row legacy-shaped: nil is omitted, never written as null/false.
        let json = try XCTUnwrap(String(data: store.encodeJSON(session), encoding: .utf8))
        XCTAssertFalse(json.contains("countsTowardStaircase"))
    }
}
