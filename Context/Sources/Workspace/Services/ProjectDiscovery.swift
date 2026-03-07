import Foundation
import GRDB

/// Discovers Claude Code projects from `~/.claude/projects/` and imports them
/// (along with their sessions) into the local database.
///
/// Claude Code stores per-project data in directories whose names encode the
/// absolute project path. Slashes, spaces, dots, and existing hyphens all
/// become `-`, making the encoding ambiguous. `ProjectDiscovery` resolves
/// each encoded name back to a real filesystem path using backtracking against
/// the actual directory structure on disk.
class ProjectDiscovery {

    // MARK: - Properties

    private let claudeDir: URL       // ~/.claude
    private let db: DatabaseService
    private let fileManager = FileManager.default

    // MARK: - Init

    init(db: DatabaseService = .shared) {
        self.db = db
        self.claudeDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Public API

    /// Scan `~/.claude/projects/` and return a `Project` record for each
    /// directory whose encoded name can be resolved to a real path.
    func discoverProjects() throws -> [Project] {
        let projectsDir = claudeDir.appendingPathComponent("projects", isDirectory: true)

        guard fileManager.fileExists(atPath: projectsDir.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var projects: [Project] = []

        for entry in entries {
            // Only look at directories
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let encodedName = entry.lastPathComponent

            // Skip the bare `-` directory (represents `/`, not a real project)
            guard encodedName != "-" else { continue }

            // Try to resolve the encoded name back to a filesystem path
            guard let resolvedPath = resolvePath(from: encodedName) else {
                // Could not resolve — project directory may have been deleted.
                // Still create a record so the user can see historical sessions.
                let fallbackName = encodedName.split(separator: "-").last.map(String.init) ?? encodedName
                let project = Project(
                    id: UUID().uuidString,
                    name: fallbackName,
                    path: encodedName, // store encoded name as-is
                    claudeProject: entry.path,
                    lastOpened: nil,
                    createdAt: Date()
                )
                projects.append(project)
                continue
            }

            let name = (resolvedPath as NSString).lastPathComponent
            let project = Project(
                id: UUID().uuidString,
                name: name,
                path: resolvedPath,
                claudeProject: entry.path,
                lastOpened: nil,
                createdAt: Date()
            )
            projects.append(project)
        }

        return projects
    }

    /// Discover projects and insert any that are not already in the database
    /// (matched by `path`).
    func importProjects() throws {
        let discovered = try discoverProjects()

        try db.dbQueue.write { dbConn in
            for project in discovered {
                // Skip if a project with the same path already exists
                let exists = try Project
                    .filter(Project.Columns.path == project.path)
                    .fetchCount(dbConn) > 0

                if !exists {
                    var p = project
                    try p.insert(dbConn)
                }
            }
        }
    }

    /// Discover `.jsonl` session files for a project and import any that are
    /// not already in the database.
    func importSessions(for project: Project) throws {
        guard let claudeProjectPath = project.claudeProject else { return }

        let claudeProjectURL = URL(fileURLWithPath: claudeProjectPath, isDirectory: true)

        guard fileManager.fileExists(atPath: claudeProjectURL.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: claudeProjectURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }

        try db.dbQueue.write { dbConn in
            for file in jsonlFiles {
                let sessionId = file.deletingPathExtension().lastPathComponent

                // Check if session already exists
                let existing = try Session
                    .filter(Session.Columns.id == sessionId)
                    .fetchOne(dbConn)

                // Skip if session exists under the same project AND already has token data
                if let existing = existing,
                   existing.projectId == project.id,
                   existing.inputTokens > 0 || existing.outputTokens > 0 {
                    continue
                }

                // Parse the session file (new session or backfill tokens)
                guard let parsed = try? SessionParser.parse(fileURL: file) else { continue }

                let summary = SessionParser.generateSummary(from: parsed)

                let filesChangedJSON: String? = {
                    guard !parsed.filesChanged.isEmpty,
                          let data = try? JSONEncoder().encode(parsed.filesChanged),
                          let str = String(data: data, encoding: .utf8)
                    else { return nil }
                    return str
                }()

                var session = Session(
                    id: parsed.sessionId,
                    projectId: project.id,
                    slug: parsed.slug,
                    startedAt: parsed.startedAt,
                    endedAt: parsed.endedAt,
                    model: parsed.model,
                    gitBranch: parsed.gitBranch,
                    summary: summary,
                    messageCount: parsed.messageCount,
                    toolUseCount: parsed.toolUseCount,
                    filesChanged: filesChangedJSON,
                    inputTokens: parsed.inputTokens,
                    outputTokens: parsed.outputTokens,
                    cacheCreationTokens: parsed.cacheCreationTokens,
                    cacheReadTokens: parsed.cacheReadTokens
                )
                try session.save(dbConn) // save = insert or update
            }
        }
    }

    // MARK: - Path Resolution

    /// The characters that Claude Code's encoding maps to `-`.
    /// A `-` in the encoded name could have originally been any of these.
    private static let replacementChars: [Character] = ["-", " ", "."]

    /// Maximum time (in seconds) to spend resolving a single encoded name
    /// before giving up. Prevents runaway backtracking for deleted projects
    /// with deeply ambiguous encodings.
    private static let resolveTimeoutSeconds: TimeInterval = 0.5

    /// Resolve an encoded Claude project directory name back to a real
    /// filesystem path.
    ///
    /// Claude Code encodes absolute paths by replacing `/`, ` `, `.`, (and
    /// keeping `-` as `-`) all with `-`. This function resolves the ambiguity
    /// by trying each possible original character at every `-` position and
    /// checking the filesystem.
    ///
    /// The algorithm works at two levels:
    /// 1. **Path component boundary**: at each `-`, try treating it as a `/`
    ///    and check if the prefix is a real directory.
    /// 2. **Within-component characters**: if `/` doesn't work, try `-`, ` `,
    ///    and `.` to continue building the current component name.
    ///
    /// Uses memoization on `(charIndex, parentDir)` to prune redundant
    /// branches, and a timeout to bound worst-case runtime.
    ///
    /// - Parameter encodedName: e.g. `-Users-connor-Documents-my-project`
    /// - Returns: The resolved absolute path, or `nil` if no valid path is found.
    func resolvePath(from encodedName: String) -> String? {
        // Strip leading dash (represents the leading `/`)
        var stripped = encodedName
        if stripped.hasPrefix("-") {
            stripped = String(stripped.dropFirst())
        }

        guard !stripped.isEmpty else { return nil }

        let chars = Array(stripped)

        // Memoization: track (charIndex, parentDir) states known to fail.
        var failedStates = Set<String>()
        let deadline = Date().addingTimeInterval(Self.resolveTimeoutSeconds)

        return buildPath(
            chars: chars,
            charIndex: 0,
            parentDir: "/",
            componentSoFar: "",
            failedStates: &failedStates,
            deadline: deadline
        )
    }

    /// Recursively resolve the encoded string character-by-character.
    ///
    /// - Parameters:
    ///   - chars: The full encoded string as a character array (leading `-` already stripped).
    ///   - charIndex: Current position in the character array.
    ///   - parentDir: The validated directory path built so far.
    ///   - componentSoFar: The partial path component being assembled.
    ///   - failedStates: Memoization set of `"charIndex:parentDir"` keys that lead nowhere.
    ///   - deadline: Absolute time after which we stop searching.
    /// - Returns: A valid filesystem path, or `nil`.
    private func buildPath(
        chars: [Character],
        charIndex: Int,
        parentDir: String,
        componentSoFar: String,
        failedStates: inout Set<String>,
        deadline: Date
    ) -> String? {
        // Check timeout
        if Date() > deadline { return nil }

        // Base case: consumed all characters
        if charIndex >= chars.count {
            if componentSoFar.isEmpty {
                return fileManager.fileExists(atPath: parentDir) ? parentDir : nil
            }
            let finalPath = (parentDir as NSString).appendingPathComponent(componentSoFar)
            return fileManager.fileExists(atPath: finalPath) ? finalPath : nil
        }

        // Memoization key: captures position in the encoded string and which
        // validated directory we've reached. The componentSoFar is deliberately
        // excluded — we only memo when entering a new directory (componentSoFar
        // is empty after a `/` split), which is the key branching point.
        if componentSoFar.isEmpty {
            let stateKey = "\(charIndex):\(parentDir)"
            if failedStates.contains(stateKey) { return nil }
        }

        let ch = chars[charIndex]

        if ch != "-" {
            // Not a dash — this character is unambiguous, append it.
            let result = buildPath(
                chars: chars,
                charIndex: charIndex + 1,
                parentDir: parentDir,
                componentSoFar: componentSoFar + String(ch),
                failedStates: &failedStates,
                deadline: deadline
            )
            if result == nil && componentSoFar.isEmpty {
                failedStates.insert("\(charIndex):\(parentDir)")
            }
            return result
        }

        // The character is `-`. Try each possible interpretation.

        // Option 1: This dash is a `/` (path component boundary).
        // Only valid if we have accumulated a component name.
        if !componentSoFar.isEmpty {
            let candidateDir = (parentDir as NSString).appendingPathComponent(componentSoFar)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidateDir, isDirectory: &isDir),
               isDir.boolValue {
                if let result = buildPath(
                    chars: chars,
                    charIndex: charIndex + 1,
                    parentDir: candidateDir,
                    componentSoFar: "",
                    failedStates: &failedStates,
                    deadline: deadline
                ) {
                    return result
                }
            }
        }

        // Option 2: This dash represents `-`, ` `, or `.` within a component.
        for replacement in Self.replacementChars {
            if let result = buildPath(
                chars: chars,
                charIndex: charIndex + 1,
                parentDir: parentDir,
                componentSoFar: componentSoFar + String(replacement),
                failedStates: &failedStates,
                deadline: deadline
            ) {
                return result
            }
        }

        // Record failure for memoization (only at directory boundaries)
        if componentSoFar.isEmpty {
            failedStates.insert("\(charIndex):\(parentDir)")
        }

        return nil
    }
}
