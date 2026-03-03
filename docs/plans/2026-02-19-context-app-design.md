# Scope.app — Design Document

**Date:** 2026-02-19
**Status:** Approved
**Platform:** macOS (native Swift + SwiftUI)
**Minimum target:** macOS 14 (Sonoma)

---

## Problem Statement

Between Claude Code sessions, all context is lost. Session agents can't recall previous work, codebase structure drifts without documentation, and maintaining continuity requires constant manual effort — re-explaining patterns, reminding agents to use MCP tools, and re-establishing project state.

## Solution

A native macOS app with a split-view layout: a full terminal emulator on the left, and a context-management GUI on the right. The app reads Claude Code's session data, maintains a local SQLite database of project context, and serves that context back to future sessions via a built-in MCP server — on-demand, with minimal token cost.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Scope.app                       │
├──────────────────────┬──────────────────────────────┤
│                      │                              │
│   Terminal Panel     │      GUI Panel               │
│   (SwiftTerm PTY)    │      (SwiftUI Tabs)          │
│                      │                              │
│   Runs `claude`      │   ┌─ Dashboard (home)        │
│   or any shell cmd   │   ├─ Session Browser         │
│                      │   ├─ Task Board (kanban)     │
│   Directory-synced   │   ├─ Project Notes            │
│   to active project  │   └─ Memory Inspector         │
│                      │                              │
├──────────────────────┴──────────────────────────────┤
│                  Core Services                       │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────┐    │
│  │ Session   │ │ Codebase │ │ Claude Data      │    │
│  │ Watcher   │ │ Tracker  │ │ Reader           │    │
│  └──────────┘ └──────────┘ └──────────────────┘    │
│                      │                              │
│         ┌────────────┼─────────────┐                │
│         │            │             │                │
│    ┌────┴─────┐ ┌────┴────┐ ┌─────┴──────┐        │
│    │ SQLite   │ │  MCP    │ │  Context   │        │
│    │ Database │ │  Server │ │  Injector  │        │
│    └──────────┘ └─────────┘ └────────────┘        │
└─────────────────────────────────────────────────────┘
```

### Key Decisions

- **SwiftUI app lifecycle** with HSplitView for the left/right split
- **SwiftTerm** for the embedded terminal (MIT-licensed, production-ready)
- **GRDB.swift** for SQLite (migrations, Codable records, reactive observation)
- **FSEvents** for file system watching (session detection, codebase tracking)
- **Unix socket MCP server** for token-efficient context delivery
- Reads Claude Code data directly from `~/.claude/` — no API dependency

### Dependencies (2 total)

- **GRDB.swift** — SQLite wrapper
- **SwiftTerm** — terminal emulator

Everything else uses native Apple frameworks (SwiftUI, Foundation, Network/NIO).

---

## Data Model

Database location: `~/Library/Application Support/Context/context.db`

### projects
| Column | Type | Description |
|--------|------|-------------|
| id | TEXT PK | UUID |
| name | TEXT | Display name |
| path | TEXT UNIQUE | Absolute path to project root |
| claude_project | TEXT | ~/.claude/projects/<key> path |
| last_opened | DATETIME | |
| created_at | DATETIME | |

### sessions
| Column | Type | Description |
|--------|------|-------------|
| id | TEXT PK | Claude's session UUID |
| project_id | TEXT FK | → projects |
| slug | TEXT | Claude's slug name |
| started_at | DATETIME | |
| ended_at | DATETIME | |
| model | TEXT | Model used |
| git_branch | TEXT | |
| summary | TEXT | Auto-generated summary |
| message_count | INTEGER | |
| tool_use_count | INTEGER | |
| files_changed | TEXT | JSON array of file paths |

### codebase_snapshots
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PK | |
| project_id | TEXT FK | → projects |
| captured_at | DATETIME | |
| file_tree | TEXT | JSON directory structure |
| schema_hash | TEXT | Hash of schema files |
| key_symbols | TEXT | JSON of exports/classes/functions |

### notes
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PK | |
| project_id | TEXT FK | → projects |
| title | TEXT | |
| content | TEXT | Markdown |
| pinned | BOOLEAN | Default 0 |
| session_id | TEXT FK | Optional → sessions |
| created_at | DATETIME | |
| updated_at | DATETIME | |

### patterns
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PK | |
| project_id | TEXT FK | → projects |
| category | TEXT | architecture, naming, schema, workflow |
| title | TEXT | |
| description | TEXT | |
| source_session | TEXT FK | → sessions |
| auto_detected | BOOLEAN | Default 0 |
| created_at | DATETIME | |

### tasks
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PK | |
| project_id | TEXT FK | → projects |
| title | TEXT | |
| description | TEXT | |
| status | TEXT | todo, in_progress, done |
| priority | INTEGER | Default 0 |
| source_session | TEXT FK | → sessions |
| source | TEXT | "claude" or "manual" |
| created_at | DATETIME | |
| completed_at | DATETIME | |

---

## Data Flow

### Inbound (Claude Code → Scope.app)

1. **App launch** — Scans `~/.claude/history.jsonl` and `~/.claude/projects/` to discover projects and sessions
2. **Session watcher** — FSEvents watches `~/.claude/projects/<current-project>/` for new/modified `.jsonl` files. When a session ends (debounce 30s after last write), parses it into a snapshot.
3. **Codebase tracker** — FSEvents watches project root for structural changes. Takes periodic snapshots of file tree, schema files, and key symbols.
4. **Task sync** — Parses session JSONL for TaskCreate/TaskUpdate tool calls, syncs into tasks table.

### Outbound (Scope.app → Claude Code)

**Hybrid approach for token efficiency:**

#### 1. MCP Server (primary — on-demand)
Local MCP server on Unix socket, auto-configured in Claude Code settings.

Tools exposed:
- `get_recent_sessions(project, limit)` — recent session summaries
- `get_active_tasks(project)` — pending/in-progress tasks
- `get_patterns(project, category?)` — conventions and patterns
- `get_codebase_snapshot(project)` — current file tree and schema state
- `search_sessions(project, query)` — FTS5 search across session history
- `get_session_detail(session_id)` — full session transcript

Token cost: ~200 tokens for tool definitions in system prompt. Content fetched only when agent calls a tool.

#### 2. CLAUDE.md (minimal pointer — ~40 tokens)
Auto-managed section in project's CLAUDE.md:
```
# Context
This project uses Scope.app for session memory.
Use the `context` MCP tools to retrieve project history,
active tasks, patterns, and codebase structure when needed.
```

#### 3. Session-start hook (bare essentials — ~200 tokens)
Injects active tasks and last session summary at session start. Configurable per-project: tasks / recent sessions / both / none.

**Token budget:**
| Component | Tokens per message | Over 100 messages |
|-----------|-------------------|-------------------|
| MCP tool defs | ~200 | ~20,000 |
| CLAUDE.md pointer | ~40 | ~4,000 |
| Hook injection | ~200 (first msg only) | ~200 |
| On-demand calls | ~300 per call | Only when used |
| **Total baseline** | **~240** | **~24,200** |

vs. full CLAUDE.md dump: ~800/msg = ~80,000 over 100 messages.

---

## GUI Panel Views

### Dashboard (home)
- Current project name + path
- Recent sessions (last 5-10) with timestamps, message counts, summaries
- Active/pending task count
- Quick-launch: "New Claude Session", "Continue Last Session", "Open Project Folder"
- Project switcher dropdown

### Sessions
- Scrollable list of all sessions for current project
- Cards: date, slug, git branch, model, message count, files changed
- Click to view read-only transcript (parsed from JSONL)
- FTS5 search bar across session content
- "Resume" button → runs `claude --resume <id>` in terminal

### Tasks (kanban)
- Three columns: Todo | In Progress | Done
- Cards: title, source badge (claude/manual), linked session
- Drag and drop between columns
- Manual task creation via "+" button
- Auto-populated from Claude Code session JSONL

### Notes
- Note list sidebar + markdown editor pane
- Live markdown preview
- Pin important notes
- Optional session linking

### Memory (pattern inspector)
- Grouped by category: Architecture, Naming, Schema, Workflow
- Each entry: title, description, source session
- Manual add/edit/delete
- Toggle auto-detected vs manual entries

---

## Terminal Panel

### Implementation
- **SwiftTerm** TerminalView (NSView wrapped for SwiftUI)
- Real PTY with user's default shell (zsh)
- Full color, mouse support, scrollback (10,000 lines default)
- Inherits shell profile — `claude` command, PATH, aliases all work

### Directory Sync
- Project switch in GUI → `cd /path/to/project` sent to active terminal (queued if process running)
- New terminal tab → spawns in current project's path
- "Resume" / "New Session" buttons → `cd` first, then run command
- Terminal header shows current working directory in real-time

### Terminal Tabs
- Tab bar above terminal panel
- "+" button for new tabs (open in current project dir)
- Each tab is an independent PTY session

### Integration with GUI
- Auto-detects active Claude session in terminal
- Session end triggers snapshot parsing
- GUI buttons send commands to terminal PTY programmatically

---

## App Settings

### General
- Default project directory (~/Documents)
- Theme: System / Light / Dark
- Launch at login
- Open last project on launch

### Terminal
- Shell path (auto-detected)
- Font family and size
- Scrollback lines
- Tab cd-on-switch behavior

### Context Engine
- Auto-snapshot sessions (toggle)
- Auto-update codebase tree (toggle)
- Snapshot debounce time (30s default)
- MCP server auto-start (toggle)
- MCP server socket path
- CLAUDE.md injection (toggle)

### Per-Project
- CLAUDE.md managed section (toggle + preview)
- Session-start hook context (tasks / recent sessions / both / none)
- Watched schema files (auto-detected + manual)
- Ignored directories (node_modules, .git, build, dist)

---

## File Locations

```
~/Library/Application Support/Context/
  ├── context.db              # SQLite database
  ├── mcp.sock                # Unix socket for MCP server
  └── config.json             # App settings

<project-root>/
  └── CLAUDE.md               # Auto-managed section (minimal pointer)
```

---

## Project Structure

```
Context/
  ├── Context.xcodeproj
  ├── Context/
  │   ├── ContextApp.swift           # App entry point
  │   ├── Models/                    # GRDB record types
  │   │   ├── Project.swift
  │   │   ├── Session.swift
  │   │   ├── CodebaseSnapshot.swift
  │   │   ├── Note.swift
  │   │   ├── Pattern.swift
  │   │   └── Task.swift
  │   ├── Services/
  │   │   ├── DatabaseService.swift  # SQLite via GRDB
  │   │   ├── SessionParser.swift    # JSONL parsing
  │   │   ├── FileWatcher.swift      # FSEvents wrapper
  │   │   ├── MCPServer.swift        # Local MCP server
  │   │   └── ContextInjector.swift  # CLAUDE.md + hook management
  │   ├── Views/
  │   │   ├── MainSplitView.swift    # HSplitView container
  │   │   ├── TerminalPanel/
  │   │   │   ├── TerminalTabView.swift
  │   │   │   └── TerminalToolbar.swift
  │   │   ├── Dashboard/
  │   │   │   └── DashboardView.swift
  │   │   ├── Sessions/
  │   │   │   ├── SessionListView.swift
  │   │   │   └── SessionDetailView.swift
  │   │   ├── Tasks/
  │   │   │   ├── KanbanBoard.swift
  │   │   │   └── TaskCard.swift
  │   │   ├── Notes/
  │   │   │   ├── NoteListView.swift
  │   │   │   └── NoteEditorView.swift
  │   │   └── Memory/
  │   │       └── PatternListView.swift
  │   └── Terminal/
  │       └── TerminalWrapper.swift  # SwiftTerm integration
  └── Package.swift (or via SPM in Xcode)
      ├── GRDB.swift
      └── SwiftTerm
```

---

## Distribution

Direct `.app` bundle. Code-signed with Apple developer account for Gatekeeper. No App Store required — developer tool for personal use.
