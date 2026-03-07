import SwiftUI
import GRDB

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var liveMonitor: LiveSessionMonitor
    @State private var sessions: [Session] = []
    @State private var sessionCount: Int = 0
    @State private var pendingTaskCount: Int = 0
    @State private var inProgressTaskCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Live session (shown when active)
                if liveMonitor.state.isActive {
                    LiveSessionView()
                    Divider()
                        .padding(.bottom, 12)
                }

                VStack(alignment: .leading, spacing: 20) {
                // Quick action buttons
                HStack(spacing: 8) {
                    ActionButton(
                        icon: "plus.circle.fill",
                        title: "New Claude Session",
                        style: .primary
                    ) {
                        NotificationCenter.default.post(
                            name: .launchTask,
                            object: nil,
                            userInfo: [
                                LaunchTaskKey.title: "Claude",
                                LaunchTaskKey.command: "claude",
                                LaunchTaskKey.projectId: appState.currentProject?.id ?? ""
                            ]
                        )
                    }
                    ActionButton(
                        icon: "arrow.counterclockwise",
                        title: "Continue Last",
                        style: .secondary
                    ) {
                        NotificationCenter.default.post(
                            name: .launchTask,
                            object: nil,
                            userInfo: [
                                LaunchTaskKey.title: "Claude (Resume)",
                                LaunchTaskKey.command: "claude --continue",
                                LaunchTaskKey.projectId: appState.currentProject?.id ?? ""
                            ]
                        )
                    }
                    ActionButton(
                        icon: "folder",
                        title: "Open in Finder",
                        style: .secondary
                    ) {
                        if let path = appState.currentProject?.path {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                    Spacer()
                }

                // Task launcher
                TaskLauncherView()

                // Dev tools (project-aware)
                DevToolsView()

                // Cost tracker
                CostSummaryView()

                // Stats row
                HStack(spacing: 10) {
                    StatCard(
                        icon: "clock.arrow.circlepath",
                        value: "\(sessionCount)",
                        label: "Sessions",
                        color: .blue
                    )
                    StatCard(
                        icon: "circle.dotted",
                        value: "\(pendingTaskCount)",
                        label: "Pending",
                        color: .white
                    )
                    StatCard(
                        icon: "arrow.triangle.2.circlepath",
                        value: "\(inProgressTaskCount)",
                        label: "In Progress",
                        color: .green
                    )
                    Spacer()
                }

                // Recent sessions
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Sessions")
                        .font(WorkspaceTheme.Font.bodySemibold)
                        .foregroundColor(.primary)

                    if !sessions.isEmpty {
                        LazyVStack(spacing: 0) {
                            ForEach(sessions) { session in
                                SessionCard(session: session)
                                Divider()
                            }
                        }
                    } else {
                        emptyState
                    }
                }
            }
            .padding(20)
            } // end inner VStack
        }
        .onAppear { loadData() }
        .onChange(of: appState.currentProject) { _, _ in loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .sessionsDidChange)) { _ in
            loadData()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No sessions yet")
                .font(WorkspaceTheme.Font.bodyMedium)
                .foregroundColor(.secondary)

            Text("Select a project to see its session history")
                .font(WorkspaceTheme.Font.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func loadData() {
        guard let project = appState.currentProject else {
            sessions = []
            sessionCount = 0
            pendingTaskCount = 0
            inProgressTaskCount = 0
            return
        }

        do {
            let result = try DatabaseService.shared.dbQueue.read { db -> (sessions: [Session], total: Int, pending: Int, inProgress: Int) in
                let recentSessions = try Session
                    .filter(Session.Columns.projectId == project.id)
                    .order(Session.Columns.startedAt.desc)
                    .limit(10)
                    .fetchAll(db)

                let total = try Session
                    .filter(Session.Columns.projectId == project.id)
                    .fetchCount(db)

                let pending = try TaskItem
                    .filter(Column("projectId") == project.id)
                    .filter(Column("status") == "todo")
                    .fetchCount(db)

                let inProgress = try TaskItem
                    .filter(Column("projectId") == project.id)
                    .filter(Column("status") == "in_progress")
                    .fetchCount(db)

                return (recentSessions, total, pending, inProgress)
            }

            sessions = result.sessions
            sessionCount = result.total
            pendingTaskCount = result.pending
            inProgressTaskCount = result.inProgress
        } catch {
            print("DashboardView: failed to load data: \(error)")
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    enum Style { case primary, secondary }

    let icon: String
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        if style == .primary {
            Button(action: action) {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: WorkspaceTheme.Spacing.sm) {
            Text(value)
                .font(WorkspaceTheme.Font.largeNumber)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, WorkspaceTheme.Spacing.md)
        .padding(.vertical, WorkspaceTheme.Spacing.sm)
    }
}

// MARK: - Session Card

struct SessionCard: View {
    let session: Session
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.sm) {
            // Header row
            HStack {
                Text(settings.demoMode ? DemoContent.shared.mask(session.slug ?? String(session.id.prefix(8)), as: .session) : (session.slug ?? String(session.id.prefix(8))))
                    .font(WorkspaceTheme.Font.bodySemibold)
                    .lineLimit(1)

                Spacer()

                if let date = session.startedAt {
                    Text(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            // Metadata pills
            HStack(spacing: WorkspaceTheme.Spacing.xs) {
                if let branch = session.gitBranch {
                    MetadataPill(icon: "arrow.triangle.branch", text: settings.demoMode ? DemoContent.shared.mask(branch, as: .gitBranch) : branch, color: .purple)
                }
                if let model = session.model {
                    MetadataPill(icon: "cpu", text: model, color: .blue)
                }
                MetadataPill(
                    icon: "message",
                    text: "\(session.messageCount) msgs",
                    color: .secondary
                )
                MetadataPill(
                    icon: "wrench",
                    text: "\(session.toolUseCount) tools",
                    color: .secondary
                )
                if session.estimatedCost > 0 {
                    MetadataPill(
                        icon: "dollarsign.circle",
                        text: String(format: "$%.2f", session.estimatedCost),
                        color: session.estimatedCost > 1 ? .white : .green
                    )
                }
            }

            // Summary
            if let summary = session.summary, !summary.isEmpty {
                Text(settings.demoMode ? DemoContent.shared.mask(summary, as: .snippet) : summary)
                    .font(WorkspaceTheme.Font.body)
                    .foregroundColor(.primary.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, WorkspaceTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Metadata Pill

struct MetadataPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(WorkspaceTheme.Font.tag)
            Text(text)
                .font(WorkspaceTheme.Font.caption)
                .lineLimit(1)
        }
        .foregroundColor(color == .secondary ? .secondary : color.opacity(0.8))
    }
}
