# Workspace

**Persistent memory for AI coding agents**
A native macOS companion for Claude Code, Gemini CLI, Codex CLI, and OpenCode

[![Download](https://img.shields.io/badge/download-macOS-orange?style=flat-square)](https://github.com/ctab30/scope/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

---

Your AI coding agent forgets everything between sessions. Workspace fixes that.

It auto-discovers your projects, tracks tasks across sessions, monitors live coding activity, and exposes everything back to your AI via MCP — so your agent always knows what you're working on and can pick up where it left off.

## Features

### Project Dashboard
Auto-discovers all your Claude Code projects from `~/.claude/projects/`. Each project opens in its own window with an integrated terminal and tabbed workspace. The home view shows a global planner with tasks aggregated across all projects. Organize projects into client groups with custom colors.

### Task Tracking
Drag-and-drop Kanban board (Todo / In Progress / Done) per project and globally. Tasks can be created manually, extracted from emails, or created programmatically by your AI agent through the MCP server. Priority levels, labels, file attachments, notes, and full task history. Tasks auto-transition to "needs attention" when an agent session ends with work still in progress.

### Git & GitHub
Full git integration with staging, unstaging, inline diffs, commit, push, and pull. Create branches directly from the branch dropdown. Generate AI-powered commit messages using Claude Code CLI — one click analyzes your staged changes and writes the message for you. See open PRs, CI/workflow status, and issues without leaving the app.

### Built-in Terminal
Tabbed terminal emulator (SwiftTerm) embedded in each project window. Launch Claude Code sessions in multiple modes — new, resume, continue, dangermode, or verbose — from a quick-launch menu. Run commands and manage multiple tabs side by side with the GUI panel.

### Live Session Monitoring
Real-time mission control for active Claude Code sessions. Watches session JSONL files and displays token usage, cost tracking, tools invoked, files touched, and a live activity feed. MCP connection indicator shows when your agent is actively connected.

### Session History
Parses and indexes all past Claude Code sessions. Browse conversations, review tool usage patterns, and track costs over time.

### Built-in Browser
Integrated browser with developer tools: network request monitoring, console log viewer, screenshot capture with annotation, and issue creation from browser context. Manage multiple tabs without leaving the app.

### Notes
Per-project and global notes with a rich editor. Pin important notes, search across all notes, and use them to persist context your agent can reference in future sessions.

### Task Launcher
One-click actions for common workflows: code review, debugging, writing tests, refactoring, documentation, and security audits. Detects your project's package manager and provides quick-launch buttons for dev, build, test, and lint commands.

### AI Features
Chat with Claude using full project context. Semantic code search across your codebase. Image generation studio with configurable prompts, aspect ratios, and sizes. All AI features powered through OpenRouter with a single API key.

## MCP Server

Workspace includes a companion MCP server (`WorkspaceMCP`) that exposes your project data to any AI coding tool. When configured, your agent can:

- Read project context (tech stack, file structure, recent git activity)
- Create and manage tasks (status updates, notes, file attachments, plans)
- Read and search project notes
- Query session history
- Navigate and interact with web pages via the built-in browser
- Generate images

This creates a feedback loop: you manage work in Workspace, and your AI has full awareness of that work during every coding session.

## Getting Started

### 1. Download

Grab `Workspace.app` from [GitHub Releases](https://github.com/ctab30/scope/releases/latest) and drag it to your Applications folder.

### 2. Connect your CLI

The app includes a guided setup wizard, or you can configure manually:

<details>
<summary><strong>Claude Code</strong></summary>

```bash
claude mcp add workspace ~/Library/Application\ Support/Workspace/bin/WorkspaceMCP
```
</details>

<details>
<summary><strong>Gemini CLI</strong></summary>

```json
// ~/.gemini/settings.json
{
  "mcpServers": {
    "workspace": {
      "command": "~/Library/Application Support/Workspace/bin/WorkspaceMCP",
      "args": []
    }
  }
}
```
</details>

<details>
<summary><strong>Codex CLI</strong></summary>

```toml
# ~/.codex/config.toml
[mcp_servers.workspace]
command = "~/Library/Application Support/Workspace/bin/WorkspaceMCP"
args = []
```
</details>

<details>
<summary><strong>OpenCode</strong></summary>

```json
// ~/.opencode/config.json
{
  "mcpServers": {
    "workspace": {
      "command": "~/Library/Application Support/Workspace/bin/WorkspaceMCP",
      "args": []
    }
  }
}
```
</details>

### 3. Configure

Open **Settings** (`Cmd + ,`) and paste your [OpenRouter API key](https://openrouter.ai/keys).

This powers the built-in AI chat, semantic code search, and image generation. All models are served through OpenRouter with a single key.

<details>
<summary>Optional: Gmail integration</summary>

To enable email-to-task sync, go to **Settings** and enter your Google OAuth credentials (Client ID + Client Secret).

Get these from [Google Cloud Console](https://console.cloud.google.com/apis/credentials).
</details>

### 4. Code

Your AI agent now has persistent memory, task tracking, and project intelligence — across every session.

## Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), [Codex CLI](https://github.com/openai/codex), or [OpenCode](https://github.com/sst/opencode)
- [GitHub CLI](https://cli.github.com/) (`gh`) for GitHub integration (optional)

## Building from Source

```bash
git clone https://github.com/ctab30/scope.git
cd scope
bash scripts/package-app.sh
cp -r build/Workspace.app /Applications/
```

## Architecture

Pure Swift Package Manager project with two executable targets:

| Target | Description |
|--------|-------------|
| `Workspace` | Main GUI app — SwiftUI + AppKit, no Xcode project needed |
| `WorkspaceMCP` | Standalone MCP server binary, communicates via stdio |

### Dependencies

| Package | Purpose |
|---------|---------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite database (shared between app and MCP server) |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator |

No Electron. No web views (except the built-in browser). No node_modules. The entire app is ~16MB.

### Data Storage

All data lives in `~/Library/Application Support/Workspace/workspace.db` — a single SQLite database shared by both the GUI app and the MCP server.

## License

MIT
