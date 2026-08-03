import SwiftUI

/// Lists previously saved screening sessions (newest first) and opens each one's clinician detail
/// by reusing `ResultsView`. Sessions are read back from `Documents/MyopiaSessions/` via `SessionStore`.
struct PreviousResultsView: View {
    @State private var sessions: [MyopiaScreenSession] = []
    private let store = SessionStore()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView("No saved screenings",
                                       systemImage: "tray",
                                       description: Text("Completed screenings will appear here."))
            } else {
                List(sessions, id: \.sessionID) { session in
                    NavigationLink {
                        ResultsView(session: session)   // no onDone means read-only history detail
                    } label: {
                        row(session)
                    }
                }
            }
        }
        .navigationTitle("Previous results")
        .onAppear { sessions = store.loadAllSessions() }
    }

    private func row(_ session: MyopiaScreenSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.formatter.string(from: session.completedAt ?? session.startedAt))
            if let delta = session.duochromeDeltaLogMAR {
                Text(String(format: "Red-teal delta %+.2f logMAR", delta))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
