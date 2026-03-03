# Multi-CLI Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add support for Claude Code, Gemini CLI, Codex CLI, and OpenCode CLI — with quick-launch buttons, per-CLI MCP installers, instruction file writers, and a preferred CLI setting.

**Architecture:** CLIProvider enum as single source of truth. All features (launcher, installer, instruction writer, settings) derive from this registry. See `docs/plans/2026-02-22-multi-cli-support-design.md` for full design.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, GRDB (existing), UserDefaults

---

### Task 1: Create CLIProvider Enum

**Files:**
- Create: `Context/Sources/Context/Models/CLIProvider.swift`

**Step 1: Create the CLIProvider enum**

```swift
import SwiftUI

/// Registry of supported AI coding CLI tools.
/// Single source of truth for all CLI metadata — display info, commands,
/// config paths, and installation detection.
enum CLIProvider: String, CaseIterable, Codable, Identifiable {
    case claude
    case gemini
    case codex
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .codex: return "Codex CLI"
        case .opencode: return "OpenCode"
        }
    }

    var command: String {
        switch self {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .codex: return "codex"
        case .opencode: return "opencode"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "c.circle.fill"
        case .gemini: return "g.circle.fill"
        case .codex: return "x.circle.fill"
        case .opencode: return "o.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .claude: return .orange
        case .gemini: return .blue
        case .codex: return .green
        case .opencode: return .purple
        }
    }

    var instructionFileName: String {
        switch self {
        case .claude: return "CLAUDE.md"
        case .gemini: return "GEMINI.md"
        case .codex: return "AGENTS.md"
        case .opencode: return "INSTRUCTIONS.md"
        }
    }

    /// Check if this CLI is installed by looking for it in PATH.
    var isInstalled: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - MCP Config

    /// Where this CLI's MCP config lives.
    /// Some are project-scoped (return path relative to project), some are global.
    enum ConfigScope {
        case projectRoot(String)  // filename in project root
        case userHome(String)     // path relative to ~
    }

    var mcpConfigScope: ConfigScope {
        switch self {
        case .claude: return .projectRoot(".mcp.json")
        case .gemini: return .userHome(".gemini/settings.json")
        case .codex: return .userHome(".codex/config.toml")
        case .opencode: return .projectRoot("opencode.json")
        }
    }

    /// Generate the MCP config content for this CLI.
    func mcpConfigContent(binaryPath: String) -> String {
        switch self {
        case .claude:
            return """
            {
              "mcpServers": {
                "context-tasks": {
                  "command": "\(binaryPath)"
                }
              }
            }
            """

        case .gemini:
            return """
            {
              "mcpServers": {
                "context-tasks": {
                  "command": "\(binaryPath)"
                }
              }
            }
            """

        case .codex:
            return """
            [mcp_servers.context-tasks]
            command = "\(binaryPath)"
            args = []
            """

        case .opencode:
            return """
            {
              "mcp": {
                "context-tasks": {
                  "type": "local",
                  "command": ["\(binaryPath)"]
                }
              }
            }
            """
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Models/CLIProvider.swift
git commit -m "feat: add CLIProvider enum as registry for supported AI CLIs"
```

---

### Task 2: Add Preferred CLI Setting

**Files:**
- Modify: `Context/Sources/Context/Services/AppSettings.swift:3-52`

**Step 1: Add preferredCLI property to AppSettings**

Add after line 36 (after `embeddingModel`):

```swift
    @Published var preferredCLI: CLIProvider {
        didSet { UserDefaults.standard.set(preferredCLI.rawValue, forKey: "preferredCLI") }
    }
```

In `init()`, add after line 50 (after `embeddingModel` init):

```swift
        if let cliRaw = defaults.string(forKey: "preferredCLI"),
           let cli = CLIProvider(rawValue: cliRaw) {
            self.preferredCLI = cli
        } else {
            self.preferredCLI = .claude
        }
```

**Step 2: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/AppSettings.swift
git commit -m "feat: add preferredCLI setting to AppSettings"
```

---

### Task 3: Add Preferred CLI Picker to Settings UI

**Files:**
- Modify: `Context/Sources/Context/Views/SettingsView.swift:35-44` (GeneralSettingsTab)

**Step 1: Replace the empty GeneralSettingsTab with a preferred CLI picker**

Replace the `GeneralSettingsTab` struct (lines 35-44) with:

```swift
private struct GeneralSettingsTab: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            Section("Preferred CLI") {
                Picker("Default coding CLI", selection: $appSettings.preferredCLI) {
                    ForEach(CLIProvider.allCases) { cli in
                        HStack(spacing: 8) {
                            Image(systemName: cli.iconName)
                                .foregroundColor(cli.color)
                            Text(cli.displayName)
                            if !cli.isInstalled {
                                Text("Not installed")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tag(cli)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("Used for task launcher and quick-launch buttons")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/SettingsView.swift
git commit -m "feat: add preferred CLI picker to Settings > General"
```

---

### Task 4: Update TaskLauncherView to Use Preferred CLI

**Files:**
- Modify: `Context/Sources/Context/Views/Dashboard/TaskLauncherView.swift:96-106,108-123`

**Step 1: Add appSettings dependency and update launch methods**

Add `@EnvironmentObject var appSettings: AppSettings` at the top of `TaskLauncherView` (after `appState`).

In `launchPreset()` (line 99), change:
```swift
let command = "claude \"\(escaped)\""
```
to:
```swift
let command = "\(appSettings.preferredCLI.command) \"\(escaped)\""
```

In `launchCustom()` (line 113), change:
```swift
let command = "claude \"\(escaped)\""
```
to:
```swift
let command = "\(appSettings.preferredCLI.command) \"\(escaped)\""
```

**Step 2: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Dashboard/TaskLauncherView.swift
git commit -m "feat: TaskLauncherView uses preferred CLI instead of hardcoded claude"
```

---

### Task 5: Extend ContextInjector with Per-CLI MCP Config Writers

**Files:**
- Modify: `Context/Sources/Context/Services/ContextInjector.swift`

**Step 1: Add per-CLI MCP config installation method**

Add the following methods after the existing `configureMCPConnection()` method (after line 148):

```swift
    // MARK: - Per-CLI MCP Installation

    /// The deployed ScopeMCP binary path.
    static var mcpBinaryPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Context/bin/ScopeMCP")
            .path
    }

    /// Install MCP config for a specific CLI provider.
    /// Merge-safe: parses existing config and only adds/updates the context-tasks entry.
    func installMCP(for cli: CLIProvider, projectPath: String) throws -> String {
        let binaryPath = Self.mcpBinaryPath
        guard fileManager.fileExists(atPath: binaryPath) else {
            throw InjectorError.fileOperationFailed("ScopeMCP binary not found at \(binaryPath)")
        }

        let configPath: String
        switch cli.mcpConfigScope {
        case .projectRoot(let filename):
            guard !projectPath.isEmpty else { throw InjectorError.projectPathMissing }
            configPath = (projectPath as NSString).appendingPathComponent(filename)
        case .userHome(let relativePath):
            configPath = (NSHomeDirectory() as NSString).appendingPathComponent(relativePath)
        }

        switch cli {
        case .claude:
            try installClaudeMCP(at: configPath, binaryPath: binaryPath)
        case .gemini:
            try installGeminiMCP(at: configPath, binaryPath: binaryPath)
        case .codex:
            try installCodexMCP(at: configPath, binaryPath: binaryPath)
        case .opencode:
            try installOpenCodeMCP(at: configPath, binaryPath: binaryPath)
        }

        return configPath
    }

    // MARK: - Claude (.mcp.json — JSON, mcpServers key)

    private func installClaudeMCP(at path: String, binaryPath: String) throws {
        var config = readJSONDict(at: path)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["context-tasks"] = ["command": binaryPath]
        config["mcpServers"] = servers
        try writeJSON(config, to: path)
    }

    // MARK: - Gemini (~/.gemini/settings.json — JSON, mcpServers key)

    private func installGeminiMCP(at path: String, binaryPath: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config = readJSONDict(at: path)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["context-tasks"] = ["command": binaryPath]
        config["mcpServers"] = servers
        try writeJSON(config, to: path)
    }

    // MARK: - Codex (~/.codex/config.toml — TOML, [mcp_servers.name])

    private func installCodexMCP(at path: String, binaryPath: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let section = """

        [mcp_servers.context-tasks]
        command = "\(binaryPath)"
        args = []
        """

        if fileManager.fileExists(atPath: path) {
            var content = try String(contentsOfFile: path, encoding: .utf8)
            // Remove existing context-tasks section if present
            let pattern = #"\[mcp_servers\.context-tasks\][^\[]*"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                content = regex.stringByReplacingMatches(
                    in: content,
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: ""
                )
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            content += "\n" + section + "\n"
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try section.trimmingCharacters(in: .newlines)
                .appending("\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - OpenCode (opencode.json — JSON, mcp key)

    private func installOpenCodeMCP(at path: String, binaryPath: String) throws {
        var config = readJSONDict(at: path)
        var mcp = config["mcp"] as? [String: Any] ?? [:]
        mcp["context-tasks"] = [
            "type": "local",
            "command": [binaryPath]
        ] as [String: Any]
        config["mcp"] = mcp
        try writeJSON(config, to: path)
    }

    // MARK: - JSON Helpers

    private func readJSONDict(at path: String) -> [String: Any] {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    private func writeJSON(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
```

**Step 2: Add per-CLI instruction file writer**

Add after the MCP methods:

```swift
    // MARK: - Per-CLI Instruction File Management

    /// Write the Scope.app managed section to the appropriate instruction file for this CLI.
    func updateInstructionFile(for cli: CLIProvider, projectPath: String) throws {
        guard !projectPath.isEmpty else { throw InjectorError.projectPathMissing }

        let filePath = (projectPath as NSString)
            .appendingPathComponent(cli.instructionFileName)
        let section = buildManagedSection()

        if fileManager.fileExists(atPath: filePath) {
            var content = try String(contentsOfFile: filePath, encoding: .utf8)
            if let range = findManagedSectionRange(in: content) {
                content.replaceSubrange(range, with: section)
            } else {
                if !content.hasSuffix("\n") { content += "\n" }
                content += "\n" + section + "\n"
            }
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        } else {
            try (section + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }

    /// Check if the managed section exists in this CLI's instruction file.
    func hasInstructionFile(for cli: CLIProvider, projectPath: String) -> Bool {
        guard !projectPath.isEmpty else { return false }
        let filePath = (projectPath as NSString)
            .appendingPathComponent(cli.instructionFileName)
        guard fileManager.fileExists(atPath: filePath),
              let content = try? String(contentsOfFile: filePath, encoding: .utf8)
        else { return false }
        return findManagedSectionRange(in: content) != nil
    }
```

**Step 3: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Context/Sources/Context/Services/ContextInjector.swift
git commit -m "feat: per-CLI MCP config installers and instruction file writers"
```

---

### Task 6: Create CLIQuickLaunchView

**Files:**
- Create: `Context/Sources/Context/Views/CLIQuickLaunchView.swift`

**Step 1: Create the quick-launch button bar with dropdown menus**

```swift
import SwiftUI

/// Quick-launch buttons for each supported CLI, displayed in the terminal tab bar.
/// Each button opens a dropdown with launch options and MCP/instruction setup.
struct CLIQuickLaunchView: View {
    @EnvironmentObject var appSettings: AppSettings
    let projectPath: String
    let onLaunchCLI: (_ title: String, _ command: String) -> Void

    @State private var promptText: [CLIProvider: String] = [:]
    @State private var setupResult: String?
    @State private var showingToast = false

    private let injector = ContextInjector()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CLIProvider.allCases) { cli in
                cliMenu(for: cli)
            }
        }
    }

    @ViewBuilder
    private func cliMenu(for cli: CLIProvider) -> some View {
        let installed = cli.isInstalled
        let isPreferred = appSettings.preferredCLI == cli

        Menu {
            if installed {
                Button("Launch \(cli.displayName)") {
                    onLaunchCLI(cli.displayName, cli.command)
                }

                Button("Launch with prompt...") {
                    // Launch with empty prompt — the terminal is interactive
                    onLaunchCLI(cli.displayName, cli.command)
                }

                Divider()
            }

            Button("Setup MCP") {
                setupMCP(for: cli)
            }

            Button("Setup Instructions") {
                setupInstructions(for: cli)
            }

            Divider()

            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .disabled(true)
            } else {
                Label("Not installed", systemImage: "xmark.circle")
                    .disabled(true)
            }

            if isPreferred {
                Label("Preferred CLI", systemImage: "star.fill")
                    .disabled(true)
            } else {
                Button("Set as Preferred") {
                    appSettings.preferredCLI = cli
                }
            }
        } label: {
            ZStack {
                Image(systemName: cli.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(installed ? cli.color : .secondary.opacity(0.3))
                    .frame(width: 28, height: 26)

                // Preferred indicator dot
                if isPreferred {
                    Circle()
                        .fill(cli.color)
                        .frame(width: 5, height: 5)
                        .offset(x: 8, y: -8)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help(cli.displayName + (installed ? "" : " (not installed)"))
    }

    // MARK: - Setup Actions

    private func setupMCP(for cli: CLIProvider) {
        do {
            let path = try injector.installMCP(for: cli, projectPath: projectPath)
            setupResult = "MCP configured for \(cli.displayName) at \(path)"
        } catch {
            setupResult = "Failed: \(error.localizedDescription)"
        }
        showToast()
    }

    private func setupInstructions(for cli: CLIProvider) {
        do {
            try injector.updateInstructionFile(for: cli, projectPath: projectPath)
            setupResult = "\(cli.instructionFileName) updated"
        } catch {
            setupResult = "Failed: \(error.localizedDescription)"
        }
        showToast()
    }

    private func showToast() {
        showingToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showingToast = false
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/CLIQuickLaunchView.swift
git commit -m "feat: add CLIQuickLaunchView with dropdown menus per CLI"
```

---

### Task 7: Integrate CLIQuickLaunchView into TerminalTabView

**Files:**
- Modify: `Context/Sources/Context/Views/Terminal/TerminalTabView.swift:23-43`

**Step 1: Add CLIQuickLaunchView to the tab bar**

In `TerminalTabView`, the tab bar `HStack` (starting at line 26) currently has tabs, a `+` button, and `Spacer()`. Add the `CLIQuickLaunchView` after the `Spacer()` (before the closing `}` of the HStack on line 43):

Replace the tab bar HStack (lines 26-43):

```swift
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabButton(for: tab)
                }

                Button(action: addTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)

                Spacer()

                CLIQuickLaunchView(
                    projectPath: projectPath,
                    onLaunchCLI: { title, command in
                        launchTask(title: title, command: command)
                    }
                )
                .padding(.trailing, 6)
            }
```

**Step 2: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Terminal/TerminalTabView.swift
git commit -m "feat: integrate CLI quick-launch buttons into terminal tab bar"
```

---

### Task 8: Rename claudeMDInjection Setting to instructionInjection

**Files:**
- Modify: `Context/Sources/Context/Services/AppSettings.swift`
- Modify: `Context/Sources/Context/Views/SettingsView.swift:175`

This is optional but recommended for consistency — the existing `claudeMDInjection` toggle now applies to all CLIs, not just Claude.

**Step 1: Rename in AppSettings**

In `AppSettings.swift`, rename `claudeMDInjection` to `instructionInjection`. Keep the same UserDefaults key (`"claudeMDInjection"`) for backward compatibility so existing users don't lose their setting.

**Step 2: Update the label in SettingsView**

In `SettingsView.swift` line 175, change:
```swift
Toggle("CLAUDE.md injection", isOn: $settings.claudeMDInjection)
```
to:
```swift
Toggle("Instruction file injection", isOn: $settings.instructionInjection)
```

**Step 3: Verify it compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Context/Sources/Context/Services/AppSettings.swift Context/Sources/Context/Views/SettingsView.swift
git commit -m "refactor: rename claudeMDInjection to instructionInjection for multi-CLI"
```

---

### Task 9: Build and Smoke Test

**Files:** None (verification only)

**Step 1: Full clean build**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors

**Step 2: Launch the app and verify**

Manual verification checklist:
- [ ] Settings > General shows the Preferred CLI radio group
- [ ] Terminal tab bar shows CLI quick-launch buttons on the right
- [ ] Clicking a CLI button shows the dropdown menu
- [ ] "Setup MCP" writes the correct config file for each CLI
- [ ] "Setup Instructions" writes the correct instruction file
- [ ] Task Launcher presets use the preferred CLI's command
- [ ] Uninstalled CLIs appear dimmed in the quick-launch bar

**Step 3: Commit any fixes from smoke testing**

```bash
git add -A
git commit -m "fix: address issues found during smoke testing"
```
