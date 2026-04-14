# MCP Project/Group Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable full project/group management through the workspace MCP — assign projects to groups on creation, update project groups/tags after the fact, and allow "Global" as a task project target.

**Architecture:** All changes are in `Context/Sources/WorkspaceMCP/main.swift`. We add parameters to existing tool schemas, add a helper to resolve/create groups by name, add an `update_project` tool, modify `resolveProjectId` to accept "global", and enhance `listProjects` output. No DB migrations needed.

**Tech Stack:** Swift, GRDB (SQLite ORM), MCP protocol (JSON-RPC over stdin/stdout)

---

### Task 1: Add `resolveOrCreateClient` helper function

**Files:**
- Modify: `Context/Sources/WorkspaceMCP/main.swift:3108` (before `listClients`)

This helper does case-insensitive client lookup by name and auto-creates if not found. Both `createProject` and the new `updateProject` will use it.

- [ ] **Step 1: Add the helper function**

Insert before the `// MARK: - Client Handlers` line (line 3108):

```swift
    /// Looks up a client by name (case-insensitive). Creates one if not found.
    func resolveOrCreateClient(name: String, inDb db: Database) throws -> Client {
        if let existing = try Client.filter(Column("name").collating(.nocase) == name).fetchOne(db) {
            return existing
        }
        let count = try Client.fetchCount(db)
        var client = Client(
            id: UUID().uuidString,
            name: name,
            color: "#3B82F6",
            sortOrder: count,
            createdAt: Date()
        )
        try client.insert(db)
        return client
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && swift build --package-path Context 2>&1 | tail -5`
Expected: Build succeeds (the function is unused for now, but should compile)

- [ ] **Step 3: Commit**

```bash
git add Context/Sources/WorkspaceMCP/main.swift
git commit -m "feat(mcp): add resolveOrCreateClient helper for group lookup/creation"
```

---

### Task 2: Enhance `create_project` with `group_name` and `tags` params

**Files:**
- Modify: `Context/Sources/WorkspaceMCP/main.swift:1083-1093` (tool schema)
- Modify: `Context/Sources/WorkspaceMCP/main.swift:2204-2235` (implementation)

- [ ] **Step 1: Update the tool schema**

Replace the `create_project` tool schema (lines 1083-1093) with:

```swift
            [
                "name": "create_project",
                "description": "Register a new project in Workspace. Use when the current working directory is not tracked. Enables task tracking, notes, and context for the project. Optionally assign to a group and add tags.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Project name"],
                        "path": ["type": "string", "description": "Absolute path to the project root (defaults to current working directory)"],
                        "group_name": ["type": "string", "description": "Name of the group to assign this project to. Auto-creates the group if it doesn't exist."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Tags for the project (e.g. [\"mobile\", \"ios\"])"],
                    ],
                    "required": ["name"]
                ]
            ],
```

- [ ] **Step 2: Update the implementation**

Replace the `createProject` function (lines 2204-2235) with:

```swift
    func createProject(_ args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw MCPError(message: "name is required")
        }
        let rawPath = args["path"] as? String ?? ""
        let path = rawPath.isEmpty ? workingDirectory : rawPath
        let groupName = args["group_name"] as? String
        let tagsArr = args["tags"] as? [String]

        let projectId = UUID().uuidString
        let (project, wasExisting, clientName) = try db.write { db -> (Project, Bool, String?) in
            var resolvedClient: Client? = nil
            if let gn = groupName, !gn.isEmpty {
                resolvedClient = try resolveOrCreateClient(name: gn, inDb: db)
            }

            if var existing = try Project.filter(Column("path") == path).fetchOne(db) {
                // Update group/tags on existing project if provided
                if let client = resolvedClient {
                    existing.clientId = client.id
                }
                if let tags = tagsArr {
                    existing.setTags(tags)
                }
                if resolvedClient != nil || tagsArr != nil {
                    try existing.update(db)
                }
                return (existing, true, resolvedClient?.name)
            }

            var tagJson: String? = nil
            if let tags = tagsArr, !tags.isEmpty,
               let data = try? JSONEncoder().encode(tags),
               let str = String(data: data, encoding: .utf8) {
                tagJson = str
            }

            try db.execute(
                sql: "INSERT INTO projects (id, name, path, clientId, tags, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [projectId, name, path, resolvedClient?.id, tagJson, Date()]
            )
            guard let created = try Project.filter(Column("id") == projectId).fetchOne(db) else {
                throw MCPError(message: "Failed to create project")
            }
            return (created, false, resolvedClient?.name)
        }

        detectedProjectId = project.id
        detectedProjectName = project.name

        var extras: [String] = []
        if let cn = clientName { extras.append("group: \(cn)") }
        if let tags = tagsArr, !tags.isEmpty { extras.append("tags: \(tags.joined(separator: ", "))") }
        let suffix = extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))"

        if wasExisting {
            return "Project already exists: [\(project.id)] \(project.name) — \(project.path)\(suffix)\nNow using this project for the session."
        } else {
            return "Created project: [\(project.id)] \(project.name) — \(project.path)\(suffix)\nNow using this project for the session."
        }
    }
```

- [ ] **Step 3: Verify it compiles**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && swift build --package-path Context 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Context/Sources/WorkspaceMCP/main.swift
git commit -m "feat(mcp): add group_name and tags params to create_project"
```

---

### Task 3: Add `update_project` tool

**Files:**
- Modify: `Context/Sources/WorkspaceMCP/main.swift:1093` (add tool schema after `create_project`)
- Modify: `Context/Sources/WorkspaceMCP/main.swift:1941` (add dispatch case)
- Modify: `Context/Sources/WorkspaceMCP/main.swift` (add implementation after `createProject`)

- [ ] **Step 1: Add the tool schema**

Insert after the `create_project` tool schema block (after the closing `],` at line ~1093):

```swift
            [
                "name": "update_project",
                "description": "Update a project's group or tags. Use to organize projects in the sidebar.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID to update"],
                        "group_name": ["type": "string", "description": "Group name to assign to. Empty string removes from group. Auto-creates group if needed."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Replace project tags (e.g. [\"mobile\", \"ios\"])"],
                    ],
                    "required": ["project_id"]
                ]
            ],
```

- [ ] **Step 2: Add the dispatch case**

In the tool dispatch switch statement, after the `case "create_project"` line (around line 1941), add:

```swift
            case "update_project":  result = try updateProject(args)
```

- [ ] **Step 3: Add the implementation**

Insert after the `createProject` function:

```swift
    func updateProject(_ args: [String: Any]) throws -> String {
        guard let projectId = args["project_id"] as? String, !projectId.isEmpty else {
            throw MCPError(message: "project_id is required")
        }
        let groupName = args["group_name"] as? String
        let tagsArr = args["tags"] as? [String]

        if groupName == nil && tagsArr == nil {
            throw MCPError(message: "At least one of group_name or tags must be provided")
        }

        let (project, clientName) = try db.write { db -> (Project, String?) in
            guard var project = try Project.filter(Column("id") == projectId).fetchOne(db) else {
                throw MCPError(message: "Project not found: \(projectId)")
            }

            var resolvedClientName: String? = nil

            if let gn = groupName {
                if gn.isEmpty {
                    project.clientId = nil
                } else {
                    let client = try resolveOrCreateClient(name: gn, inDb: db)
                    project.clientId = client.id
                    resolvedClientName = client.name
                }
            }

            if let tags = tagsArr {
                project.setTags(tags)
            }

            try project.update(db)
            return (project, resolvedClientName)
        }

        var parts: [String] = ["Updated project: [\(project.id)] \(project.name)"]
        if let cn = clientName {
            parts.append("Group: \(cn)")
        } else if groupName == "" {
            parts.append("Removed from group")
        }
        if let tags = tagsArr {
            parts.append("Tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && swift build --package-path Context 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Context/Sources/WorkspaceMCP/main.swift
git commit -m "feat(mcp): add update_project tool for group/tag management"
```

---

### Task 4: Modify `resolveProjectId` to accept "global"

**Files:**
- Modify: `Context/Sources/WorkspaceMCP/main.swift:700-708` (`resolveProjectId`)

- [ ] **Step 1: Update `resolveProjectId`**

Replace the function (lines 700-708) with:

```swift
    func resolveProjectId(_ args: [String: Any]) throws -> String {
        if let explicit = args["project_id"] as? String {
            // Normalize "global" shorthand to the sentinel ID
            if explicit.lowercased() == "global" || explicit == "__global__" {
                return "__global__"
            }
            return explicit
        }
        guard let detected = detectedProjectId else {
            throw MCPError(message: "project_id is required (could not auto-detect from working directory)")
        }
        return detected
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && swift build --package-path Context 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Context/Sources/WorkspaceMCP/main.swift
git commit -m "feat(mcp): accept 'global' as project_id for non-repo tasks"
```

---

### Task 5: Enhance `listProjects` to show group, tags, and Global

**Files:**
- Modify: `Context/Sources/WorkspaceMCP/main.swift:2193-2202` (`listProjects`)

- [ ] **Step 1: Update the implementation**

Replace the `listProjects` function (lines 2193-2202) with:

```swift
    func listProjects() throws -> String {
        let (projects, clients) = try db.read { db in
            let projects = try Project.fetchAll(db)
            let clients = try Client.fetchAll(db)
            return (projects, clients)
        }
        let clientMap = Dictionary(uniqueKeysWithValues: clients.map { ($0.id, $0.name) })

        var lines = ["Projects (\(projects.count)):"]
        // Show Global first
        lines.append("  [__global__] Global (for tasks not tied to a specific project)")

        for p in projects where p.id != "__global__" {
            var info = "  [\(p.id)] \(p.name) — \(p.path)"
            if let cid = p.clientId, let cname = clientMap[cid] {
                info += " (group: \(cname))"
            }
            let tags = p.tagsArray
            if !tags.isEmpty {
                info += " [\(tags.joined(separator: ", "))]"
            }
            lines.append(info)
        }
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && swift build --package-path Context 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Context/Sources/WorkspaceMCP/main.swift
git commit -m "feat(mcp): show group, tags, and Global in list_projects output"
```

---

### Task 6: Build and verify end-to-end

**Files:** None (verification only)

- [ ] **Step 1: Full build**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && swift build --package-path Context 2>&1 | tail -10`
Expected: Build succeeds with no errors

- [ ] **Step 2: Verify tool schema count**

Run: `cd "/Users/connor/Downloads/Personal Dev/scope" && grep -c '"name":' Context/Sources/WorkspaceMCP/main.swift`
Expected: Count is one more than before (the new `update_project` tool)

- [ ] **Step 3: Final commit (if any fixups needed)**

```bash
git add Context/Sources/WorkspaceMCP/main.swift
git commit -m "fix(mcp): address build issues from project/group management feature"
```

Only run this if Step 1 or 2 required fixes.
