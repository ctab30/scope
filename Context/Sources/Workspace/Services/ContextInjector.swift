import Foundation

// MARK: - Context Injector

/// Manages the integration surface between Workspace and Claude Code.
/// Handles two responsibilities:
/// 1. Injecting/removing a managed section in a project's CLAUDE.md file
/// 2. Writing an MCP configuration file that Claude Code can reference
class ContextInjector {

    enum InjectorError: Error, LocalizedError {
        case projectPathMissing
        case fileOperationFailed(String)

        var errorDescription: String? {
            switch self {
            case .projectPathMissing: return "Project path is empty"
            case .fileOperationFailed(let msg): return "File operation failed: \(msg)"
            }
        }
    }

    /// Markers used to identify the Workspace-managed section in CLAUDE.md
    static let sectionStart = "<!-- Workspace managed section -->"
    static let sectionEnd = "<!-- End Workspace section -->"

    // Old markers for migration — find and replace existing sections from pre-rename installs
    private static let legacySectionStart = "<!-- Scope managed section -->"
    private static let legacySectionEnd = "<!-- End Scope section -->"

    /// The content injected between the markers
    private static let managedContent = """
    # Workspace Task Tracking
    Use `mcp__workspace__` tools for task management. Do NOT use TodoWrite.

    ## Session start
    `mcp__workspace__get_project_context` — see open tasks and project state.
    If tasks are `in_progress`, resume them with `mcp__workspace__get_task`.

    ## Workflow
    - **Start work**: `mcp__workspace__create_task` with `status: "in_progress"` (one call to create + start). Title is required; description, priority, labels are optional. Duplicate detection is automatic.
    - **Log progress**: `mcp__workspace__add_task_note` for key decisions or progress.
    - **Finish**: `mcp__workspace__complete_task` with a summary of what was done.
    - **Notes**: `mcp__workspace__create_note` to save project knowledge.

    For quick questions or read-only tasks, creating a task is optional.
    """

    private let db: DatabaseService
    private let fileManager: FileManager

    init(db: DatabaseService = .shared, fileManager: FileManager = .default) {
        self.db = db
        self.fileManager = fileManager
    }

    // MARK: - CLAUDE.md Management

    /// Add or update the Workspace managed section in the project's CLAUDE.md.
    /// If CLAUDE.md exists, the managed section is found and replaced (or appended).
    /// If CLAUDE.md does not exist, a new file is created with just the managed section.
    func updateClaudeMD(for project: Project) throws {
        let projectPath = project.path
        guard !projectPath.isEmpty else {
            throw InjectorError.projectPathMissing
        }

        let claudeMDPath = (projectPath as NSString).appendingPathComponent("CLAUDE.md")
        let section = buildManagedSection()

        if fileManager.fileExists(atPath: claudeMDPath) {
            var content = try String(contentsOfFile: claudeMDPath, encoding: .utf8)

            if let range = findManagedSectionRange(in: content) {
                // Replace existing section
                content.replaceSubrange(range, with: section)
            } else {
                // Append section
                if !content.hasSuffix("\n") {
                    content += "\n"
                }
                content += "\n" + section + "\n"
            }

            try content.write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
        } else {
            // Create new CLAUDE.md with just the managed section
            let content = section + "\n"
            try content.write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
        }
    }

    /// Remove the Workspace managed section from the project's CLAUDE.md.
    /// If the file becomes empty (or whitespace-only) after removal, delete it.
    func removeClaudeMDSection(for project: Project) throws {
        let projectPath = project.path
        guard !projectPath.isEmpty else {
            throw InjectorError.projectPathMissing
        }

        let claudeMDPath = (projectPath as NSString).appendingPathComponent("CLAUDE.md")

        guard fileManager.fileExists(atPath: claudeMDPath) else {
            return // Nothing to remove
        }

        var content = try String(contentsOfFile: claudeMDPath, encoding: .utf8)

        guard let range = findManagedSectionRange(in: content) else {
            return // Section not found, nothing to do
        }

        content.removeSubrange(range)

        // Clean up extra newlines left behind
        content = content
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if content.isEmpty {
            try fileManager.removeItem(atPath: claudeMDPath)
        } else {
            try (content + "\n").write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - MCP Configuration

    /// Write the MCP configuration file that Claude Code can reference.
    /// Creates ~/Library/Application Support/Workspace/mcp-config.json
    ///
    /// Note: The transport bridge (connecting this config to the in-process MCPServer)
    /// is a future enhancement. For now this writes the structural config.
    func configureMCPConnection() throws {
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Workspace", isDirectory: true)

        try fileManager.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )

        let configPath = appSupportURL.appendingPathComponent("mcp-config.json")

        let config: [String: Any] = [
            "mcpServers": [
                "workspace": [
                    "command": "workspace-mcp-bridge",
                    "args": [] as [String],
                    "description": "Workspace - Session memory and project intelligence for Claude Code"
                ]
            ]
        ]

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configPath, options: .atomic)
    }

    // MARK: - Per-CLI MCP Installation

    /// The deployed WorkspaceMCP binary path.
    static var mcpBinaryPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Workspace/bin/WorkspaceMCP")
            .path
    }

    /// Install MCP config for Claude Code.
    /// Merge-safe: parses existing config and only adds/updates the workspace entry.
    /// Returns the path where the config was written.
    func installMCP(for cli: CLIProvider, projectPath: String) throws -> String {
        let binaryPath = Self.mcpBinaryPath
        guard fileManager.fileExists(atPath: binaryPath) else {
            throw InjectorError.fileOperationFailed("WorkspaceMCP binary not found at \(binaryPath)")
        }

        let configPath: String
        switch cli.mcpConfigScope {
        case .projectRoot(let filename):
            guard !projectPath.isEmpty else { throw InjectorError.projectPathMissing }
            configPath = (projectPath as NSString).appendingPathComponent(filename)
        case .userHome(let relativePath):
            configPath = (NSHomeDirectory() as NSString).appendingPathComponent(relativePath)
        }

        // Ensure parent directory exists
        let dir = (configPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config = readJSONDict(at: configPath)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["workspace"] = ["command": binaryPath]
        config["mcpServers"] = servers
        try writeJSON(config, to: configPath)

        return configPath
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

    // MARK: - Per-CLI Instruction File Management

    /// Write the Workspace managed section to the appropriate instruction file for this CLI.
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

    // MARK: - Helpers

    /// Build the full managed section string including markers.
    private func buildManagedSection() -> String {
        return [
            Self.sectionStart,
            Self.managedContent,
            Self.sectionEnd
        ].joined(separator: "\n")
    }

    /// Find the range of the managed section (including markers) within a string.
    /// Searches for both current and legacy markers so upgrades replace rather than duplicate.
    private func findManagedSectionRange(in content: String) -> Range<String.Index>? {
        // Try current markers first
        if let startRange = content.range(of: Self.sectionStart),
           let endRange = content.range(of: Self.sectionEnd),
           startRange.lowerBound < endRange.lowerBound {
            return startRange.lowerBound ..< endRange.upperBound
        }
        // Fall back to legacy markers
        if let startRange = content.range(of: Self.legacySectionStart),
           let endRange = content.range(of: Self.legacySectionEnd),
           startRange.lowerBound < endRange.lowerBound {
            return startRange.lowerBound ..< endRange.upperBound
        }
        return nil
    }
}
