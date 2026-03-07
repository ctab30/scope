import SwiftUI

/// Three-step onboarding wizard presented on first launch.
/// Detects Claude Code and connects Workspace's MCP server.
struct MCPSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    @State private var claudeStatus: CLIStatus = .checking

    private enum CLIStatus {
        case checking
        case installed
        case notInstalled
        case connecting
        case connected
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: WorkspaceTheme.Spacing.sm) {
                ForEach(0..<3, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, WorkspaceTheme.Spacing.xl)
            .padding(.bottom, WorkspaceTheme.Spacing.lg)

            switch currentStep {
            case 0: welcomeStep
            case 1: connectStep
            case 2: doneStep
            default: EmptyView()
            }
        }
        .frame(width: 440, height: 400)
        .background(WorkspaceTheme.Colors.windowBg)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor.gradient)
                .padding(.bottom, WorkspaceTheme.Spacing.md)

            Text("Welcome to Workspace")
                .font(WorkspaceTheme.Font.largeNumber)
                .padding(.bottom, WorkspaceTheme.Spacing.sm)

            Text("Workspace connects to Claude Code via MCP,\ngiving it project memory, tasks, notes, and more.")
                .font(WorkspaceTheme.Font.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()

            stepButton("Get Started") {
                currentStep = 1
                Task { await detectClaude() }
            }
        }
    }

    // MARK: - Step 2: Connect

    private var connectStep: some View {
        VStack(spacing: 0) {
            Text("Connect Claude Code")
                .font(WorkspaceTheme.Font.title)
                .padding(.bottom, WorkspaceTheme.Spacing.xxs)

            Text("Workspace will register its MCP server\nwith Claude Code on your system.")
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Claude Code status row
            HStack(spacing: WorkspaceTheme.Spacing.md) {
                Image(systemName: "c.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 24)

                Text("Claude Code")
                    .font(WorkspaceTheme.Font.bodyMedium)

                Spacer()

                connectBadge
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.md)
            .padding(.vertical, WorkspaceTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(WorkspaceTheme.Colors.controlBg)
            )
            .padding(.horizontal, 48)

            Spacer()

            stepButton("Continue") {
                currentStep = 2
            }
        }
    }

    @ViewBuilder
    private var connectBadge: some View {
        switch claudeStatus {
        case .checking, .connecting:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .notInstalled:
            Text("Not installed")
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary.opacity(0.5))
        case .connected:
            HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connected")
                    .foregroundColor(.green)
            }
            .font(WorkspaceTheme.Font.footnoteMedium)
        case .failed(let msg):
            Button {
                Task { await connectClaude() }
            } label: {
                Text("Retry")
                    .font(WorkspaceTheme.Font.footnoteMedium)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(msg)
        case .installed:
            Button {
                Task { await connectClaude() }
            } label: {
                Text("Connect")
                    .font(WorkspaceTheme.Font.footnoteMedium)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - Step 3: Done

    private var doneStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
                .padding(.bottom, WorkspaceTheme.Spacing.md)

            Text("You're all set!")
                .font(WorkspaceTheme.Font.largeNumber)
                .padding(.bottom, WorkspaceTheme.Spacing.xs)

            if case .connected = claudeStatus {
                HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                    Image(systemName: "c.circle.fill")
                        .foregroundColor(.white)
                    Text("Claude Code")
                        .font(WorkspaceTheme.Font.footnoteMedium)
                }
                .foregroundColor(.secondary)
                .padding(.bottom, WorkspaceTheme.Spacing.sm)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text("Available MCP tools:")
                    .font(WorkspaceTheme.Font.footnoteSemibold)
                    .foregroundColor(.secondary)
                    .padding(.bottom, WorkspaceTheme.Spacing.xxxs)
                Group {
                    Label("Task management", systemImage: "checklist")
                    Label("Note taking", systemImage: "note.text")
                    Label("Session history", systemImage: "clock")
                    Label("Browser automation", systemImage: "globe")
                    Label("Git operations", systemImage: "arrow.triangle.branch")
                    Label("Codebase search", systemImage: "magnifyingglass")
                }
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 48)

            Spacer()

            Text("Restart your Claude Code session to activate.")
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, WorkspaceTheme.Spacing.xs)

            stepButton("Done") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                dismiss()
            }
        }
    }

    // MARK: - Shared Components

    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(WorkspaceTheme.Font.bodySemibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, WorkspaceTheme.Spacing.xs)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 48)
        .padding(.bottom, WorkspaceTheme.Spacing.xl)
    }

    // MARK: - Logic

    private func shellRun(_ command: String) async -> (status: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (process.terminationStatus, output)
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }

    private func detectClaude() async {
        claudeStatus = .checking
        let result = await shellRun("which claude")
        claudeStatus = (result.status == 0 && !result.output.isEmpty) ? .installed : .notInstalled
    }

    private func connectClaude() async {
        claudeStatus = .connecting
        let binaryPath = ContextInjector.mcpBinaryPath

        // Try `claude mcp add` first
        let result = await shellRun("claude mcp add workspace '\(binaryPath)'")
        if result.status == 0 {
            claudeStatus = .connected
            return
        }

        // Fall back to writing ~/.claude.json directly
        do {
            try installClaudeGlobalMCP(binaryPath: binaryPath)
            claudeStatus = .connected
        } catch {
            claudeStatus = .failed(error.localizedDescription)
        }
    }

    private func installClaudeGlobalMCP(binaryPath: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".claude.json")

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        }

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["workspace"] = ["command": binaryPath]
        config["mcpServers"] = servers

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configPath, options: .atomic)
    }
}
