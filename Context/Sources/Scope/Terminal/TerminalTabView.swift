import SwiftUI

/// Notification payload for launching a Claude task in a new terminal tab.
extension Notification.Name {
    static let launchTask = Notification.Name("launchTask")
}

/// Keys for `.launchTask` notification userInfo.
enum LaunchTaskKey {
    static let title = "title"
    static let command = "command"
    static let projectId = "projectId"
}

/// A view that manages multiple terminal tabs, each backed by a `TerminalWrapper`.
///
/// The tab bar sits at the top. A "+" button creates new tabs whose initial
/// directory matches the current `projectPath`. When the project path changes
/// the active terminal receives a `cd` command so it stays in sync.
///
/// Listens for `.launchTask` notifications from the GUI side to create new
/// tabs that auto-run Claude commands.
/// AppKit `NSVisualEffectView` wrapped for SwiftUI — provides the
/// frosted-glass / vibrancy backdrop behind the terminal.
struct TerminalVibrancyView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active          // always active, even when window is not key
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct TerminalTabView: View {
    @Binding var projectPath: String
    var projectId: String = ""
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTabId: UUID?
    @State private var commandToSend: String?
    @StateObject private var agentMonitor = AgentMonitor()

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabButton(for: tab)
                }

                Button(action: addTab) {
                    Image(systemName: "plus")
                        .font(ScopeTheme.Font.footnoteMedium)
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, ScopeTheme.Spacing.xxxs)
                .help("New Tab")

                Spacer()

                CLIQuickLaunchView(
                    projectPath: projectPath,
                    onLaunchCLI: { title, command in
                        launchTask(title: title, command: command)
                    }
                )
                .padding(.trailing, ScopeTheme.Spacing.xs)
            }
            .padding(.horizontal, ScopeTheme.Spacing.xs)
            .padding(.vertical, ScopeTheme.Spacing.xxs)
            .background(.clear)

            // Agent status bar (visible when Claude Code is running)
            AgentStatusBar(monitor: agentMonitor)

            // Terminal content — all tabs stay alive in a ZStack,
            // only the selected tab is visible and interactive.
            // Screen blend makes the black bg transparent, showing the
            // window's ultraThinMaterial seamlessly (same as the sidebar).
            ZStack {
                ForEach(tabs) { tab in
                    let isActive = tab.id == selectedTabId
                    TerminalWrapper(
                        initialDirectory: tab.initialDirectory,
                        initialCommand: tab.initialCommand,
                        isActive: isActive,
                        sendCommand: isActive ? $commandToSend : .constant(nil),
                        onShellStarted: { [weak agentMonitor] pid in
                            tab.shellPid = pid
                            // Start monitoring if this is the active tab
                            if tab.id == selectedTabId {
                                agentMonitor?.start(shellPid: pid)
                            }
                        }
                    )
                    .blendMode(.screen)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                }
            }
            .overlay {
                if tabs.isEmpty {
                    VStack(spacing: ScopeTheme.Spacing.sm) {
                        Image(systemName: "terminal")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No terminal open")
                            .font(ScopeTheme.Font.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onAppear {
            if tabs.isEmpty {
                addTab()
            }
        }
        .onDisappear {
            agentMonitor.stop()
        }
        .onChange(of: selectedTabId) { _, newId in
            // Switch agent monitor to the newly selected tab's shell
            if let tab = tabs.first(where: { $0.id == newId }), tab.shellPid > 0 {
                agentMonitor.start(shellPid: tab.shellPid)
            } else {
                agentMonitor.stop()
            }
        }
        .onChange(of: projectPath) { _, newPath in
            if !newPath.isEmpty {
                commandToSend = "cd \"\(newPath)\""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchTask)) { notification in
            guard let info = notification.userInfo,
                  let title = info[LaunchTaskKey.title] as? String,
                  let command = info[LaunchTaskKey.command] as? String else { return }
            // Filter: only handle if projectId matches or notification has no projectId
            if let notifProjectId = info[LaunchTaskKey.projectId] as? String,
               !projectId.isEmpty,
               notifProjectId != projectId {
                return
            }
            launchTask(title: title, command: command)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteToTerminal)) { notification in
            guard let text = notification.userInfo?["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: - Tab actions

    private func addTab() {
        let tab = TerminalTab(
            title: "Terminal \(tabs.count + 1)",
            initialDirectory: projectPath
        )
        tabs.append(tab)
        selectedTabId = tab.id
    }

    private func launchTask(title: String, command: String) {
        let injectedCommand = injectClaudeHooks(command: command, projectId: projectId)
        let tab = TerminalTab(
            title: title,
            initialDirectory: projectPath,
            initialCommand: injectedCommand
        )
        tabs.append(tab)
        selectedTabId = tab.id
    }

    /// If the command launches Claude Code, inject `--settings` with a Notification hook
    /// that automatically moves in_progress tasks to needs_attention when Claude is waiting.
    private func injectClaudeHooks(command: String, projectId: String) -> String {
        // Only inject for claude commands
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed == "claude" || trimmed.hasPrefix("claude ") else { return command }
        guard !projectId.isEmpty else { return command }

        // Use ~/.scope/hooks/ — no spaces in path (critical for hook command execution)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let hooksDir = homeDir.appendingPathComponent(".scope/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let dbPath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Scope/scope.db").path

        // Write the hook script — queries task titles, updates DB, triggers Scope notification via deep link
        let scriptPath = hooksDir.appendingPathComponent("needs-attention-\(projectId).sh")
        let lines = [
            "#!/bin/bash",
            "TITLES=$(/usr/bin/sqlite3 '\(dbPath)' \"SELECT title FROM taskItems WHERE projectId = '\(projectId)' AND status = 'in_progress' LIMIT 3;\" 2>/dev/null | paste -sd', ' -)",
            "[ -z \"$TITLES\" ] && exit 0",
            "/usr/bin/sqlite3 '\(dbPath)' \"UPDATE taskItems SET status = 'needs_attention' WHERE projectId = '\(projectId)' AND status = 'in_progress';\"",
            "ENCODED=$(python3 -c \"import urllib.parse; print(urllib.parse.quote('$TITLES'))\")",
            "open \"scope://needs-attention?project=\(projectId)&titles=$ENCODED\""
        ]
        try? lines.joined(separator: "\n").appending("\n").write(to: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Write hooks settings JSON to a file (--settings accepts a file path)
        let settingsPath = hooksDir.appendingPathComponent("settings-\(projectId).json")
        let settingsJSON = "{\"hooks\":{\"Notification\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(scriptPath.path)\",\"timeout\":10}]}],\"Stop\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(scriptPath.path)\",\"timeout\":10}]}]}}"
        try? settingsJSON.write(to: settingsPath, atomically: true, encoding: .utf8)

        // Inject --settings pointing to the file (no spaces in path, no escaping needed)
        if trimmed == "claude" {
            return "claude --settings \(settingsPath.path)"
        } else {
            let rest = String(trimmed.dropFirst("claude ".count))
            return "claude --settings \(settingsPath.path) \(rest)"
        }
    }

    private func closeTab(_ tab: TerminalTab) {
        tabs.removeAll { $0.id == tab.id }
        if selectedTabId == tab.id {
            selectedTabId = tabs.last?.id
        }
    }

    // MARK: - Tab button

    @ViewBuilder
    private func tabButton(for tab: TerminalTab) -> some View {
        let isSelected = tab.id == selectedTabId

        HStack(spacing: ScopeTheme.Spacing.xxs) {
            Image(systemName: "terminal")
                .font(ScopeTheme.Font.tag)
                .foregroundColor(isSelected ? .primary : .secondary.opacity(0.5))

            Text(tab.title)
                .font(isSelected ? ScopeTheme.Font.footnoteMedium : ScopeTheme.Font.footnote)
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)

            if tabs.count > 1 {
                Button(action: { closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(ScopeTheme.Colors.controlBg.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .help("Close Tab")
                .opacity(isSelected ? 1 : 0)
            }
        }
        .padding(.horizontal, ScopeTheme.Spacing.sm)
        .padding(.vertical, ScopeTheme.Spacing.xxs)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTabId = tab.id
        }
    }
}
