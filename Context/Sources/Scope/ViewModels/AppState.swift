import Foundation
import GRDB
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var currentProject: Project?
    @Published var projects: [Project] = []
    @Published var selectedTab: GUITab = .tasks
    @Published var isHomeView: Bool = true
    @Published var clients: [Client] = []
    @Published var projectProfile: String?
    @Published var isProfileGenerating = false

    enum GUITab: String, CaseIterable {
        case tasks = "Tasks"
        case notes = "Notes"
        case files = "Files"
        case browser = "Browser"
        case sessions = "Sessions"
        case dashboard = "Details"

        var icon: String {
            switch self {
            case .tasks: return "checklist"
            case .notes: return "note.text"
            case .files: return "folder"
            case .browser: return "globe"
            case .sessions: return "clock"
            case .dashboard: return "info.circle"
            }
        }
    }

    func loadProjects() {
        do {
            projects = try DatabaseService.shared.dbQueue.read { db in
                try Project.order(Project.Columns.lastOpened.desc).fetchAll(db)
            }

            // Auto-select the most recently opened project if none is selected
            // and we're not on the home view.
            if !isHomeView && currentProject == nil, let first = projects.first {
                selectProject(first)
            }
        } catch {
            print("Failed to load projects: \(error)")
        }
        loadClients()

        // Install Claude Code hooks for all projects
        for project in projects {
            installClaudeHooks(for: project)
        }
    }

    func selectProject(_ project: Project) {
        isHomeView = false
        currentProject = project
        do {
            try DatabaseService.shared.dbQueue.write { db in
                var updated = project
                updated.lastOpened = Date()
                try updated.update(db)
            }
            let discovery = ProjectDiscovery()
            try discovery.importSessions(for: project)

            // Notify views that session data is available.
            NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        } catch {
            print("Failed to update project: \(error)")
        }

        // Install Claude Code hooks for needs_attention
        installClaudeHooks(for: project)

        // Generate project profile asynchronously
        generateProjectProfile(for: project)
    }

    /// Writes hooks to the project's `.claude/settings.local.json` so every Claude session
    /// in that directory automatically moves in_progress tasks to needs_attention on Stop/Notification.
    private func installClaudeHooks(for project: Project) {
        let projectURL = URL(fileURLWithPath: project.path)
        let claudeDir = projectURL.appendingPathComponent(".claude", isDirectory: true)
        let settingsLocalPath = claudeDir.appendingPathComponent("settings.local.json")

        // Ensure .claude/ directory exists
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Update CLAUDE.md with Scope MCP tool instructions
        let injector = ContextInjector()
        try? injector.updateClaudeMD(for: project)

        // Write the project-level hook script to ~/.scope/hooks/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let hooksDir = homeDir.appendingPathComponent(".scope/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let appSupportPath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Scope").path
        let dbPath = appSupportPath + "/scope.db"
        let activeTasksDir = appSupportPath + "/active-tasks"

        // Find ScopeMCP binary path (sibling to main app binary)
        let mcpBinaryPath = Bundle.main.bundlePath + "/Contents/MacOS/ScopeMCP"

        let scriptPath = hooksDir.appendingPathComponent("needs-attention-\(project.id).sh")
        let projectName = project.name.replacingOccurrences(of: "'", with: "'\\''")
        // The MCP server writes active-tasks/<project-id> with the task ID when update_task
        // moves a task to in_progress. The hook reads that file to move only that specific task.
        let script = """
        #!/bin/bash
        # Background the delay so the hook returns immediately (avoids timeout kill)
        (
            sleep 30

            DB='\(dbPath)'
            TASK_FILE='\(activeTasksDir)/\(project.id)'

            [ ! -f "$TASK_FILE" ] && exit 0
            TASK_ID=$(cat "$TASK_FILE" 2>/dev/null)
            [ -z "$TASK_ID" ] && exit 0

            # Re-check status after 30s — task may have resumed already
            TITLE=$(/usr/bin/sqlite3 "$DB" "SELECT title FROM taskItems WHERE id = $TASK_ID AND status = 'in_progress' LIMIT 1;" 2>/dev/null)
            [ -z "$TITLE" ] && exit 0

            /usr/bin/sqlite3 "$DB" "UPDATE taskItems SET status = 'needs_attention' WHERE id = $TASK_ID AND status = 'in_progress';"
            '\(mcpBinaryPath)' notify --title "Needs Attention" --subtitle '\(projectName)' --body "$TITLE"
        ) &
        """
        try? script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Resume script — moves task back to in_progress when user responds
        let resumeScriptPath = hooksDir.appendingPathComponent("resume-\(project.id).sh")
        let resumeScript = """
        #!/bin/bash
        DB='\(dbPath)'
        TASK_FILE='\(activeTasksDir)/\(project.id)'

        [ ! -f "$TASK_FILE" ] && exit 0
        TASK_ID=$(cat "$TASK_FILE" 2>/dev/null)
        [ -z "$TASK_ID" ] && exit 0

        /usr/bin/sqlite3 "$DB" "UPDATE taskItems SET status = 'in_progress' WHERE id = $TASK_ID AND status = 'needs_attention';"
        """
        try? resumeScript.write(to: resumeScriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resumeScriptPath.path)

        // Read existing settings.local.json to preserve other settings
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsLocalPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        // Notification/Stop → move task to needs_attention
        let needsAttentionHook: [[String: Any]] = [
            [
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": scriptPath.path, "timeout": 10]
                ]
            ]
        ]
        // UserPromptSubmit → move task back to in_progress
        let resumeHook: [[String: Any]] = [
            [
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": resumeScriptPath.path, "timeout": 10]
                ]
            ]
        ]
        settings["hooks"] = [
            "Notification": needsAttentionHook,
            "Stop": needsAttentionHook,
            "UserPromptSubmit": resumeHook,
            "PostToolUse": resumeHook
        ]


        // Write back
        if let jsonData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: settingsLocalPath, options: .atomic)
        }
    }

    private func generateProjectProfile(for project: Project) {
        // Load cached profile immediately for instant availability
        projectProfile = ProjectProfileGenerator.loadCached(projectId: project.id)
        isProfileGenerating = true

        // Then regenerate in background
        Task {
            let profile = await ProjectProfileGenerator.generate(
                projectId: project.id,
                projectPath: project.path
            )
            self.projectProfile = profile
            self.isProfileGenerating = false
        }
    }

    func selectHome() {
        isHomeView = true
        currentProject = nil
        projectProfile = nil
        isProfileGenerating = false
    }

    func loadClients() {
        do {
            clients = try DatabaseService.shared.dbQueue.read { db in
                try Client.order(Column("sortOrder").asc, Column("name").asc).fetchAll(db)
            }
        } catch {
            print("Failed to load clients: \(error)")
        }
    }

    func createClient(name: String, color: String) {
        var client = Client(
            id: UUID().uuidString,
            name: name,
            color: color,
            sortOrder: clients.count,
            createdAt: Date()
        )
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try client.insert(db)
            }
            loadClients()
        } catch {
            print("Failed to create client: \(error)")
        }
    }

    func deleteClient(_ client: Client) {
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in
                try client.delete(db)
            }
            loadClients()
            loadProjects() // refresh since projects may have lost their clientId
        } catch {
            print("Failed to delete client: \(error)")
        }
    }

    func addProjectFromFolder(_ url: URL) {
        let path = url.path
        let name = url.lastPathComponent

        // Check if this path is already in the DB
        do {
            let exists = try DatabaseService.shared.dbQueue.read { db in
                try Project.filter(Project.Columns.path == path).fetchCount(db) > 0
            }
            if exists {
                // Already tracked — just select it
                if let project = projects.first(where: { $0.path == path }) {
                    selectProject(project)
                }
                return
            }
        } catch {
            print("Failed to check existing project: \(error)")
        }

        // Check if there's a matching ~/.claude/projects/ directory
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let encoded = encodePath(path)
        let claudeDir = claudeProjectsDir.appendingPathComponent(encoded)
        let claudeProject: String? = FileManager.default.fileExists(atPath: claudeDir.path)
            ? claudeDir.path : nil

        var project = Project(
            id: UUID().uuidString,
            name: name,
            path: path,
            claudeProject: claudeProject,
            lastOpened: Date(),
            createdAt: Date()
        )
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try project.insert(db)
            }
            loadProjects()
            selectProject(project)
        } catch {
            print("Failed to add project: \(error)")
        }
    }

    func removeProject(_ project: Project) {
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in
                try project.delete(db)
            }
            if currentProject?.id == project.id {
                selectHome()
            }
            loadProjects()
        } catch {
            print("Failed to remove project: \(error)")
        }
    }

    func updateProjectTag(_ project: Project, tag: String?) {
        do {
            try DatabaseService.shared.dbQueue.write { db in
                var updated = project
                if let tag {
                    updated.setTags([tag])
                } else {
                    updated.setTags([])
                }
                try updated.update(db)
            }
            loadProjects()
        } catch {
            print("Failed to update project tag: \(error)")
        }
    }

    /// Encode a filesystem path the same way Claude Code does for ~/.claude/projects/
    private func encodePath(_ path: String) -> String {
        var result = ""
        for ch in path {
            if ch == "/" || ch == " " || ch == "." || ch == "-" {
                result.append("-")
            } else {
                result.append(ch)
            }
        }
        return result
    }

    func updateProjectClient(_ project: Project, clientId: String?) {
        do {
            try DatabaseService.shared.dbQueue.write { db in
                var updated = project
                updated.clientId = clientId
                try updated.update(db)
            }
            loadProjects()
        } catch {
            print("Failed to update project client: \(error)")
        }
    }

    /// Projects grouped by client for the sidebar.
    var projectsByClient: [(client: Client?, projects: [Project])] {
        var groups: [(client: Client?, projects: [Project])] = []

        for client in clients {
            let clientProjects = projects.filter { $0.clientId == client.id }
            if !clientProjects.isEmpty {
                groups.append((client: client, projects: clientProjects))
            }
        }

        let ungrouped = projects.filter { $0.clientId == nil && $0.id != "__global__" }
        if !ungrouped.isEmpty {
            groups.append((client: nil, projects: ungrouped))
        }

        return groups
    }
}
