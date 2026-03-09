import SwiftUI

/// Four-step onboarding wizard presented on first launch.
/// Detects Claude Code and connects Workspace's MCP server.
struct MCPSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    @State private var claudeStatus: CLIStatus = .checking

    private let totalSteps = 4

    private enum CLIStatus: Equatable {
        case checking
        case installed
        case notInstalled
        case connecting
        case connected
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: WorkspaceTheme.Spacing.sm) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, WorkspaceTheme.Spacing.xl)
            .padding(.bottom, WorkspaceTheme.Spacing.lg)

            switch currentStep {
            case 0: welcomeStep
            case 1: howItWorksStep
            case 2: connectStep
            case 3: readyStep
            default: EmptyView()
            }
        }
        .frame(width: 440, height: 460)
        .background(WorkspaceTheme.Colors.windowBg)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor.gradient)
                .padding(.bottom, WorkspaceTheme.Spacing.md)

            Text("Welcome to Workspace")
                .font(WorkspaceTheme.Font.largeNumber)
                .padding(.bottom, WorkspaceTheme.Spacing.sm)

            Text("Give Claude Code persistent memory, tasks,\nnotes, and browser tools across sessions.")
                .font(WorkspaceTheme.Font.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()

            // Feature highlights
            VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.sm) {
                featureRow(icon: "brain", color: .purple, text: "Project context that persists between sessions")
                featureRow(icon: "checklist", color: .blue, text: "Track tasks and decisions as you build")
                featureRow(icon: "globe", color: .teal, text: "Let Claude browse, click, and test your app")
            }
            .padding(.horizontal, 52)

            Spacer()

            stepButton("Get Started") {
                currentStep = 1
            }
        }
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: WorkspaceTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color)
                .frame(width: 20, alignment: .center)

            Text(text)
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Step 2: How it works

    private var howItWorksStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "link")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor.gradient)
                .padding(.bottom, WorkspaceTheme.Spacing.md)

            Text("How it works")
                .font(WorkspaceTheme.Font.largeNumber)
                .padding(.bottom, WorkspaceTheme.Spacing.lg)

            // Explanation rows
            VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.lg) {
                explanationRow(
                    icon: "desktopcomputer",
                    color: .blue,
                    title: "Workspace runs a local server",
                    desc: "A small background process on your machine — nothing leaves your computer."
                )
                explanationRow(
                    icon: "arrow.left.arrow.right",
                    color: .purple,
                    title: "Claude Code connects via MCP",
                    desc: "Model Context Protocol lets Claude use tools like tasks, notes, and browser."
                )
                explanationRow(
                    icon: "arrow.triangle.2.circlepath",
                    color: .teal,
                    title: "Everything stays in sync",
                    desc: "Changes from Claude show up in Workspace instantly, and vice versa."
                )
            }
            .padding(.horizontal, 44)

            Spacer()

            stepButton("Set it up") {
                currentStep = 2
                Task { await detectAndConnect() }
            }
        }
    }

    private func explanationRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: WorkspaceTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WorkspaceTheme.Font.footnoteSemibold)

                Text(desc)
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: - Step 3: Connect

    private var connectStep: some View {
        VStack(spacing: 0) {
            Text("Connecting to Claude Code")
                .font(WorkspaceTheme.Font.title)
                .padding(.bottom, WorkspaceTheme.Spacing.xxs)

            Text("Workspace registers as an MCP server so Claude\ncan read and write to your project workspace.")
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Connection status card
            VStack(spacing: 0) {
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

                // Show hint when not installed
                if case .notInstalled = claudeStatus {
                    Divider()
                        .padding(.horizontal, WorkspaceTheme.Spacing.sm)
                    Text("Install Claude Code first, then reopen Workspace.\nnpm install -g @anthropic-ai/claude-code")
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundColor(.secondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, WorkspaceTheme.Spacing.md)
                        .padding(.vertical, WorkspaceTheme.Spacing.sm)
                        .textSelection(.enabled)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(WorkspaceTheme.Colors.controlBg)
            )
            .padding(.horizontal, 48)

            Spacer()

            if claudeStatus == .connected {
                stepButton("Continue") {
                    currentStep = 3
                }
            } else {
                // Skip option — don't block onboarding
                stepButton("Skip for Now") {
                    currentStep = 3
                }
                .opacity(claudeStatus == .checking || claudeStatus == .connecting ? 0.4 : 1.0)
            }
        }
    }

    @ViewBuilder
    private var connectBadge: some View {
        switch claudeStatus {
        case .checking, .connecting:
            HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(claudeStatus == .checking ? "Detecting..." : "Connecting...")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundColor(.secondary)
            }
        case .notInstalled:
            Text("Not found")
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

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 0) {
            Spacer()

            if case .connected = claudeStatus {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                    .padding(.bottom, WorkspaceTheme.Spacing.md)

                Text("You're all set")
                    .font(WorkspaceTheme.Font.largeNumber)
                    .padding(.bottom, WorkspaceTheme.Spacing.xs)
            } else {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor.gradient)
                    .padding(.bottom, WorkspaceTheme.Spacing.md)

                Text("Almost there")
                    .font(WorkspaceTheme.Font.largeNumber)
                    .padding(.bottom, WorkspaceTheme.Spacing.xs)

                Text("Connect Claude Code from Settings when you're ready.")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, WorkspaceTheme.Spacing.sm)
            }

            Spacer()

            // Usage expectations card
            VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.sm) {
                Text("Workspace works automatically.")
                    .font(WorkspaceTheme.Font.footnoteSemibold)

                Text("Claude Code will use these tools on its own when relevant — creating tasks, saving notes, and checking context as it works.")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)

                Text("You can also ask Claude directly:")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, WorkspaceTheme.Spacing.xxxs)

                VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xxs) {
                    promptExample("\"save this as a task\"")
                    promptExample("\"check my workspace for notes on this\"")
                    promptExample("\"open the browser and test the login page\"")
                }
            }
            .padding(WorkspaceTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(WorkspaceTheme.Colors.controlBg)
            )
            .padding(.horizontal, 44)

            Spacer()

            if case .connected = claudeStatus {
                Text("Start a new Claude Code session to activate.")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.bottom, WorkspaceTheme.Spacing.xs)
            }

            stepButton("Done") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                dismiss()
            }
        }
    }

    private func promptExample(_ text: String) -> some View {
        HStack(spacing: WorkspaceTheme.Spacing.xs) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.accentColor)

            Text(text)
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.secondary)
                .italic()
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

    /// Detect Claude Code and auto-connect if found.
    private func detectAndConnect() async {
        claudeStatus = .checking

        // Check common install paths first (GUI apps have limited PATH)
        let home = NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.npm/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.nvm/current/bin/claude",
        ]

        var found = false
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                found = true
                break
            }
        }

        // Fallback to which
        if !found {
            let result = await shellRun("which claude")
            found = result.status == 0 && !result.output.isEmpty
        }

        if found {
            // Auto-connect immediately
            await connectClaude()
        } else {
            claudeStatus = .notInstalled
        }
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
