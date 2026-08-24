import Foundation

/// Persists completed sessions to the app's Documents directory as JSON (full log) and CSV
/// (trial-level rows), retrievable via the Files app / Finder for research use.
///
/// By default no raw audio or face geometry is stored. Only the derived per-trial `distanceCM`
/// scalar (see `ScreenConfig.persistRawSignals`).
struct SessionStore {
    enum StoreError: Error { case noDocumentsDirectory }

    /// Subdirectory under Documents where sessions are written.
    static let directoryName = "MyopiaSessions"

    var fileManager: FileManager = .default

    /// Writes both JSON and CSV for a session. Returns the JSON file URL.
    @discardableResult
    func save(_ session: MyopiaScreenSession) throws -> URL {
        let dir = try sessionsDirectory()
        let jsonURL = dir.appendingPathComponent("\(session.sessionID).json")
        let csvURL = dir.appendingPathComponent("\(session.sessionID).csv")

        try encodeJSON(session).write(to: jsonURL)
        try Data(csv(for: session).utf8).write(to: csvURL)
        return jsonURL
    }

    func encodeJSON(_ session: MyopiaScreenSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }

    func decodeJSON(_ data: Data) throws -> MyopiaScreenSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MyopiaScreenSession.self, from: data)
    }

    /// Deletes every saved session file (JSON and CSV). Irreversible — callers confirm first.
    func deleteAllSessions() {
        guard let dir = try? sessionsDirectory(),
              let urls = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Writes the session's CSV to a temporary file for the share sheet. The temp directory is
    /// system-managed, so cleanup is best-effort.
    func temporaryCSVURL(for session: MyopiaScreenSession) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("myotect_\(session.sessionID).csv")
        try Data(csv(for: session).utf8).write(to: url)
        return url
    }

    /// Loads every saved session, newest first (by `completedAt ?? startedAt`). Unreadable or
    /// undecodable files are skipped so one bad file never hides the rest.
    func loadAllSessions() -> [MyopiaScreenSession] {
        guard let dir = try? sessionsDirectory() else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decodeJSON($0) }
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
    }

    /// One header row plus one row per trial.
    func csv(for session: MyopiaScreenSession) -> String {
        let header = [
            "session_id", "started_at", "condition", "acuity_20x", "shown_letter",
            "response", "is_correct", "distance_cm", "sizing_distance_cm", "response_time_ms",
            "trial_number", "timestamp",
            "sizing_version", "calibration_source", "points_per_mm", "screen_signature",
            "target_height_mm", "rendered_height_points",
            // Session-level constant repeated per row: with contrast operator-selectable, every
            // trial row must carry the Weber value that produced it. Appended last so columns
            // 1-18 stay positionally stable for existing analysis scripts.
            "weber_contrast",
        ].joined(separator: ",")

        let formatter = ISO8601DateFormatter()
        let startedAt = formatter.string(from: session.startedAt)

        let rows = session.trials.map { trial -> String in
            [
                session.sessionID,
                startedAt,
                trial.condition.rawValue,
                String(trial.acuityDenominator),
                trial.shownLetter,
                trial.response,
                trial.isCorrect ? "1" : "0",
                String(format: "%.1f", trial.distanceCM),
                trial.sizingDistanceCM.map { String(format: "%.1f", $0) } ?? "",
                String(trial.responseTimeMS),
                String(trial.trialNumber),
                formatter.string(from: trial.timestamp),
                trial.provenance.map { String($0.sizingVersion) } ?? "",
                trial.provenance?.calibrationSource.rawValue ?? "",
                trial.provenance.map { String(format: "%.4f", $0.pointsPerMillimeter) } ?? "",
                Self.csvField(trial.provenance?.screenSignature ?? ""),
                trial.provenance.map { String(format: "%.3f", $0.targetHeightMillimeters) } ?? "",
                trial.provenance.map { String(format: "%.2f", $0.renderedHeightPoints) } ?? "",
                String(format: "%.2f", session.weberContrast),
            ].joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    /// RFC-4180 quoting for a field that can contain commas: screen signatures embed the device
    /// machine identifier, which is "iPhone15,3"-shaped on every real device — unquoted it would
    /// misalign every provenance row.
    static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func sessionsDirectory() throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.noDocumentsDirectory
        }
        let dir = documents.appendingPathComponent(Self.directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
