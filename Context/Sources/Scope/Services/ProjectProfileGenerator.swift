import Foundation
import GRDB

/// Generates a text profile of a project by composing output from
/// `ProjectAnalyzer` (file tree, architecture, schema, git) and
/// project type detection. The profile is stored in the `codebaseSnapshots`
/// table and cached in memory for fast access by ContextAssembler and MCP.
struct ProjectProfileGenerator {

    /// Generate a full project profile and persist it as a CodebaseSnapshot.
    /// Runs all scanners off the main thread, then returns the rendered text.
    static func generate(projectId: String, projectPath: String) async -> String {
        let profile = await Task.detached {
            buildProfile(projectPath: projectPath)
        }.value

        // Upsert into codebaseSnapshots
        var snapshot = CodebaseSnapshot(
            projectId: projectId,
            capturedAt: Date(),
            profileText: profile
        )

        // Also store the file tree as JSON for MCP backward compat
        let fileNodes = ProjectAnalyzer.performFileTreeScan(at: projectPath)
        let fileTreeJSON = fileNodes.map { $0.id }
        if let data = try? JSONSerialization.data(withJSONObject: fileTreeJSON),
           let jsonStr = String(data: data, encoding: .utf8) {
            snapshot.fileTree = jsonStr
        }

        do {
            try await DatabaseService.shared.dbQueue.write { db in
                // Delete previous snapshots for this project (keep only latest)
                try CodebaseSnapshot
                    .filter(Column("projectId") == projectId)
                    .deleteAll(db)
                try snapshot.insert(db)
            }
        } catch {
            print("ProjectProfileGenerator: failed to save snapshot: \(error)")
        }

        return profile
    }

    /// Load the most recent cached profile from the database.
    static func loadCached(projectId: String) -> String? {
        try? DatabaseService.shared.dbQueue.read { db in
            try CodebaseSnapshot
                .filter(Column("projectId") == projectId)
                .order(Column("capturedAt").desc)
                .fetchOne(db)?
                .profileText
        }
    }

    // MARK: - Profile Builder

    private nonisolated static func buildProfile(projectPath: String) -> String {
        let projectName = (projectPath as NSString).lastPathComponent
        let projectType = detectProjectType(at: projectPath)

        // Run scanners
        let fileNodes = ProjectAnalyzer.performFileTreeScan(at: projectPath)
        let archResult = ProjectAnalyzer.performArchScan(at: projectPath)
        let schemaTables = ProjectAnalyzer.performSchemaScan(at: projectPath)
        let gitCommits = ProjectAnalyzer.performGitHistoryScan(at: projectPath)

        var sections: [String] = []

        // Header
        sections.append("""
        PROJECT PROFILE: \(projectName)
        Type: \(projectType)
        Path: \(projectPath)
        """)

        // File structure
        if !fileNodes.isEmpty {
            sections.append(renderFileTree(fileNodes))
        }

        // Architecture / dependencies
        if !archResult.nodes.isEmpty {
            sections.append(renderArchitecture(archResult.nodes))
        }

        // Schema
        if !schemaTables.isEmpty {
            sections.append(renderSchema(schemaTables))
        }

        // Git activity
        if !gitCommits.isEmpty {
            sections.append(renderGitActivity(gitCommits))
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Renderers

    private nonisolated static func renderFileTree(_ nodes: [FileNode]) -> String {
        // Group files by directory
        var dirs: [String: [FileNode]] = [:]
        for node in nodes {
            let dir = (node.id as NSString).deletingLastPathComponent
            let key = dir.isEmpty ? "." : dir
            dirs[key, default: []].append(node)
        }

        var lines = ["FILE STRUCTURE (\(nodes.count) files):"]
        let sortedDirs = dirs.keys.sorted()

        for dir in sortedDirs.prefix(40) {
            let files = dirs[dir]!
            let totalLines = files.reduce(0) { $0 + $1.lineCount }
            let exts = Set(files.map { $0.fileType }).sorted().joined(separator: ", ")
            lines.append("  \(dir)/ (\(files.count) files, \(totalLines) lines) [\(exts)]")
        }

        if sortedDirs.count > 40 {
            lines.append("  ... and \(sortedDirs.count - 40) more directories")
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func renderArchitecture(_ nodes: [ArchNode]) -> String {
        // Collect all imports across the project
        var importCounts: [String: Int] = [:]
        for node in nodes {
            for imp in node.imports {
                // Only count external-looking imports (not relative paths)
                if !imp.contains("/") || imp.hasPrefix("@") {
                    importCounts[imp, default: 0] += 1
                }
            }
        }

        // Also count by directory for module-level view
        var dirCounts: [String: Int] = [:]
        for node in nodes {
            let dir = node.directory
            dirCounts[dir, default: 0] += 1
        }

        var lines = ["ARCHITECTURE:"]

        // Top imports/dependencies
        let topImports = importCounts
            .sorted { $0.value > $1.value }
            .prefix(15)
        if !topImports.isEmpty {
            lines.append("  Key dependencies:")
            for (name, count) in topImports {
                lines.append("    - \(name) (used in \(count) files)")
            }
        }

        // Module breakdown
        let topDirs = dirCounts
            .sorted { $0.value > $1.value }
            .prefix(15)
        if !topDirs.isEmpty {
            lines.append("  Modules:")
            for (dir, count) in topDirs {
                lines.append("    - \(dir): \(count) source files")
            }
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func renderSchema(_ tables: [SchemaTable]) -> String {
        var lines = ["DATABASE SCHEMA (\(tables.count) tables):"]
        for table in tables.prefix(20) {
            let cols = table.columns.map { col in
                var desc = col.name
                if col.isPrimaryKey { desc += " (PK)" }
                if col.isForeignKey, let ref = col.references { desc += " -> \(ref)" }
                return desc
            }
            lines.append("  \(table.name): \(cols.joined(separator: ", "))")
        }
        if tables.count > 20 {
            lines.append("  ... and \(tables.count - 20) more tables")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func renderGitActivity(_ commits: [GitCommit]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"

        var lines = ["RECENT GIT ACTIVITY:"]
        for commit in commits.prefix(10) {
            let date = formatter.string(from: commit.date)
            let msg = String(commit.message.prefix(80))
            lines.append("  - \(date): \(msg) (\(commit.author))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Project Type Detection

    private nonisolated static func detectProjectType(at path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/pubspec.yaml") { return "Flutter / Dart" }
        if fm.fileExists(atPath: "\(path)/Package.swift") { return "Swift (SPM)" }
        if fm.fileExists(atPath: "\(path)/package.json") {
            // Check for framework markers
            if fm.fileExists(atPath: "\(path)/next.config.js") ||
               fm.fileExists(atPath: "\(path)/next.config.mjs") ||
               fm.fileExists(atPath: "\(path)/next.config.ts") { return "Next.js" }
            if fm.fileExists(atPath: "\(path)/nuxt.config.ts") { return "Nuxt" }
            if fm.fileExists(atPath: "\(path)/angular.json") { return "Angular" }
            return "Node.js / TypeScript"
        }
        if fm.fileExists(atPath: "\(path)/requirements.txt") ||
           fm.fileExists(atPath: "\(path)/pyproject.toml") { return "Python" }
        if fm.fileExists(atPath: "\(path)/Cargo.toml") { return "Rust" }
        if fm.fileExists(atPath: "\(path)/go.mod") { return "Go" }
        return "Unknown"
    }
}
