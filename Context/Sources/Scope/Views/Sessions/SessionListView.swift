import SwiftUI
import GRDB

struct SessionListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var searchText: String = ""

    var body: some View {
        HSplitView {
            // Left panel: search + session list
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Search sessions...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                )
                .padding(10)

                Divider()

                // Session list
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, isSelected: selectedSession?.id == session.id)
                                .onTapGesture {
                                    selectedSession = session
                                }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
            }
            .frame(minWidth: 220, idealWidth: 280)

            // Right panel: detail view
            if let session = selectedSession {
                SessionDetailView(session: session)
                    .frame(minWidth: 300)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Choose from the list to view details")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadSessions() }
        .onChange(of: appState.currentProject) { _, _ in
            selectedSession = nil
            loadSessions()
        }
        .onChange(of: searchText) { _, _ in loadSessions() }
        .onReceive(NotificationCenter.default.publisher(for: .sessionsDidChange)) { notification in
            if let notifProjectId = notification.userInfo?["projectId"] as? String,
               let currentId = appState.currentProject?.id,
               notifProjectId != currentId {
                return
            }
            loadSessions()
        }
    }

    private func loadSessions() {
        guard let project = appState.currentProject else {
            sessions = []
            return
        }

        do {
            sessions = try DatabaseService.shared.dbQueue.read { db in
                var request = Session
                    .filter(Session.Columns.projectId == project.id)

                if !searchText.isEmpty {
                    request = request.filter(Session.Columns.summary.like("%\(searchText)%"))
                }

                return try request
                    .order(Session.Columns.startedAt.desc)
                    .fetchAll(db)
            }
        } catch {
            print("SessionListView: failed to load sessions: \(error)")
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    @EnvironmentObject var settings: AppSettings
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(settings.demoMode ? DemoContent.shared.mask(session.slug ?? String(session.id.prefix(8)), as: .session) : (session.slug ?? String(session.id.prefix(8))))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let date = session.startedAt {
                    Text(date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Label("\(session.messageCount)", systemImage: "message")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Label("\(session.toolUseCount)", systemImage: "wrench")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if session.estimatedCost > 0 {
                    Label(String(format: "$%.2f", session.estimatedCost), systemImage: "dollarsign.circle")
                        .font(.system(size: 10))
                        .foregroundColor(session.estimatedCost > 1 ? .orange : .green)
                }
                if let branch = session.gitBranch {
                    Label(settings.demoMode ? DemoContent.shared.mask(branch, as: .gitBranch) : branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundColor(.purple.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.15)
                      : isHovering ? Color(nsColor: .separatorColor).opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
