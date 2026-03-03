# Multi-CLI Support Design

**Date:** 2026-02-22
**Status:** Approved

## Goal

Make Scope.app work seamlessly with Claude Code, Gemini CLI, Codex CLI, and OpenCode CLI. Users can launch any CLI from the terminal, install MCP configs per-CLI, and set a preferred CLI that all task presets respect.

## Architecture: CLI Registry Model

A `CLIProvider` enum serves as the single source of truth for all CLI metadata. Every feature (launcher, installer, instruction writer) derives from this registry. Adding a new CLI = adding one enum case.

### CLIProvider Enum

```swift
enum CLIProvider: String, CaseIterable, Codable, Identifiable {
    case claude, gemini, codex, opencode

    var id: String { rawValue }
    var displayName: String        // "Claude Code", "Gemini CLI", etc.
    var command: String             // "claude", "gemini", "codex", "opencode"
    var iconName: String            // SF Symbol
    var color: Color                // Brand color for UI
    var mcpConfigFormat: ConfigFormat
    var instructionFileName: String // "CLAUDE.md", "GEMINI.md", "AGENTS.md", "INSTRUCTIONS.md"
    var isInstalled: Bool           // Checks PATH for binary

    func mcpConfigPath(for project: Project) -> String
    func mcpConfigContent(binaryPath: String) -> String
}
```

## Feature 1: Preferred CLI Setting

- New `preferredCLI: CLIProvider` property in `AppSettings`, stored in UserDefaults
- Defaults to `.claude`
- Shown in Settings > General as a radio group
- Uninstalled CLIs shown greyed out with "Not installed"
- TaskLauncherView reads this to build the launch command

## Feature 2: Quick-Launch Buttons

Positioned right side of terminal tab bar:

```
[Terminal 1] [Terminal 2] [+]           [C v] [G v] [X v] [O v]
```

Each button opens a dropdown menu:
- **Launch [CLI]** — New terminal tab running the CLI interactively
- **Launch with prompt...** — New tab with `cli "prompt"`
- **Setup MCP** — Writes MCP config for this CLI
- **Setup Instructions** — Writes instruction file for this CLI
- **Status** — Installed / Not found

Preferred CLI gets a subtle visual indicator (ring/dot).
Uninstalled CLIs are dimmed, show only "Not installed" status.

## Feature 3: MCP Config Installer

Per-CLI config writing via `ContextInjector`. Merge-safe — never overwrites existing servers.

| CLI | Config File | Format | Key |
|-----|------------|--------|-----|
| Claude | `.mcp.json` (project root) | JSON | `mcpServers` |
| Gemini | `~/.gemini/settings.json` | JSON | `mcpServers` |
| Codex | `~/.codex/config.toml` | TOML | `[mcp_servers.name]` |
| OpenCode | `opencode.json` (project root) | JSONC | `mcp` |

Behaviors:
- Merge, don't overwrite — parse existing file, add/update `context-tasks` entry only
- Expand `~` to absolute path for Codex (TOML requires it)
- Idempotent — running twice produces same result
- Show confirmation toast after writing

## Feature 4: Instruction File Writer

Per-CLI instruction file with Scope.app managed section.

| CLI | File |
|-----|------|
| Claude | `CLAUDE.md` |
| Gemini | `GEMINI.md` |
| Codex | `AGENTS.md` |
| OpenCode | `INSTRUCTIONS.md` |

Same managed-section markers and content. Same merge logic as existing CLAUDE.md injector.
Each CLI's file is independent — setting up one doesn't touch another.

## Feature 5: TaskLauncherView Update

Single-line change: read `appSettings.preferredCLI.command` instead of hardcoding `"claude"`.

```swift
// Before:
let command = "claude \"\(escaped)\""
// After:
let command = "\(appSettings.preferredCLI.command) \"\(escaped)\""
```

## Files Changed

| File | Change |
|------|--------|
| **New:** `CLIProvider.swift` | Enum with all CLI metadata |
| **New:** `CLIQuickLaunchView.swift` | Quick-launch buttons + dropdown menus |
| **Modified:** `AppSettings.swift` | Add `preferredCLI` property |
| **Modified:** `SettingsView.swift` | Add preferred CLI picker |
| **Modified:** `ContextInjector.swift` | Per-CLI MCP config + instruction writers |
| **Modified:** `TaskLauncherView.swift` | Use preferred CLI command |
| **Modified:** `TerminalTabView.swift` | Host quick-launch buttons in tab bar |

## What Doesn't Change

- ScopeMCP binary (CLI-agnostic, standard MCP protocol)
- Database schema
- Browser automation IPC
- Existing MCP protocol behavior

## Key Design Decisions

1. **Preferred CLI is global, not per-project** — Simpler UX, matches "default browser" mental model
2. **MCP install is manual, not auto** — Avoids surprising users with config file changes
3. **Instruction files are per-CLI** — Each CLI has its own convention; one shared file would require all CLIs to support custom paths
4. **Merge, don't overwrite** — Config files may have other MCP servers; we only touch our entry
