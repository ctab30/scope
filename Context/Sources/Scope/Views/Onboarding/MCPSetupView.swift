import SwiftUI

/// Four-step onboarding wizard presented on first launch.
/// Guides users through detecting installed CLIs and connecting Scope's MCP server.
struct MCPSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    @State private var cliStatuses: [CLIProvider: CLIStatus] = [:]

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
            // Step indicator
            HStack(spacing: ScopeTheme.Spacing.sm) {
                ForEach(0..<4, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, ScopeTheme.Spacing.xl)
            .padding(.bottom, ScopeTheme.Spacing.lg)

            // Step content — fills remaining space
            switch currentStep {
            case 0: welcomeStep
            case 1: detectStep
            case 2: connectStep
            case 3: doneStep
            default: EmptyView()
            }
        }
        .frame(width: 440, height: 400)
        .background(ScopeTheme.Colors.windowBg)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor.gradient)
                .padding(.bottom, ScopeTheme.Spacing.md)

            Text("Welcome to Scope")
                .font(ScopeTheme.Font.largeNumber)
                .padding(.bottom, ScopeTheme.Spacing.sm)

            Text("Scope connects to your AI coding CLIs via MCP,\ngiving them project memory, tasks, notes, and more.")
                .font(ScopeTheme.Font.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()

            stepButton("Get Started") {
                currentStep = 1
                Task { await detectCLIs() }
            }
        }
    }

    // MARK: - Step 2: Detect CLIs

    private var detectStep: some View {
        VStack(spacing: 0) {
            Text("Detected CLIs")
                .font(ScopeTheme.Font.title)
                .padding(.bottom, ScopeTheme.Spacing.xxs)

            Text("Scope found these AI coding tools on your system.")
                .font(ScopeTheme.Font.footnote)
                .foregroundColor(.secondary)

            Spacer()

            cliList { cli in
                statusBadge(for: cli)
            }

            Spacer()

            stepButton("Continue") {
                currentStep = 2
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for cli: CLIProvider) -> some View {
        switch cliStatuses[cli] ?? .checking {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .installed, .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(ScopeTheme.Font.headline)
                .foregroundColor(.green)
        case .notInstalled:
            Image(systemName: "xmark.circle")
                .font(ScopeTheme.Font.headline)
                .foregroundColor(.secondary.opacity(0.5))
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ScopeTheme.Font.headline)
                .foregroundColor(.orange)
        }
    }

    // MARK: - Step 3: Connect

    private var connectStep: some View {
        VStack(spacing: 0) {
            Text("Connect MCP")
                .font(ScopeTheme.Font.title)
                .padding(.bottom, ScopeTheme.Spacing.xxs)

            Text("Click Connect to configure each CLI\nto use Scope's MCP server.")
                .font(ScopeTheme.Font.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            cliList { cli in
                connectButton(for: cli, status: cliStatuses[cli] ?? .notInstalled)
            }

            Spacer()

            stepButton("Continue") {
                currentStep = 3
            }
        }
    }

    @ViewBuilder
    private func connectButton(for cli: CLIProvider, status: CLIStatus) -> some View {
        switch status {
        case .notInstalled:
            Text("Not installed")
                .font(ScopeTheme.Font.footnote)
                .foregroundColor(.secondary.opacity(0.5))
        case .checking, .connecting:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .connected:
            HStack(spacing: ScopeTheme.Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connected")
                    .foregroundColor(.green)
            }
            .font(ScopeTheme.Font.footnoteMedium)
        case .failed(let msg):
            Button {
                Task { await connectCLI(cli) }
            } label: {
                Text("Retry")
                    .font(ScopeTheme.Font.footnoteMedium)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(msg)
        case .installed:
            Button {
                Task { await connectCLI(cli) }
            } label: {
                Text("Connect")
                    .font(ScopeTheme.Font.footnoteMedium)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
                .padding(.bottom, ScopeTheme.Spacing.md)

            Text("You're all set!")
                .font(ScopeTheme.Font.largeNumber)
                .padding(.bottom, ScopeTheme.Spacing.xs)

            let connectedCLIs = CLIProvider.allCases.filter {
                if case .connected = cliStatuses[$0] { return true }
                return false
            }

            if !connectedCLIs.isEmpty {
                HStack(spacing: ScopeTheme.Spacing.md) {
                    ForEach(connectedCLIs) { cli in
                        HStack(spacing: ScopeTheme.Spacing.xxs) {
                            Image(systemName: cli.iconName)
                                .foregroundColor(cli.color)
                            Text(cli.displayName)
                                .font(ScopeTheme.Font.footnoteMedium)
                        }
                    }
                }
                .foregroundColor(.secondary)
                .padding(.bottom, ScopeTheme.Spacing.sm)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text("Available MCP tools:")
                    .font(ScopeTheme.Font.footnoteSemibold)
                    .foregroundColor(.secondary)
                    .padding(.bottom, ScopeTheme.Spacing.xxxs)
                Group {
                    Label("Task management", systemImage: "checklist")
                    Label("Note taking", systemImage: "note.text")
                    Label("Session history", systemImage: "clock")
                    Label("Browser automation", systemImage: "globe")
                    Label("Git operations", systemImage: "arrow.triangle.branch")
                    Label("Codebase search", systemImage: "magnifyingglass")
                }
                .font(ScopeTheme.Font.footnote)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 48)

            Spacer()

            Text("Restart your CLI sessions to activate.")
                .font(ScopeTheme.Font.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, ScopeTheme.Spacing.xs)

            stepButton("Done") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                dismiss()
            }
        }
    }

    // MARK: - Shared Components

    /// Consistent bottom action button used by every step.
    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ScopeTheme.Font.bodySemibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ScopeTheme.Spacing.xs)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 48)
        .padding(.bottom, ScopeTheme.Spacing.xl)
    }

    /// Reusable CLI list used by detect and connect steps.
    private func cliList<Trailing: View>(@ViewBuilder trailing: @escaping (CLIProvider) -> Trailing) -> some View {
        VStack(spacing: ScopeTheme.Spacing.xxs) {
            ForEach(CLIProvider.allCases) { cli in
                HStack(spacing: ScopeTheme.Spacing.md) {
                    Image(systemName: cli.iconName)
                        .font(.system(size: 16))
                        .foregroundColor(cli.color)
                        .frame(width: 24)

                    Text(cli.displayName)
                        .font(ScopeTheme.Font.bodyMedium)

                    Spacer()

                    trailing(cli)
                }
                .padding(.horizontal, ScopeTheme.Spacing.md)
                .padding(.vertical, ScopeTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .fill(ScopeTheme.Colors.controlBg)
                )
            }
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Logic

    /// Run a shell command using a login shell so the user's full PATH is available.
    /// GUI .app bundles have a minimal PATH that won't include homebrew/npm bins.
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

    private func detectCLIs() async {
        for cli in CLIProvider.allCases {
            cliStatuses[cli] = .checking
        }

        // Use login shell to find CLIs (GUI apps have limited PATH)
        for cli in CLIProvider.allCases {
            let result = await shellRun("which \(cli.command)")
            cliStatuses[cli] = (result.status == 0 && !result.output.isEmpty) ? .installed : .notInstalled
        }
    }

    private func connectCLI(_ cli: CLIProvider) async {
        cliStatuses[cli] = .connecting
        let binaryPath = ContextInjector.mcpBinaryPath

        if cli == .claude {
            // Use login shell so `claude` is found in PATH
            let result = await shellRun("claude mcp add scope '\(binaryPath)'")
            if result.status == 0 {
                cliStatuses[cli] = .connected
                return
            }
            // Fall through to file-based config
        }

        // File-based MCP config for non-Claude CLIs or as Claude fallback
        do {
            let injector = ContextInjector()
            if cli == .claude {
                // Claude's config is project-scoped (.mcp.json), so for global setup
                // write directly to ~/.claude.json
                try installClaudeGlobalMCP(binaryPath: binaryPath)
            } else {
                _ = try injector.installMCP(for: cli, projectPath: "")
            }
            cliStatuses[cli] = .connected
        } catch {
            cliStatuses[cli] = .failed(error.localizedDescription)
        }
    }

    /// Write MCP config to Claude Code's global settings file (~/.claude.json).
    private func installClaudeGlobalMCP(binaryPath: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".claude.json")

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        }

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["scope"] = ["command": binaryPath]
        config["mcpServers"] = servers

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configPath, options: .atomic)
    }
}
