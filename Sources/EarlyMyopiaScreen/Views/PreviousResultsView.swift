import SwiftUI

/// Test history in the gold TestHistoryViewController format: gray surface, white row cards,
/// per-session Share, and a destructive Clear All History with confirmation. Opens each
/// session's clinician detail by reusing `ResultsView`. Sessions are read back from
/// `Documents/MyopiaSessions/` via `SessionStore`.
struct PreviousResultsView: View {
    @State private var sessions: [MyopiaScreenSession] = []
    @State private var showClearConfirmation = false
    @State private var shareURL: URL?
    @State private var showExportError = false
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
                    .tint(.myoTeal)
            } else {
                List {
                    ForEach(sessions, id: \.sessionID) { session in
                        NavigationLink {
                            ResultsView(session: session)   // no onDone means read-only history detail
                        } label: {
                            row(session)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                do {
                                    shareURL = try store.temporaryCSVURL(for: session)
                                } catch {
                                    showExportError = true
                                }
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.myoActionBlue)
                        }
                    }

                    // Gold "Clear All History": destructive pill with confirmation.
                    HStack {
                        Spacer()
                        Button("Clear All History") { showClearConfirmation = true }
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 200, height: 50)
                            .background(Capsule().fill(Color.myoDestructive))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.top, 10)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .decorativeDaisies(.myoResultsDaisies, over: .myoSurface)
        .navigationTitle("Test History")
        .onAppear { sessions = store.loadAllSessions() }
        .confirmationDialog("Clear Test History",
                            isPresented: $showClearConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                store.deleteAllSessions()
                // Reload from disk rather than assuming success: a file that failed to delete
                // must stay visible, never be reported as cleared.
                sessions = store.loadAllSessions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all saved screenings? This action cannot be undone.")
        }
        .alert("Export Error", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The session CSV could not be written for sharing.")
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
    }

    /// Gold history entry as a white mini-card: 20pt semibold timestamp + gray detail line.
    private func row(_ session: MyopiaScreenSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.formatter.string(from: session.completedAt ?? session.startedAt))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.black)
            if let delta = session.duochromeDeltaLogMAR {
                Text(String(format: "Red-teal delta %+.2f logMAR", delta))
                    .myoSmallText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.myoGrayBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}
