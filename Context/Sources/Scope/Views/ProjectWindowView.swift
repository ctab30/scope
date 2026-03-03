import SwiftUI

/// Self-contained root view for project-specific windows.
///
/// Per-project services (SessionWatcher, LiveSessionMonitor, etc.) are created per window.
/// App-level services (AppSettings, BriefingService, ClaudeService) are shared via SharedServices
/// to avoid duplicating memory for every open project window.
struct ProjectWindowView: View {
    let projectId: String

    // App-level services — shared across all windows
    private var appSettings: AppSettings { SharedServices.shared.appSettings }
    private var briefingService: BriefingService { SharedServices.shared.briefingService }
    private var claudeService: ClaudeService { SharedServices.shared.claudeService }

    // Per-window services — legitimately per-project
    @StateObject private var appState = AppState()
    @StateObject private var sessionWatcher = SessionWatcher()
    @StateObject private var liveMonitor = LiveSessionMonitor()
    @StateObject private var devEnvironment = DevEnvironment()
    @StateObject private var projectAnalyzer = ProjectAnalyzer()
    @StateObject private var githubService = GitHubService()
    @StateObject private var contextEngine = ContextEngine()

    @State private var projectPath: String = ""
    @State private var project: Project?

    var body: some View {
        Group {
            if project != nil {
                HSplitView {
                    TerminalTabView(projectPath: $projectPath, projectId: projectId)
                        .frame(minWidth: 400, idealWidth: 600)

                    GUIPanelView()
                        .frame(minWidth: 400, idealWidth: 600)
                }
            } else {
                VStack {
                    ProgressView()
                    Text("Loading project…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environmentObject(appState)
        .environmentObject(appSettings)
        .environmentObject(liveMonitor)
        .environmentObject(devEnvironment)
        .environmentObject(projectAnalyzer)
        .environmentObject(claudeService)
        .environmentObject(githubService)
        .environmentObject(contextEngine)
        .environmentObject(briefingService)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .background(WindowConfigurator(title: project?.name))
        .onAppear {
            loadProject()
        }
        .onDisappear {
            devEnvironment.stop()
            liveMonitor.stopMonitoring()
            sessionWatcher.stopWatching()
            githubService.stopMonitoring()
            contextEngine.stopWatching()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            liveMonitor.pauseMonitoring()
            githubService.pauseMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            liveMonitor.resumeMonitoring()
            githubService.resumeMonitoring()
        }
    }

    private func loadProject() {
        do {
            let loaded = try DatabaseService.shared.dbQueue.read { db in
                try Project.fetchOne(db, key: projectId)
            }
            guard let loaded else { return }
            project = loaded
            projectPath = loaded.path
            appState.selectProject(loaded)
            appState.loadProjects()
            sessionWatcher.watchProject(loaded)
            devEnvironment.scan(projectPath: loaded.path)
            projectAnalyzer.scan(projectPath: loaded.path)
            githubService.startMonitoring(projectPath: loaded.path)
            contextEngine.startIndexing(projectId: loaded.id, projectPath: loaded.path)
            if let claudeDir = loaded.claudeProject {
                liveMonitor.startMonitoring(claudeProjectPath: claudeDir)
            }
        } catch {
            print("Failed to load project \(projectId): \(error)")
        }
    }
}
