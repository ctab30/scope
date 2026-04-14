# MCP Project/Group Management & Global Tasks

**Date:** 2026-04-14
**Status:** Approved

## Problem

The workspace MCP server can create projects and clients (groups), but cannot:
- Assign a project to a group on creation or after the fact
- Set tags on projects
- Create tasks under "Global" for work not tied to a specific repo
- Show group/tag info when listing projects

This forces users to the GUI for project organization, breaking the CLI-first workflow.

## Design

### 1. `create_project` — Add `group_name` and `tags` params

**File:** `Context/Sources/WorkspaceMCP/main.swift`

**New optional parameters:**
- `group_name` (string) — Name of the group to assign the project to. If a group with that name doesn't exist, auto-create it with a default color. Case-insensitive lookup.
- `tags` (string array) — e.g. `["mobile", "ios"]`. Stored as JSON in the existing `tags` column.

**Behavior:**
1. Existing path-based dedup and project creation logic unchanged
2. If `group_name` provided, look up client by name (case-insensitive)
3. If not found, create new client with that name + default color (`#3B82F6`)
4. Set `clientId` on the project (new or existing) to the matched/created client
5. If `tags` provided, store as JSON in the `tags` column
6. Response includes group name and tags

**No DB migration needed** — `clientId` and `tags` columns already exist on the projects table.

### 2. New `update_project` tool

**Parameters:**
- `project_id` (required string) — the project to update
- `group_name` (optional string) — assign to group (auto-creates if needed). Empty string removes from group.
- `tags` (optional string array) — replaces existing tags

**Behavior:**
1. Look up project by ID, error if not found
2. If `group_name` is empty string, set `clientId = NULL`
3. If `group_name` is non-empty, resolve/create client (same logic as `create_project`)
4. If `tags` provided, serialize to JSON and update
5. Return updated project info with group name

### 3. Global in task creation

**Current:** `create_task` requires `project_id` via auto-detection or explicit param. The `__global__` sentinel project exists but is hidden.

**Changes:**
- Accept `project_id: "global"` or `project_id: "__global__"` as valid explicit values in `create_task` (and other project-scoped tools)
- Normalize `"global"` to `"__global__"` in `resolveProjectId`
- `list_projects` includes a "Global" entry so callers know it's available

**No change to auto-detection** — being in a repo still defaults to that project. Global is opt-in only via explicit `project_id`.

### 4. `list_projects` enhancement

**Current output:**
```
Projects (3):
  [uuid1] MyApp — /path/to/myapp
  [uuid2] Backend — /path/to/backend
```

**New output:**
```
Projects (4):
  [__global__] Global (for tasks not tied to a specific project)
  [uuid1] MyApp — /path/to/myapp (group: Mobile Apps) [ios, mobile]
  [uuid2] Backend — /path/to/backend (group: Backend Services)
  [uuid3] Website — /path/to/website
```

## Scope

All changes are in `Context/Sources/WorkspaceMCP/main.swift`:
- Modify `create_project` tool schema + implementation
- Add `update_project` tool schema + implementation
- Modify `resolveProjectId` to accept `"global"`
- Modify `list_projects` to include group/tag info and Global entry

No database migrations. No GUI changes. No changes to the Swift Workspace app.

## Typical User Flow

1. User in Claude Code session: "Add this BB repo under Mobile Apps"
2. Claude asks where to clone it
3. User says `~/Downloads`
4. Claude runs `git clone <url> ~/Downloads/repo-name`
5. Claude calls `create_project(name: "Repo Name", path: "~/Downloads/repo-name", group_name: "Mobile Apps")`
6. MCP creates "Mobile Apps" group if needed, creates project, assigns to group
7. Project appears in GUI sidebar under "Mobile Apps"
