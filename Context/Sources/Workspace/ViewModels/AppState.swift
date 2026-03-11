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

        /// Tabs currently shown in the tab bar.
        static var visibleCases: [GUITab] {
            [.tasks, .notes, .files, .browser]
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

        // Install Claude Code hooks for file tracking
        installClaudeHooks(for: project)

        // Generate project profile asynchronously
        generateProjectProfile(for: project)
    }

    /// Writes hooks to the project's `.claude/settings.local.json` for file tracking and notifications.
    private func installClaudeHooks(for project: Project) {
        let projectURL = URL(fileURLWithPath: project.path)
        let claudeDir = projectURL.appendingPathComponent(".claude", isDirectory: true)
        let settingsLocalPath = claudeDir.appendingPathComponent("settings.local.json")

        // Ensure .claude/ directory exists
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Update CLAUDE.md with Workspace MCP tool instructions
        let injector = ContextInjector()
        try? injector.updateClaudeMD(for: project)

        // Write hook scripts to ~/.workspace/hooks/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let hooksDir = homeDir.appendingPathComponent(".workspace/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let appSupportPath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Workspace").path
        let dbPath = appSupportPath + "/workspace.db"
        let notifyDir = appSupportPath + "/notifications"

        let projectName = project.name.replacingOccurrences(of: "'", with: "'\\''")
        let escapedProjectPath = project.path.replacingOccurrences(of: "'", with: "'\\''")

        // -- 1a. Permission notification script (instant) --
        // Fires immediately when Claude needs tool approval.
        let notifyScriptPath = hooksDir.appendingPathComponent("notify-\(project.id).sh")
        let notifyScript = """
        #!/bin/bash
        # Collect all ancestor PIDs so the app can match to the terminal tab's shell
        ANCESTORS=""
        PID=$PPID
        for i in $(seq 1 10); do
            [ "$PID" -le 1 ] 2>/dev/null && break
            ANCESTORS="$ANCESTORS$PID,"
            PID=$(ps -o ppid= -p $PID 2>/dev/null | tr -d ' ')
        done
        mkdir -p '\(notifyDir)'
        cat > '\(notifyDir)/hook-$$-$(date +%s).json' <<NOTIFY_EOF
        {"title":"Claude Code","subtitle":"\(projectName)","body":"Needs approval","projectPath":"\(escapedProjectPath)","ancestors":"$ANCESTORS"}
        NOTIFY_EOF
        """
        try? notifyScript.write(to: notifyScriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notifyScriptPath.path)

        // -- 1b. Idle notification script (60s delay) --
        // Fires when Claude finishes and waits for input. Delays 60s so it only
        // notifies if the user walked away — not on every single response.
        let idleNotifyScriptPath = hooksDir.appendingPathComponent("notify-idle-\(project.id).sh")
        let idleNotifyScript = """
        #!/bin/bash
        # Collect ancestor PIDs
        ANCESTORS=""
        PID=$PPID
        for i in $(seq 1 10); do
            [ "$PID" -le 1 ] 2>/dev/null && break
            ANCESTORS="$ANCESTORS$PID,"
            PID=$(ps -o ppid= -p $PID 2>/dev/null | tr -d ' ')
        done
        STAMP_FILE='/tmp/workspace-idle-\(project.id)-'$PPID
        date +%s > "$STAMP_FILE"
        MY_STAMP=$(cat "$STAMP_FILE")
        (
            sleep 60
            [ -f "$STAMP_FILE" ] || exit 0
            CURRENT=$(cat "$STAMP_FILE" 2>/dev/null)
            [ "$CURRENT" = "$MY_STAMP" ] || exit 0
            rm -f "$STAMP_FILE"
            mkdir -p '\(notifyDir)'
            cat > '\(notifyDir)/idle-$$-$(date +%s).json' <<NOTIFY_EOF
        {"title":"Claude Code","subtitle":"\(projectName)","body":"Waiting for input","projectPath":"\(escapedProjectPath)","ancestors":"$ANCESTORS"}
        NOTIFY_EOF
        ) &
        """
        try? idleNotifyScript.write(to: idleNotifyScriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: idleNotifyScriptPath.path)

        // -- 2. File tracking script (PostToolUse: Edit/Write/NotebookEdit) --
        let fileTrackScriptPath = hooksDir.appendingPathComponent("track-files-\(project.id).sh")
        let fileTrackScript = """
        #!/bin/bash
        INPUT=$(cat)
        TOOL_NAME=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null)
        FILE_PATH=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.load(sys.stdin); i=d.get('tool_input',{}); print(i.get('file_path','') or i.get('path',''))" 2>/dev/null)

        case "$TOOL_NAME" in
            Edit|Write|NotebookEdit) ;;
            *) exit 0 ;;
        esac

        [ -z "$FILE_PATH" ] && exit 0

        DB='\(dbPath)'
        PROJECT_ID='\(project.id)'

        # Find the most recent in_progress task for this project
        TASK_ID=$(/usr/bin/sqlite3 "$DB" "SELECT id FROM taskItems WHERE projectId = '$PROJECT_ID' AND status = 'in_progress' ORDER BY createdAt DESC LIMIT 1;" 2>/dev/null)
        [ -z "$TASK_ID" ] && exit 0

        CHANGE_TYPE="edit"
        [ "$TOOL_NAME" = "Write" ] && CHANGE_TYPE="create"

        /usr/bin/sqlite3 "$DB" "INSERT INTO taskFileChanges (taskId, filePath, changeType, changedAt) VALUES ($TASK_ID, '$(echo "$FILE_PATH" | sed "s/'/''/g")', '$CHANGE_TYPE', datetime('now'));" 2>/dev/null
        """
        try? fileTrackScript.write(to: fileTrackScriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileTrackScriptPath.path)

        // Read existing settings.local.json to preserve other settings
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsLocalPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        // Notification hooks:
        // - permission_prompt → instant (always urgent)
        // - idle_prompt → 60s delay (only if user walked away)
        let notifyHook: [[String: Any]] = [
            [
                "matcher": "permission_prompt",
                "hooks": [
                    ["type": "command", "command": notifyScriptPath.path, "timeout": 5]
                ]
            ],
            [
                "matcher": "idle_prompt",
                "hooks": [
                    ["type": "command", "command": idleNotifyScriptPath.path, "timeout": 5]
                ]
            ]
        ]
        // File tracking hook — only fires on Edit/Write tool use
        let fileTrackHook: [[String: Any]] = [
            [
                "matcher": "Edit|Write|NotebookEdit",
                "hooks": [
                    ["type": "command", "command": fileTrackScriptPath.path, "timeout": 5]
                ]
            ]
        ]

        settings["hooks"] = [
            "Notification": notifyHook,
            "PostToolUse": fileTrackHook
        ]

        // Auto-allow key workspace MCP tools
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        let workspaceTools = [
            "mcp__workspace__get_project_context",
            "mcp__workspace__get_next_task",
            "mcp__workspace__create_task",
            "mcp__workspace__update_task",
            "mcp__workspace__complete_task",
            "mcp__workspace__search_tasks",
            "mcp__workspace__add_task_note",
            "mcp__workspace__list_tasks",
            "mcp__workspace__get_task",
            "mcp__workspace__get_task_plan",
            "mcp__workspace__set_task_plan",
            "mcp__workspace__add_task_file",
            "mcp__workspace__list_task_notes",
            "mcp__workspace__create_note",
            "mcp__workspace__search_notes",
            "mcp__workspace__list_notes",
            "mcp__workspace__get_note",
        ]
        for tool in workspaceTools {
            if !allow.contains(tool) {
                allow.append(tool)
            }
        }
        permissions["allow"] = allow
        settings["permissions"] = permissions

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
