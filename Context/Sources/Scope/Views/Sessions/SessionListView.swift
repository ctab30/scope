import SwiftUI
import GRDB

struct SessionListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var searchText: String = ""

    var body: some View {
        HSplitView {
            // Left panel: session list
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, isSelected: selectedSession?.id == session.id)
                                .onTapGesture {
                                    selectedSession = session
                                }
                        }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 280)

            // Right panel: detail view
            if let session = selectedSession {
                SessionDetailView(session: session)
                    .frame(minWidth: 300)
            } else {
                VStack(spacing: ScopeTheme.Spacing.sm) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a session")
                        .font(ScopeTheme.Font.bodyMedium)
                        .foregroundColor(.secondary)
                    Text("Choose from the list to view details")
                        .font(ScopeTheme.Font.footnote)
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
        VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxs) {
            HStack {
                Text(settings.demoMode ? DemoContent.shared.mask(session.slug ?? String(session.id.prefix(8)), as: .session) : (session.slug ?? String(session.id.prefix(8))))
                    .font(ScopeTheme.Font.footnoteMedium)
                    .lineLimit(1)
                Spacer()
                if let date = session.startedAt {
                    Text(date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(ScopeTheme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: ScopeTheme.Spacing.sm) {
                Label("\(session.messageCount)", systemImage: "message")
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(.secondary)
                Label("\(session.toolUseCount)", systemImage: "wrench")
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(.secondary)
                if session.estimatedCost > 0 {
                    Label(String(format: "$%.2f", session.estimatedCost), systemImage: "dollarsign.circle")
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(session.estimatedCost > 1 ? .orange : .green)
                }
                if let branch = session.gitBranch {
                    Label(settings.demoMode ? DemoContent.shared.mask(branch, as: .gitBranch) : branch, systemImage: "arrow.triangle.branch")
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.purple.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, ScopeTheme.Spacing.sm)
        .padding(.vertical, ScopeTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                .fill(isSelected
                      ? Color.accentColor.opacity(ScopeTheme.Opacity.selection)
                      : isHovering ? ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.selection) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
