# Dev Cockpit: Project Tags, Sidebar Navigation & Global Planner

## Goal

Transform Context from a project-scoped tool into an all-in-one dev cockpit. Add client-based project grouping, a persistent sidebar for navigation, and a global planner (kanban + notes) for cross-project day-to-day work management.

## Architecture

Three changes: (1) new data model for clients and project tags, (2) three-pane layout with project sidebar, (3) global planner home view.

## Data Model

### New `clients` table

| Column    | Type     | Notes                          |
|-----------|----------|--------------------------------|
| id        | TEXT PK  | UUID string                    |
| name      | TEXT     | "Acme Corp", "Personal", etc.  |
| color     | TEXT     | Hex color for sidebar accents  |
| sortOrder | INTEGER  | Manual ordering                |
| createdAt | DATETIME |                                |

### Migration: `projects` table

Add columns:
- `clientId TEXT` — FK to `clients`, nullable (ungrouped projects)
- `tags TEXT` — JSON array of free-form strings, e.g. `["react","staging"]`
- `sortOrder INTEGER DEFAULT 0` — ordering within client group

### Migration: `taskItems` table

Add column:
- `isGlobal BOOLEAN DEFAULT false` — global tasks show on home planner

Global tasks can still have a `projectId` (optional link). When `isGlobal = true`, the task appears on the home kanban. When it also has a `projectId`, a project badge is shown on the card.

### Migration: `notes` table

Add column:
- `isGlobal BOOLEAN DEFAULT false` — same pattern as tasks

## Layout

### Current (two-pane)

```
┌────────────────────┬──────────────────────────┐
│   Terminal Tabs    │ Project Header + Picker   │
│                    │ Tab Bar                   │
│                    │ Tab Content               │
└────────────────────┴──────────────────────────┘
```

### New (three-pane)

```
┌──────────────┬──────────────────────┬──────────────────────────┐
│   Project    │                      │                          │
│   Sidebar    │   Terminal           │  Home View (global       │
│   (~200px)   │   Tabs               │  kanban + notes)         │
│              │                      │         — or —           │
│   ┌ Home     │                      │  Project View (existing  │
│   ├ Acme     │                      │  tabs: tasks, dashboard, │
│   │ ├ proj-1 │                      │  sessions, notes, etc.)  │
│   │ └ proj-2 │                      │                          │
│   ├ Personal │                      │                          │
│   │ └ proj-3 │                      │                          │
│   └ Ungrouped│                      │                          │
│     └ proj-4 │                      │                          │
└──────────────┴──────────────────────┴──────────────────────────┘
```

`MainSplitView` changes from `HSplitView { Terminal | GUI }` to `HSplitView { Sidebar | Terminal | GUI }`.

## Project Sidebar (`ProjectSidebarView`)

- **Home item** at top — icon + "Planner". Sets `appState.isHomeView = true`.
- **Client groups** — collapsible `DisclosureGroup` sections. Client name header with colored accent dot. Projects nested underneath, sorted by `sortOrder`.
- **"Ungrouped" section** — projects with `clientId = nil`. Shown at bottom.
- **Selected state** — highlight for Home or active project.
- **Context menus:**
  - Projects: "Set Client...", "Edit Tags...", "Open in Finder"
  - Clients: "Rename", "Change Color", "Delete"
- **Add Client button** at bottom of sidebar.
- Fixed width ~200px.

## AppState Changes

```swift
@Published var isHomeView: Bool = true  // starts on home
@Published var currentProject: Project?

// Selecting Home:
func selectHome() {
    isHomeView = true
    currentProject = nil
}

// Selecting a project:
func selectProject(_ project: Project) {
    isHomeView = false
    currentProject = project
    // ... existing logic
}
```

## GUIPanelView Changes

- Remove the `Menu` dropdown project picker (sidebar replaces it).
- Keep project name/path display and MCP indicator in header.
- When `isHomeView = true`: show `HomeView` instead of tabbed content.
- When `isHomeView = false`: show existing tab bar + content (unchanged).

## Home View (Global Planner)

Vertical split showing:

1. **Global Kanban** — reuses `KanbanBoard` component, filtered to `isGlobal = true`. Task cards linked to a project show a small clickable project badge.
2. **Global Notes** — reuses `NoteListView`, filtered to `isGlobal = true`.

No tab bar on home view. Header shows "Planner" with a planner icon.

## MCP Server Changes

- `create_task` and `create_note`: add optional `global: true` parameter.
- `list_tasks` and `list_notes`: add optional `global: true` filter.
- Global tasks/notes still support optional `project_id` for linking.
- New tools: `list_clients`, `create_client`.

## Migration Strategy

All changes are additive (new table + new columns with defaults). No destructive migrations needed. Existing data is unaffected — all current tasks/notes have `isGlobal = false` by default, all projects have `clientId = nil` (show in "Ungrouped").
