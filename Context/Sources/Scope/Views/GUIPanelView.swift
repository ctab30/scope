import SwiftUI

// MARK: - MCP Connection Monitor

struct MCPConnection: Identifiable {
    let id: Int // PID
    let cwd: String
    let projectId: String?
    let projectName: String?
    let connectedAt: String
}

class MCPConnectionMonitor: ObservableObject {
    @Published var connections: [MCPConnection] = []

    private var timer: Timer?
    private let statusDir: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Scope/mcp-connections", isDirectory: true)
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
                // Process is dead — clean up stale file
                try? FileManager.default.removeItem(at: file)
                continue
            }

            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            active.append(MCPConnection(
                id: pid,
                cwd: json["cwd"] as? String ?? "unknown",
                projectId: json["projectId"] as? String,
                projectName: json["projectName"] as? String,
                connectedAt: json["connectedAt"] as? String ?? ""
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
                    // Home view header
                    HStack {
                        Text("Planner")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        MCPIndicator(connections: mcpMonitor.connections, currentProjectId: nil)
                    }
                    .padding(.horizontal, ScopeTheme.Spacing.lg)
                    .padding(.vertical, ScopeTheme.Spacing.sm)

                    Divider()

                    // Home content
                    HomeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Project header (simplified — no dropdown picker)
                projectHeader
                    .padding(.horizontal, ScopeTheme.Spacing.lg)
                    .padding(.vertical, ScopeTheme.Spacing.sm)

                Divider()

                // Tab bar
                tabBar
                    .padding(.horizontal, ScopeTheme.Spacing.md)
                    .padding(.vertical, ScopeTheme.Spacing.sm)

                Divider()

                // Tab content — browser persists via ZStack, others switch normally
                ZStack {
                    // Browser always exists in the ZStack (hidden when not selected)
                    BrowserView(viewModel: browserViewModel)
                        .opacity(appState.selectedTab == .browser ? 1 : 0)
                        .allowsHitTesting(appState.selectedTab == .browser)

                    // Other tabs render on demand
                    if appState.selectedTab != .browser {
                        Group {
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
                            case .git:
                                GitChangesView()
                            case .browser:
                                EmptyView() // Handled above in ZStack
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Project Header

    private var projectHeader: some View {
        HStack(spacing: ScopeTheme.Spacing.md) {
            if let project = appState.currentProject {
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                    Text(project.path)
                        .font(ScopeTheme.Font.caption)
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
            MCPIndicator(connections: mcpMonitor.connections, currentProjectId: appState.currentProject?.id)
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
                .font(ScopeTheme.Font.footnoteMedium)
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
    let currentProjectId: String?

    /// Connections matching the currently selected project.
    private var projectConnections: [MCPConnection] {
        guard let pid = currentProjectId else { return [] }
        return connections.filter { $0.projectId == pid }
    }

    private var isConnectedToCurrentProject: Bool {
        !projectConnections.isEmpty
    }

    private var statusColor: Color {
        .green
    }

    var body: some View {
        if connections.isEmpty {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text("MCP")
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(.secondary.opacity(0.4))
            }
        } else {
            Menu {
                Section("MCP Connections (\(connections.count))") {
                    ForEach(connections) { conn in
                        let isCurrent = conn.projectId == currentProjectId
                        Label {
                            Text("\(conn.projectName ?? "Unknown") — PID \(conn.id)")
                        } icon: {
                            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text("MCP")
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(statusColor)
                    if connections.count > 1 {
                        Text("\(connections.count)")
                            .font(ScopeTheme.Font.tag)
                            .fontDesign(.monospaced)
                            .foregroundColor(statusColor)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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
        case "indexing": return .orange
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
                    .font(ScopeTheme.Font.caption)
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
        if isGenerating { return .orange }
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
                .font(ScopeTheme.Font.caption)
                .foregroundColor(statusColor)
        }
    }
}
