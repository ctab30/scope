import SwiftUI
import GRDB

// MARK: - MCP Connection Monitor

struct MCPConnection: Identifiable {
    let id: Int // PID
    let cwd: String
    let projectId: String?
    let projectName: String?
    let connectedAt: String
    let lastActivityAt: Date?
}

class MCPConnectionMonitor: ObservableObject {
    @Published var connections: [MCPConnection] = []

    private var timer: Timer?
    private let statusDir: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Workspace/mcp-connections", isDirectory: true)
        statusDir = appSupport
    }

    func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: statusDir.path) else {
            DispatchQueue.main.async { self.connections = [] }
            return
        }

        var active: [MCPConnection] = []
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: statusDir, includingPropertiesForKeys: nil
        ) else {
            DispatchQueue.main.async { self.connections = [] }
            return
        }

        for file in files where file.pathExtension == "json" {
            guard let pidStr = file.deletingPathExtension().lastPathComponent.components(separatedBy: ".").first,
                  let pid = Int(pidStr) else { continue }

            // Check if process is still running
            if kill(Int32(pid), 0) != 0 {
                // Process is dead — read projectId before cleanup
                if let data = try? Data(contentsOf: file),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let projectId = json["projectId"] as? String {
                    let wasDangerous = json["dangerousMode"] as? Bool == true

                    // Check if any OTHER active connections exist for this project
                    let otherFiles = files.filter { f in
                        guard f != file, f.pathExtension == "json" else { return false }
                        guard let pStr = f.deletingPathExtension().lastPathComponent.components(separatedBy: ".").first,
                              let otherPid = Int(pStr),
                              kill(Int32(otherPid), 0) == 0 else { return false }
                        guard let d = try? Data(contentsOf: f),
                              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let pId = j["projectId"] as? String else { return false }
                        return pId == projectId
                    }
                    if otherFiles.isEmpty && !wasDangerous {
                        // No other sessions — move in_progress tasks to needs_attention
                        // (skip for dangerous mode — Claude runs autonomously)
                        let moved = try? DatabaseService.shared.dbQueue.write { db -> Int in
                            try db.execute(
                                sql: "UPDATE taskItems SET status = 'needs_attention' WHERE projectId = ? AND status = 'in_progress'",
                                arguments: [projectId]
                            )
                            return db.changesCount
                        }
                        if let moved, moved > 0 {
                            let projName = json["projectName"] as? String
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .tasksDidChange, object: nil)
                                NotificationCenter.default.post(name: .tasksNeedAttention, object: nil, userInfo: ["projectName": projName as Any])
                            }
                        }
                    }
                }
                // Clean up stale file
                try? FileManager.default.removeItem(at: file)
                continue
            }

            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            var lastActivity: Date? = nil
            if let lastActivityStr = json["lastActivityAt"] as? String {
                lastActivity = ISO8601DateFormatter().date(from: lastActivityStr)
            }

            let isDangerous = json["dangerousMode"] as? Bool == true

            // Detect idle sessions: alive but no MCP activity for 60+ seconds
            // Skip for dangerous mode — Claude runs autonomously without MCP calls
            if let projectId = json["projectId"] as? String,
               let activity = lastActivity,
               Date().timeIntervalSince(activity) > 60,
               !isDangerous {
                // Move in_progress tasks to needs_attention for this idle session
                let moved = try? DatabaseService.shared.dbQueue.write { db -> Int in
                    try db.execute(
                        sql: "UPDATE taskItems SET status = 'needs_attention' WHERE projectId = ? AND status = 'in_progress'",
                        arguments: [projectId]
                    )
                    return db.changesCount
                }
                if let moved, moved > 0 {
                    let projName = json["projectName"] as? String
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .tasksDidChange, object: nil)
                        NotificationCenter.default.post(name: .tasksNeedAttention, object: nil, userInfo: ["projectName": projName as Any])
                    }
                }
            }

            active.append(MCPConnection(
                id: pid,
                cwd: json["cwd"] as? String ?? "unknown",
                projectId: json["projectId"] as? String,
                projectName: json["projectName"] as? String,
                connectedAt: json["connectedAt"] as? String ?? "",
                lastActivityAt: lastActivity
            ))
        }

        DispatchQueue.main.async { self.connections = active }
    }
}

struct GUIPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var contextEngine: ContextEngine
    @StateObject private var mcpMonitor = MCPConnectionMonitor()
    @StateObject private var browserViewModel = BrowserViewModel()
    @StateObject private var browserCommandExecutor = BrowserCommandExecutor()
    @State private var showChatDrawer = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.isHomeView {
                if appState.selectedTab == .browser {
                    BrowserView(viewModel: browserViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Home content
                    HomeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Project header (simplified — no dropdown picker)
                projectHeader
                    .padding(.horizontal, WorkspaceTheme.Spacing.lg)
                    .padding(.vertical, WorkspaceTheme.Spacing.sm)

                Divider()

                // Tab bar
                tabBar
                    .padding(.horizontal, WorkspaceTheme.Spacing.md)
                    .padding(.vertical, WorkspaceTheme.Spacing.sm)

                Divider()

                // Tab content and Git Pane stacked vertically
                SeamlessVSplitView2 {
                    ZStack {
                        // Browser always exists in the ZStack (hidden when not selected)
                        BrowserView(viewModel: browserViewModel)
                            .opacity(appState.selectedTab == .browser ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == .browser)

                        // Other tabs render on demand
                        if appState.selectedTab != .browser {
                            tabContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        // Bottom border for the top pane (the line above Git)
                        VStack {
                            Spacer()
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } bottom: {
                    GitChangesView()
                }
            }
        }
        .inspector(isPresented: $showChatDrawer) {
            ChatDrawerView(isOpen: $showChatDrawer)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 450)
        }
        .onAppear {
            mcpMonitor.startPolling()
            browserCommandExecutor.start(browserViewModel: browserViewModel)
        }
        .onDisappear {
            mcpMonitor.stopPolling()
            browserCommandExecutor.stop()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.selectedTab {
        case .dashboard:
            DashboardView()
        case .sessions:
            SessionListView()
        case .tasks:
            KanbanBoard()
        case .notes:
            NoteListView()
        case .files:
            FileBrowserView()
        case .browser:
            EmptyView()
        }
    }

    // MARK: - Project Header

    private var projectHeader: some View {
        HStack(spacing: WorkspaceTheme.Spacing.md) {
            if let project = appState.currentProject {
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                    Text(project.path)
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            IndexIndicator(
                isIndexing: contextEngine.isIndexing,
                indexStatus: contextEngine.indexStatus,
                progress: contextEngine.indexProgress,
                totalChunks: contextEngine.totalChunks,
                lastError: contextEngine.lastError,
                isEmbedding: contextEngine.isEmbedding,
                embeddingProgress: contextEngine.embeddingProgress,
                onReindex: {
                    contextEngine.rebuildIndex()
                },
                onClearIndex: {
                    Task { await contextEngine.clearIndex() }
                }
            )
            ProfileIndicator(
                isGenerating: appState.isProfileGenerating,
                hasProfile: appState.projectProfile != nil
            )
            MCPIndicator(connections: mcpMonitor.connections)
        }
    }

    // MARK: - Chat Button

    private var chatButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showChatDrawer.toggle()
            }
        } label: {
            Image(systemName: showChatDrawer ? "bubble.right.fill" : "bubble.right")
                .font(WorkspaceTheme.Font.footnoteMedium)
                .foregroundColor(showChatDrawer ? .accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chat")
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        Picker("", selection: $appState.selectedTab) {
            ForEach(AppState.GUITab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - MCP Connection Indicator

struct MCPIndicator: View {
    let connections: [MCPConnection]
    @State private var showPopover = false

    private var statusColor: Color {
        connections.isEmpty ? .secondary.opacity(0.6) : .green
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text("MCP")
                .font(WorkspaceTheme.Font.caption)
                .foregroundColor(statusColor)
        }
        .onTapGesture { showPopover.toggle() }
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.sm) {
                if connections.isEmpty {
                    Text("No MCP connections")
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("MCP Connections")
                        .font(WorkspaceTheme.Font.footnoteSemibold)
                    ForEach(connections) { conn in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("\(conn.projectName ?? "Unknown")")
                                .font(WorkspaceTheme.Font.footnote)
                            Text("PID \(conn.id)")
                                .font(WorkspaceTheme.Font.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(WorkspaceTheme.Spacing.md)
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Index Indicator

struct IndexIndicator: View {
    let isIndexing: Bool
    let indexStatus: String
    let progress: Double
    let totalChunks: Int
    let lastError: String?
    var isEmbedding: Bool = false
    var embeddingProgress: Double = 0
    var onReindex: (() -> Void)?
    var onClearIndex: (() -> Void)?

    private var statusColor: Color {
        switch indexStatus {
        case "indexing": return .white
        case "ready": return .green
        case "error": return .red
        case "idle": return .secondary.opacity(0.6)
        default: return .secondary.opacity(0.5)
        }
    }

    private var label: String {
        if isIndexing {
            return "Indexing \(Int(progress * 100))%"
        }
        switch indexStatus {
        case "ready": return "Indexed \(totalChunks)"
        case "error": return "Index Error"
        case "idle": return "Not Indexed"
        default: return "Codebase"
        }
    }

    var body: some View {
        Menu {
            if indexStatus == "no_key" {
                Text("Set OpenRouter API key in Settings")
            }
            if let error = lastError, indexStatus == "error" {
                Text(error)
            }

            Divider()

            Button {
                onReindex?()
            } label: {
                Label(indexStatus == "idle" || indexStatus == "no_key" ? "Index Codebase" : "Re-index Codebase",
                      systemImage: "arrow.clockwise")
            }
            .disabled(isIndexing || indexStatus == "no_key")

            if indexStatus == "ready" || indexStatus == "error" {
                Button(role: .destructive) {
                    onClearIndex?()
                } label: {
                    Label("Clear Index", systemImage: "trash")
                }
                .disabled(isIndexing)
            }
        } label: {
            HStack(spacing: 3) {
                if isIndexing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                Text(label)
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundColor(statusColor)
                if isEmbedding && !isIndexing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.5)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Profile Indicator

struct ProfileIndicator: View {
    let isGenerating: Bool
    let hasProfile: Bool

    private var statusColor: Color {
        if isGenerating { return .white }
        if hasProfile { return .green }
        return .secondary.opacity(0.5)
    }

    private var label: String {
        if isGenerating { return "Filesystem" }
        if hasProfile { return "Filesystem" }
        return "Filesystem"
    }

    private var icon: String {
        if isGenerating { return "arrow.triangle.2.circlepath" }
        if hasProfile { return "folder.fill" }
        return "folder"
    }

    var body: some View {
        HStack(spacing: 3) {
            if isGenerating {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(WorkspaceTheme.Font.caption)
                .foregroundColor(statusColor)
        }
    }
}
