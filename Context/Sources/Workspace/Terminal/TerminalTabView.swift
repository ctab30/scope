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
                        .font(WorkspaceTheme.Font.footnoteMedium)
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, WorkspaceTheme.Spacing.xxxs)
                .help("New Tab")

                Spacer()

                CLIQuickLaunchView(
                    projectPath: projectPath,
                    onLaunchCLI: { title, command in
                        launchTask(title: title, command: command)
                    }
                )
                .padding(.trailing, WorkspaceTheme.Spacing.xs)
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.xs)
            .padding(.vertical, WorkspaceTheme.Spacing.xxs)
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
                        },
                        onViewCreated: { view in
                            tab.terminalView = view
                        }
                    )
                    .blendMode(.screen)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                }
            }
            .padding(.leading, WorkspaceTheme.Spacing.xs)
            .overlay {
                if tabs.isEmpty {
                    VStack(spacing: WorkspaceTheme.Spacing.sm) {
                        Image(systemName: "terminal")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No terminal open")
                            .font(WorkspaceTheme.Font.footnote)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Clear attention on the selected tab when user returns to the app
            if let tab = tabs.first(where: { $0.id == selectedTabId }) {
                tab.needsAttention = false
            }
        }
        .onChange(of: selectedTabId) { _, newId in
            // Clear attention state when user selects a tab
            if let tab = tabs.first(where: { $0.id == newId }) {
                tab.needsAttention = false
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .claudeProcessDidExit)) { _ in
            // Mark the current tab as needing attention when Claude exits
            if let tab = tabs.first(where: { $0.id == selectedTabId }) {
                tab.needsAttention = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalInput)) { notification in
            // Clear attention when user types in a terminal
            guard let inputView = notification.object as? NSView else { return }
            if let tab = tabs.first(where: { $0.terminalView === inputView }) {
                tab.needsAttention = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalBell)) { notification in
            // Mark the tab that rang the bell as needing attention
            guard let bellView = notification.object as? NSView else { return }
            if let tab = tabs.first(where: { $0.terminalView === bellView }) {
                // Only flag if this tab isn't currently visible and focused
                if tab.id != selectedTabId || !NSApp.isActive {
                    tab.needsAttention = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionNeedsAttention)) { notification in
            // Hook-based notification: match tab by checking if its shell PID
            // is in the hook's ancestor chain. Falls back to all project tabs.
            let notifPath = notification.userInfo?["projectPath"] as? String
            let ancestorsStr = notification.userInfo?["ancestors"] as? String
            let shouldHandle = notifPath == nil || notifPath == projectPath
            guard shouldHandle else { return }

            // Parse ancestor PIDs from comma-separated string
            if let ancestorsStr {
                let ancestorPids = Set(ancestorsStr.split(separator: ",").compactMap { Int32($0) })
                if !ancestorPids.isEmpty {
                    if let tab = tabs.first(where: { ancestorPids.contains($0.shellPid) }) {
                        tab.needsAttention = true
                        return
                    }
                }
            }

            // Fallback: mark all tabs for this project
            for tab in tabs {
                tab.needsAttention = true
            }
        }
    }

    // MARK: - Tab actions

    private func addTab() {
        let tab = TerminalTab(
            title: "Terminal \(tabs.count + 1)",
            initialDirectory: projectPath.isEmpty ? NSHomeDirectory() : projectPath
        )
        tabs.append(tab)
        selectedTabId = tab.id
    }

    private func launchTask(title: String, command: String) {
        let tab = TerminalTab(
            title: title,
            initialDirectory: projectPath,
            initialCommand: command
        )
        tabs.append(tab)
        selectedTabId = tab.id
    }

    private func closeTab(_ tab: TerminalTab) {
        tabs.removeAll { $0.id == tab.id }
        if selectedTabId == tab.id {
            selectedTabId = tabs.last?.id
        }
    }

    // MARK: - Tab button

    private func tabButton(for tab: TerminalTab) -> some View {
        TabButton(tab: tab, isSelected: tab.id == selectedTabId, showClose: tabs.count > 1) {
            tab.needsAttention = false
            selectedTabId = tab.id
        } onClose: {
            closeTab(tab)
        }
    }
}

/// Extracted so @ObservedObject subscribes to TerminalTab's @Published properties (needsAttention).
private struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let showClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: WorkspaceTheme.Spacing.xxs) {
            if tab.needsAttention {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.red)
                    .symbolEffect(.pulse, isActive: true)
            }

            Image(systemName: tab.needsAttention ? "exclamationmark.terminal" : "terminal")
                .font(WorkspaceTheme.Font.tag)
                .foregroundColor(tab.needsAttention ? .red : (isSelected ? .primary : .secondary.opacity(0.5)))

            Text(tab.title)
                .font(isSelected ? WorkspaceTheme.Font.footnoteMedium : WorkspaceTheme.Font.footnote)
                .lineLimit(1)
                .foregroundColor(tab.needsAttention ? .red : (isSelected ? .primary : .secondary))

            if showClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(WorkspaceTheme.Colors.controlBg.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .help("Close Tab")
                .opacity(isSelected ? 1 : 0)
            }
        }
        .padding(.horizontal, WorkspaceTheme.Spacing.sm)
        .padding(.vertical, WorkspaceTheme.Spacing.xxs)
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                .strokeBorder(Color.red.opacity(tab.needsAttention ? 0.6 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}
