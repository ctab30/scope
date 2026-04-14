import Foundation
import GRDB

// MARK: - Database Access

/// Opens the same database used by the Workspace app.
func openDatabase() throws -> DatabaseQueue {
    let appSupportURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("Workspace", isDirectory: true)

    let dbPath = appSupportURL.appendingPathComponent("workspace.db").path
    guard FileManager.default.fileExists(atPath: dbPath) else {
        throw MCPError(message: "Workspace database not found at \(dbPath). Launch Workspace first.")
    }
    var config = Configuration()
    config.busyMode = .timeout(5.0) // Wait up to 5s for locks (cross-process access)
    let db = try DatabaseQueue(path: dbPath, configuration: config)

    // Enable WAL mode for concurrent cross-process access
    try db.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA journal_mode=WAL")
    }

    // Ensure browserCommands table exists (may not if GUI app hasn't launched since update)
    try db.write { conn in
        try conn.execute(sql: """
            CREATE TABLE IF NOT EXISTS browserCommands (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool TEXT NOT NULL,
                args TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                result TEXT,
                createdAt DATETIME NOT NULL,
                completedAt DATETIME
            )
        """)
    }

    // Ensure indexRequests table exists for MCP-to-GUI IPC
    try db.write { conn in
        try conn.execute(sql: """
            CREATE TABLE IF NOT EXISTS indexRequests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                projectId TEXT NOT NULL,
                projectPath TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                createdAt DATETIME NOT NULL
            )
        """)
    }

    // Ensure generatedImages table exists for image generation tools
    try db.write { conn in
        try conn.execute(sql: """
            CREATE TABLE IF NOT EXISTS generatedImages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                projectId TEXT NOT NULL,
                prompt TEXT NOT NULL,
                responseText TEXT,
                filePath TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT 'google/gemini-3.1-flash-image-preview',
                aspectRatio TEXT DEFAULT '1:1',
                imageSize TEXT DEFAULT '1K',
                parentImageId INTEGER REFERENCES generatedImages(id) ON DELETE SET NULL,
                createdAt DATETIME NOT NULL
            )
        """)
    }

    // Ensure uiCommands table exists for MCP-to-GUI IPC (commit messages, etc.)
    try db.write { conn in
        try conn.execute(sql: """
            CREATE TABLE IF NOT EXISTS uiCommands (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                command TEXT NOT NULL,
                args TEXT,
                projectId TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                result TEXT,
                createdAt DATETIME NOT NULL,
                completedAt DATETIME
            )
        """)
    }

    // Ensure indexes exist for common MCP query patterns
    try db.write { conn in
        try conn.execute(sql: "CREATE INDEX IF NOT EXISTS idx_taskItems_project_status ON taskItems(projectId, status)")
        try conn.execute(sql: "CREATE INDEX IF NOT EXISTS idx_notes_project_pinned ON notes(projectId, pinned)")
        try conn.execute(sql: "CREATE INDEX IF NOT EXISTS idx_taskNotes_taskId ON taskNotes(taskId)")
    }

    return db
}

// MARK: - Models (lightweight copies)

struct TaskItem: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var title: String
    var description: String?
    var status: String
    var priority: Int
    var sourceSession: String?
    var source: String
    var createdAt: Date
    var completedAt: Date?
    var labels: String?
    var attachments: String?
    var isGlobal: Bool = false
    var gmailThreadId: String?
    var gmailMessageId: String?
    var recordingId: String?
    var parentTaskId: Int64?
    var blockedBy: String?
    var completionSummary: String?
    static let databaseTableName = "taskItems"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TaskNote: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var taskId: Int64
    var content: String
    var source: String
    var sessionId: String?
    var createdAt: Date
    static let databaseTableName = "taskNotes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Project: Codable, FetchableRecord, TableRecord {
    var id: String
    var name: String
    var path: String
    static let databaseTableName = "projects"
}

struct Note: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var title: String
    var content: String
    var pinned: Bool
    var sessionId: String?
    var createdAt: Date
    var updatedAt: Date
    var isGlobal: Bool
    static let databaseTableName = "notes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Client: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var name: String
    var color: String
    var sortOrder: Int
    var createdAt: Date
    static let databaseTableName = "clients"
}

struct BrowserCommand: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var tool: String
    var args: String?
    var status: String
    var result: String?
    var createdAt: Date
    var completedAt: Date?
    static let databaseTableName = "browserCommands"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct CodeChunk: Codable, FetchableRecord {
    var id: String
    var fileId: String
    var projectId: String
    var chunkType: String
    var symbolName: String?
    var content: String
    var startLine: Int?
    var endLine: Int?
    var embedding: Data?

    static let databaseTableName = "codeChunks"

    var embeddingVector: [Float]? {
        guard let data = embedding else { return nil }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}

struct IndexState: Codable, FetchableRecord {
    var projectId: String
    var status: String
    var lastFullIndexAt: Date?
    var totalChunks: Int
    var lastError: String?

    static let databaseTableName = "indexState"
}

// MARK: - String Similarity

/// Jaro-Winkler string similarity (0.0 = no match, 1.0 = exact match)
func jaroWinklerSimilarity(_ s1: String, _ s2: String) -> Double {
    let s1 = Array(s1.lowercased())
    let s2 = Array(s2.lowercased())

    guard !s1.isEmpty && !s2.isEmpty else { return s1.isEmpty && s2.isEmpty ? 1.0 : 0.0 }

    let matchDistance = max(0, max(s1.count, s2.count) / 2 - 1)

    var s1Matches = [Bool](repeating: false, count: s1.count)
    var s2Matches = [Bool](repeating: false, count: s2.count)
    var matches: Double = 0
    var transpositions: Double = 0

    for i in 0..<s1.count {
        let start = max(0, i - matchDistance)
        let end = min(i + matchDistance + 1, s2.count)
        for j in start..<end {
            guard !s2Matches[j] && s1[i] == s2[j] else { continue }
            s1Matches[i] = true
            s2Matches[j] = true
            matches += 1
            break
        }
    }

    guard matches > 0 else { return 0.0 }

    var k = 0
    for i in 0..<s1.count {
        guard s1Matches[i] else { continue }
        while !s2Matches[k] { k += 1 }
        if s1[i] != s2[k] { transpositions += 1 }
        k += 1
    }

    let jaro = (matches / Double(s1.count) + matches / Double(s2.count) + (matches - transpositions / 2) / matches) / 3.0

    // Winkler bonus for common prefix (up to 4 chars)
    var prefix = 0
    for i in 0..<min(4, min(s1.count, s2.count)) {
        guard s1[i] == s2[i] else { break }
        prefix += 1
    }

    return jaro + Double(prefix) * 0.1 * (1.0 - jaro)
}

/// Normalized token overlap (Jaccard similarity on words)
func tokenOverlap(_ s1: String, _ s2: String) -> Double {
    let tokens1 = Set(s1.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    let tokens2 = Set(s2.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    guard !tokens1.isEmpty || !tokens2.isEmpty else { return 0.0 }
    let intersection = tokens1.intersection(tokens2).count
    let union = tokens1.union(tokens2).count
    return union > 0 ? Double(intersection) / Double(union) : 0.0
}

// MARK: - MCP Protocol Types

struct MCPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: [String: AnyCodable]?
}

enum JSONRPCID: Codable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(JSONRPCID.self, .init(codingPath: [], debugDescription: "Expected int or string"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }
}

/// Minimal any-value wrapper for JSON decoding.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull(); return }
        if let b = try? container.decode(Bool.self) { value = b; return }
        if let i = try? container.decode(Int.self) { value = i; return }
        if let d = try? container.decode(Double.self) { value = d; return }
        if let s = try? container.decode(String.self) { value = s; return }
        if let a = try? container.decode([AnyCodable].self) { value = a.map(\.value); return }
        if let o = try? container.decode([String: AnyCodable].self) { value = o.mapValues(\.value); return }
        throw DecodingError.typeMismatch(AnyCodable.self, .init(codingPath: [], debugDescription: "Unsupported type"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        default: try container.encodeNil()
        }
    }
}

// MARK: - MCP Connection Status

/// Writes a status file so the Workspace GUI can show an MCP connection indicator.
class MCPConnectionStatus {
    /// Static reference for signal handler cleanup (signal handlers can't capture instance state)
    static var activeStatusFile: URL?

    let statusDir: URL
    let statusFile: URL
    let pid: Int32

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Workspace/mcp-connections", isDirectory: true)
        statusDir = appSupport
        pid = ProcessInfo.processInfo.processIdentifier
        statusFile = appSupport.appendingPathComponent("\(pid).json")
    }

    func register(projectId: String?, projectName: String?, cwd: String) {
        try? FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
        MCPConnectionStatus.activeStatusFile = statusFile
        writeStatus(projectId: projectId, projectName: projectName, cwd: cwd)
    }

    func heartbeat(projectId: String?, projectName: String?, cwd: String) {
        writeStatus(projectId: projectId, projectName: projectName, cwd: cwd)
    }

    func deregister() {
        try? FileManager.default.removeItem(at: statusFile)
    }

    private var initialConnectedAt: String?

    /// Detects if the parent Claude Code process was launched with --dangerously-skip-permissions.
    /// Walks up the process tree (up to 5 levels) and also checks environment variables.
    lazy var isDangerousMode: Bool = {
        // Check environment variable first (most reliable if set)
        if let envVal = ProcessInfo.processInfo.environment["CLAUDE_DANGEROUS_MODE"],
           !envVal.isEmpty && envVal != "0" && envVal.lowercased() != "false" {
            return true
        }

        // Walk up the process tree checking each ancestor's command line
        var currentPid = getppid()
        for _ in 0..<5 {
            guard currentPid > 1 else { break }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-p", "\(currentPid)", "-o", "ppid=,args="]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { break }
            proc.waitUntilExit()
            let output = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { break }

            if output.contains("--dangerously-skip-permissions") || output.contains("-dangerously-skip-permissions") {
                return true
            }

            // Extract parent PID for next iteration
            let parts = output.split(separator: " ", maxSplits: 1)
            guard let nextPid = parts.first.flatMap({ Int32($0) }), nextPid > 1, nextPid != currentPid else { break }
            currentPid = nextPid
        }
        return false
    }()

    private func writeStatus(projectId: String?, projectName: String?, cwd: String) {
        if initialConnectedAt == nil {
            initialConnectedAt = ISO8601DateFormatter().string(from: Date())
        }
        var status: [String: Any] = [
            "pid": Int(pid),
            "cwd": cwd,
            "projectId": projectId as Any,
            "projectName": projectName as Any,
            "connectedAt": initialConnectedAt as Any,
            "lastActivityAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if isDangerousMode {
            status["dangerousMode"] = true
        }
        if let data = try? JSONSerialization.data(withJSONObject: status.compactMapValues { $0 }) {
            try? data.write(to: statusFile, options: .atomic)
        }
    }
}

// MARK: - Query Preprocessor (duplicated from Workspace module — WorkspaceMCP cannot import it)

/// Preprocesses search queries to improve result quality.
/// Classifies queries, expands synonyms, strips filler words, and selects adaptive weights.
struct QueryPreprocessor {

    enum QueryType {
        case symbol   // looks like a function/class name
        case concept  // natural language question about behavior
        case pattern  // looking for a code pattern
    }

    struct ProcessedQuery {
        let originalQuery: String
        let tokenizedQuery: String       // cleaned for embedding
        let expandedTerms: [String]      // additional FTS terms (concept queries only)
        let queryType: QueryType
        let semanticWeight: Float        // 0-1
        let keywordWeight: Float         // 0-1
    }

    // MARK: - Public API

    static func process(_ query: String) -> ProcessedQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProcessedQuery(
                originalQuery: query,
                tokenizedQuery: "",
                expandedTerms: [],
                queryType: .pattern,
                semanticWeight: 0.70,
                keywordWeight: 0.30
            )
        }

        let queryType = classify(trimmed)
        let tokenized = tokenize(trimmed)
        let expanded = queryType == .concept ? expand(trimmed) : []
        let weights = selectWeights(queryType)

        return ProcessedQuery(
            originalQuery: query,
            tokenizedQuery: tokenized,
            expandedTerms: expanded,
            queryType: queryType,
            semanticWeight: weights.semantic,
            keywordWeight: weights.keyword
        )
    }

    // MARK: - Classification

    /// Classify a query as symbol, concept, or pattern based on heuristics.
    static func classify(_ query: String) -> QueryType {
        let words = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Single word or 2 words that look like code identifiers → symbol
        if words.count <= 2 {
            let allCodeLike = words.allSatisfy { isCodeToken($0) }
            if allCodeLike { return .symbol }
        }

        // Contains code operators → likely symbol or pattern
        let codeOperators: [Character] = [".", "(", ")", "<", ">", "_"]
        let hasCodeOps = query.contains(where: { codeOperators.contains($0) })
        if hasCodeOps && words.count <= 3 { return .symbol }

        // Question words → concept
        let questionWords = ["how", "where", "what", "why", "when", "which", "find", "show", "list", "get"]
        if let first = words.first?.lowercased(), questionWords.contains(first) {
            return .concept
        }

        // Longer queries without code tokens → concept
        if words.count >= 4 && !hasCodeOps {
            return .concept
        }

        // Default: pattern (balanced blend)
        return .pattern
    }

    // MARK: - Tokenization

    /// Strip filler words from queries 4+ words long, preserve code tokens.
    static func tokenize(_ query: String) -> String {
        let words = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count >= 4 else { return query }

        let fillerWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been",
            "of", "in", "to", "for", "with", "on", "at", "from", "by",
            "that", "which", "this", "these", "those", "it", "its",
            "do", "does", "did", "has", "have", "had"
        ]

        let filtered = words.filter { word in
            // Always keep code tokens
            if isCodeToken(word) { return true }
            // Strip filler words
            return !fillerWords.contains(word.lowercased())
        }

        // Don't strip everything — keep at least 2 words
        if filtered.count < 2 { return query }
        return filtered.joined(separator: " ")
    }

    // MARK: - Query Expansion

    /// Expand concept queries with related programming terms.
    static func expand(_ query: String) -> [String] {
        let lowered = query.lowercased()
        var expansions: [String] = []

        for (_, terms) in synonymMap {
            // Check if any term from this group appears in the query
            let matched = terms.first { lowered.contains($0) }
            if matched != nil {
                // Add all other terms from this group as expansions
                for term in terms {
                    if !lowered.contains(term) {
                        expansions.append(term)
                    }
                }
            }
        }

        return Array(expansions.prefix(15))
    }

    // MARK: - Weight Selection

    private static func selectWeights(_ type: QueryType) -> (semantic: Float, keyword: Float) {
        switch type {
        case .symbol:  return (semantic: 0.40, keyword: 0.60)
        case .concept: return (semantic: 0.85, keyword: 0.15)
        case .pattern: return (semantic: 0.70, keyword: 0.30)
        }
    }

    // MARK: - Helpers

    /// Check if a word looks like a code identifier.
    private static func isCodeToken(_ word: String) -> Bool {
        // Contains dots, underscores, parens, or angle brackets
        if word.contains(".") || word.contains("_") || word.contains("(") || word.contains("<") {
            return true
        }
        // camelCase detection: lowercase letter followed by uppercase
        let chars = Array(word)
        for i in 1..<chars.count {
            if chars[i-1].isLowercase && chars[i].isUppercase { return true }
        }
        return false
    }

    // MARK: - Synonym Map

    /// Static map of related programming concepts for query expansion.
    static let synonymMap: [String: [String]] = [
        "auth":       ["auth", "authentication", "login", "signin", "signout", "logout", "session", "credential", "token", "jwt", "oauth"],
        "database":   ["database", "db", "sql", "query", "migration", "schema", "table", "column", "record", "model"],
        "api":        ["api", "endpoint", "route", "handler", "request", "response", "rest", "controller"],
        "ui":         ["ui", "view", "component", "layout", "render", "display", "screen", "widget", "interface"],
        "error":      ["error", "exception", "throw", "catch", "fail", "crash", "bug", "issue"],
        "test":       ["test", "spec", "assert", "expect", "mock", "stub", "fixture", "unittest"],
        "network":    ["network", "http", "fetch", "request", "url", "socket", "websocket", "connection"],
        "storage":    ["storage", "cache", "persist", "save", "store", "disk", "file", "write", "read"],
        "config":     ["config", "configuration", "settings", "preferences", "options", "environment", "env"],
        "nav":        ["navigation", "navigate", "route", "router", "redirect", "link", "path"],
        "state":      ["state", "store", "redux", "context", "provider", "observable", "published", "binding"],
        "style":      ["style", "css", "theme", "color", "font", "margin", "padding", "layout"],
        "async":      ["async", "await", "promise", "future", "concurrent", "parallel", "dispatch", "queue", "thread"],
        "parse":      ["parse", "decode", "deserialize", "json", "xml", "serialize", "encode", "format"],
        "validate":   ["validate", "validation", "check", "verify", "sanitize", "constraint", "rule"],
        "security":   ["security", "encrypt", "decrypt", "hash", "salt", "password", "permission", "authorize"],
        "deploy":     ["deploy", "build", "ci", "cd", "pipeline", "release", "publish", "ship"],
        "git":        ["git", "commit", "branch", "merge", "rebase", "push", "pull", "clone", "diff", "status"],
        "image":      ["image", "photo", "picture", "thumbnail", "avatar", "icon", "graphic", "media"],
        "notify":     ["notification", "notify", "alert", "push", "email", "sms", "message", "toast"],
        "search":     ["search", "find", "filter", "query", "lookup", "index", "match"],
        "log":        ["log", "logging", "debug", "trace", "print", "monitor", "analytics", "telemetry"],
        "payment":    ["payment", "pay", "charge", "invoice", "billing", "subscription", "stripe", "checkout"],
        "user":       ["user", "account", "profile", "member", "role", "permission"],
        "upload":     ["upload", "download", "transfer", "import", "export", "attach", "file"],
        "schedule":   ["schedule", "cron", "timer", "interval", "recurring", "background", "job", "task", "queue"],
        "embed":      ["embed", "embedding", "vector", "similarity", "semantic", "cosine"],
        "chunk":      ["chunk", "split", "segment", "tokenize", "partition", "slice"],
        "browser":    ["browser", "webview", "wkwebview", "tab", "page", "dom", "javascript"],
        "process":    ["process", "spawn", "exec", "shell", "command", "terminal", "subprocess"],
    ]
}

// MARK: - MCP Server

class MCPServer {
    let db: DatabaseQueue
    var detectedProjectId: String?
    var detectedProjectName: String?
    let workingDirectory: String
    let connectionStatus: MCPConnectionStatus
    let embeddingCache = EmbeddingCache()

    /// Tool tier controls which tools are exposed. Reduces context window usage.
    /// core (~5K tokens): Essential task + project tools only
    /// standard (~10K tokens): Core + notes + plans + task files
    /// full (~20K tokens): All tools including browser, git, network, env
    let toolTier: String  // "core", "standard", "full"

    init(db: DatabaseQueue) {
        self.db = db
        self.workingDirectory = FileManager.default.currentDirectoryPath
        self.connectionStatus = MCPConnectionStatus()

        // Auto-detect project from working directory
        var foundId: String? = nil
        var foundName: String? = nil
        let cwd = self.workingDirectory

        if let match = try? db.read({ db -> Project? in
            // Exact match first
            if let exact = try Project.filter(Column("path") == cwd).fetchOne(db) {
                return exact
            }
            // Try parent directories (for subdirectories like /project/src)
            let projects = try Project.fetchAll(db)
            var best: Project? = nil
            var bestLen = 0
            for p in projects {
                if cwd.hasPrefix(p.path) && p.path.count > bestLen {
                    best = p
                    bestLen = p.path.count
                }
            }
            return best
        }) {
            foundId = match.id
            foundName = match.name
        }

        self.detectedProjectId = foundId
        self.detectedProjectName = foundName

        // Log detected project to stderr for debugging
        if let name = foundName {
            FileHandle.standardError.write("WorkspaceMCP: detected project '\(name)' from \(cwd)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("WorkspaceMCP: no project matched for \(cwd)\n".data(using: .utf8)!)
        }

        // Read tool tier from environment (default: full for backwards compatibility)
        self.toolTier = ProcessInfo.processInfo.environment["WORKSPACE_TOOLS"] ?? "full"
        FileHandle.standardError.write("WorkspaceMCP: tool tier = \(self.toolTier)\n".data(using: .utf8)!)

        // Register connection
        connectionStatus.register(projectId: foundId, projectName: foundName, cwd: cwd)
    }

    /// Resolves project_id from args or falls back to auto-detected project.
    func resolveProjectId(_ args: [String: Any]) throws -> String {
        if let explicit = args["project_id"] as? String {
            return explicit
        }
        guard let detected = detectedProjectId else {
            throw MCPError(message: "project_id is required (could not auto-detect from working directory)")
        }
        return detected
    }

    func run() {
        // Clean up on exit
        defer { connectionStatus.deregister() }

        // Handle SIGTERM/SIGINT for clean shutdown
        // Note: exit() does not run Swift defer blocks, so we clean up the status file
        // via the static reference since signal handlers can't capture instance state.
        signal(SIGTERM) { _ in
            if let file = MCPConnectionStatus.activeStatusFile {
                try? FileManager.default.removeItem(at: file)
            }
            exit(0)
        }
        signal(SIGINT) { _ in
            if let file = MCPConnectionStatus.activeStatusFile {
                try? FileManager.default.removeItem(at: file)
            }
            exit(0)
        }

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }

            // Update heartbeat on each request
            connectionStatus.heartbeat(
                projectId: detectedProjectId,
                projectName: detectedProjectName,
                cwd: workingDirectory
            )

            do {
                let request = try JSONDecoder.mcp.decode(JSONRPCRequest.self, from: data)
                let response = handleRequest(request)
                write(response)
            } catch {
                let errResp = errorResponse(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
                write(errResp)
            }
        }
    }

    /// Build dynamic instructions based on current project state.
    /// These are the single source of truth for how agents should use workspace tools.
    func buildDynamicInstructions() -> String {
        var parts: [String] = []

        // Core workflow
        parts.append("Start with get_project_context. ALWAYS create a task with create_task(status: \"in_progress\") for any work that modifies code or produces output. The only exception is pure read-only questions.")

        // When to use each tool — prescriptive, not optional
        parts.append("")
        parts.append("## Required workflow")
        parts.append("- **set_task_plan**: Attach a plan BEFORE starting multi-step work. If a PLAN.md exists in the repo, attach its content.")
        parts.append("- **add_task_note**: Log after EVERY meaningful step — commits, decisions, discoveries, blockers. Short and frequent. This is how context survives across sessions.")
        parts.append("- **add_task_file**: EVERY analysis, review, report, or structured output you produce MUST be attached as a markdown file. Do not let deliverables exist only in the conversation.")
        parts.append("- **complete_task**: Finish with a detailed summary. Then capture reusable knowledge (patterns, gotchas, conventions) as a project note with create_note.")
        parts.append("- **create_note**: Project-level knowledge that outlives any single task. NOT for task progress — use add_task_note for that.")

        // Inject active task state so the agent knows what's happening right away
        if detectedProjectId == nil {
            parts.append("")
            parts.append("No project detected for \(workingDirectory). Use create_project to register it before creating tasks or notes.")
        }

        if let projectId = detectedProjectId {
            if let openTasks = try? db.read({ db in
                try TaskItem.filter(Column("projectId") == projectId)
                    .filter(Column("status") != "done")
                    .order(Column("priority").desc)
                    .fetchAll(db)
            }), !openTasks.isEmpty {
                let inProgress = openTasks.filter { $0.status == "in_progress" }

                if !inProgress.isEmpty {
                    parts.append("")
                    parts.append("ACTIVE WORK — resume these before starting new tasks:")
                    for t in inProgress {
                        parts.append("  [in_progress] #\(t.id ?? 0): \(t.title)")
                    }
                    parts.append("Use get_task to load full context for these tasks.")
                }

                let todoCount = openTasks.filter { $0.status == "todo" }.count
                if todoCount > 0 && inProgress.isEmpty {
                    parts.append("")
                    parts.append("You have \(todoCount) queued task(s). Use get_next_task to pick one up.")
                }
            }
        }

        return parts.joined(separator: "\n")
    }

    func handleRequest(_ req: JSONRPCRequest) -> [String: Any] {
        switch req.method {
        case "initialize":
            let instructions = buildDynamicInstructions()
            return successResponse(id: req.id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": [:],
                    "resources": [:],
                ],
                "serverInfo": ["name": "workspace", "version": "2.0.0"],
                "instructions": instructions
            ])

        case "notifications/initialized":
            return [:] // no response for notifications

        case "tools/list":
            let allTools = toolDefinitions()
            let filtered = filterToolsByTier(allTools)
            let annotated = addToolAnnotations(filtered)
            return successResponse(id: req.id, result: ["tools": annotated])

        case "tools/call":
            return handleToolCall(req)

        case "resources/list":
            return handleResourcesList(req)

        case "resources/read":
            return handleResourcesRead(req)

        default:
            return errorResponse(id: req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }

    /// Filter tools based on the configured tool tier.
    /// core: task management + project context only
    /// standard: core + notes + plans + files + clients
    /// full: everything
    func filterToolsByTier(_ tools: [[String: Any]]) -> [[String: Any]] {
        guard toolTier != "full" else { return tools }

        let coreTool = Set([
            "get_current_project",
            "get_project_context",
            "list_tasks",
            "get_task",
            "create_task",
            "update_task",
            "complete_task",
            "get_next_task",
            "search_tasks",
            "add_task_note",
        ])

        let standardTools = coreTool.union([
            "list_projects",
            "create_project",
            "list_task_notes",
            "set_task_plan",
            "get_task_plan",
            "add_task_file",
            "list_notes",
            "get_note",
            "create_note",
            "update_note",
            "delete_note",
            "search_notes",
            "list_clients",
            "create_client",
        ])

        let allowedTools: Set<String>
        switch toolTier {
        case "core":
            allowedTools = coreTool
        case "standard":
            allowedTools = standardTools
        default:
            return tools // unknown tier = full
        }

        return tools.filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return allowedTools.contains(name)
        }
    }

    /// Add MCP tool annotations (readOnlyHint, destructiveHint, idempotentHint) per the 2025-03-26 spec.
    /// Helps clients decide auto-approval and risk assessment.
    func addToolAnnotations(_ tools: [[String: Any]]) -> [[String: Any]] {
        let readOnly: Set<String> = [
            "get_current_project", "get_project_context", "list_projects",
            "list_tasks", "get_task", "get_next_task", "search_tasks",
            "list_task_notes", "get_task_plan",
            "list_notes", "get_note", "search_notes",
            "list_clients",
            "browser_snapshot", "browser_extract", "browser_list_tabs",
            "browser_console_logs", "browser_screenshot", "browser_get_cookies",
            "browser_get_storage",
            "git_status", "git_diff", "git_log",
            "get_network_requests", "get_request_detail",
            "detect_services", "list_env_files", "get_env_variables",
            "context_search",
        ]
        let destructive: Set<String> = [
            "delete_note",
            "browser_clear_session",
            "clear_network_log",
            "git_push",
        ]

        return tools.map { tool in
            guard let name = tool["name"] as? String else { return tool }
            var annotated = tool
            var annotations: [String: Any] = [:]

            if readOnly.contains(name) {
                annotations["readOnlyHint"] = true
            }
            if destructive.contains(name) {
                annotations["destructiveHint"] = true
            }
            // Idempotent: tools that produce the same result on repeat calls
            if readOnly.contains(name) || ["update_task", "update_note", "set_task_plan"].contains(name) {
                annotations["idempotentHint"] = true
            }

            if !annotations.isEmpty {
                annotated["annotations"] = annotations
            }
            return annotated
        }
    }

    // MARK: - Resource Handlers

    /// List available MCP resources. Exposes project context so it loads automatically into the AI's context.
    func handleResourcesList(_ req: JSONRPCRequest) -> [String: Any] {
        var resources: [[String: Any]] = []

        if detectedProjectId != nil, let name = detectedProjectName {
            resources.append([
                "uri": "workspace://project/context",
                "name": "Project Context: \(name)",
                "description": "Current project state including tech stack, git info, open tasks, and pinned notes. Loaded automatically at session start.",
                "mimeType": "text/markdown",
                "annotations": [
                    "audience": ["assistant"],
                    "priority": 1.0,
                ],
            ])
            resources.append([
                "uri": "workspace://project/tasks",
                "name": "Active Tasks: \(name)",
                "description": "All open tasks for the current project with status and priority.",
                "mimeType": "text/markdown",
                "annotations": [
                    "audience": ["assistant"],
                    "priority": 0.8,
                ],
            ])
        }

        return successResponse(id: req.id, result: ["resources": resources])
    }

    /// Read a specific MCP resource by URI.
    func handleResourcesRead(_ req: JSONRPCRequest) -> [String: Any] {
        let params = req.params ?? [:]
        guard let uri = params["uri"]?.value as? String else {
            return errorResponse(id: req.id, code: -32602, message: "Missing uri parameter")
        }

        do {
            let content: String
            switch uri {
            case "workspace://project/context":
                content = try getProjectContext()
            case "workspace://project/tasks":
                content = try getActiveTasksSummary()
            default:
                return errorResponse(id: req.id, code: -32602, message: "Unknown resource: \(uri)")
            }
            return successResponse(id: req.id, result: [
                "contents": [
                    ["uri": uri, "mimeType": "text/markdown", "text": content]
                ]
            ])
        } catch {
            return errorResponse(id: req.id, code: -32603, message: "Resource read error: \(error.localizedDescription)")
        }
    }

    /// Returns a summary of active tasks for resource reads and tool response enrichment.
    func getActiveTasksSummary() throws -> String {
        guard let projectId = detectedProjectId else {
            return "No project detected."
        }

        let openTasks = try db.read { db in
            try TaskItem.filter(Column("projectId") == projectId)
                .filter(Column("status") != "done")
                .order(Column("priority").desc, Column("createdAt").desc)
                .fetchAll(db)
        }

        guard !openTasks.isEmpty else {
            return "No open tasks. Use create_task to start tracking work."
        }

        var lines: [String] = ["# Active Tasks (\(openTasks.count))"]
        let grouped: [(String, [TaskItem])] = [
            ("In Progress", openTasks.filter { $0.status == "in_progress" }),
            ("Todo", openTasks.filter { $0.status == "todo" }),
        ]

        for (label, tasks) in grouped where !tasks.isEmpty {
            lines.append("## \(label)")
            for t in tasks {
                let priority = t.priority > 0 ? " [P\(t.priority)]" : ""
                lines.append("- #\(t.id ?? 0): \(t.title)\(priority)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Build a compact task context footer to append to tool responses.
    /// This keeps the AI aware of active tasks and encourages continued MCP usage.
    func activeTaskContextFooter() -> String? {
        guard let projectId = detectedProjectId else { return nil }

        guard let inProgress = try? db.read({ db in
            try TaskItem.filter(Column("projectId") == projectId)
                .filter(Column("status") == "in_progress")
                .order(Column("priority").desc)
                .limit(3)
                .fetchAll(db)
        }), !inProgress.isEmpty else { return nil }

        var footer = "\n---\nActive tasks:"
        for t in inProgress {
            footer += " #\(t.id ?? 0) \(t.title);"
        }
        footer += "\nLog this step: add_task_note | Save output: add_task_file | Done: complete_task"
        return footer
    }

    // MARK: - Tool Definitions

    func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "get_current_project",
                "description": "Get the auto-detected project for this session based on the working directory. Call this first to confirm which project you're working with.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ],
            [
                "name": "get_project_context",
                "description": "Get rich project context: tech stack, file structure, recent git activity, open tasks, and pinned notes. Call this at session start to understand the project you're working with.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ],
            [
                "name": "list_projects",
                "description": "List all projects tracked by Workspace",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ],
            [
                "name": "create_project",
                "description": "Register a new project in Workspace. Use when the current working directory is not tracked. Enables task tracking, notes, and context for the project.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Project name"],
                        "path": ["type": "string", "description": "Absolute path to the project root (defaults to current working directory)"],
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "list_tasks",
                "description": "List tasks for this project, optionally filtered by status. Use for overview and browsing. For picking up the next actionable task, use get_next_task instead. project_id is auto-detected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
                        "status": ["type": "string", "description": "Filter by status: todo, in_progress, done. Omit for all.", "enum": ["todo", "in_progress", "done"]],
                    ]
                ]
            ],
            [
                "name": "get_task",
                "description": "Get full details of a task by ID, including notes and attachments.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"]
                    ],
                    "required": ["task_id"]
                ]
            ],
            [
                "name": "create_task",
                "description": "Create a new task. Use status='in_progress' to create and start immediately. Duplicate detection is automatic. project_id is auto-detected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
                        "title": ["type": "string", "description": "Clear, specific task title"],
                        "description": ["type": "string", "description": "What needs to be done and why"],
                        "priority": ["type": "integer", "description": "0=none, 1=low, 2=medium, 3=high, 4=urgent"],
                        "labels": ["type": "array", "items": ["type": "string"], "description": "Labels: bug, feature, hotfix, refactor, test, docs, performance, security, design, devops"],
                        "status": ["type": "string", "description": "Initial status. Use 'in_progress' to start immediately.", "enum": ["todo", "in_progress"]],
                        "force": ["type": "boolean", "description": "Create even if similar tasks exist"],
                        "session_id": ["type": "string", "description": "Session ID for tracking which session created the task (optional)"],
                    ],
                    "required": ["title", "description", "priority", "labels"]
                ]
            ],
            [
                "name": "update_task",
                "description": "Update a task's fields (status, priority, title, description, labels). Use to start work (status='in_progress'). Do NOT use status='done' — use complete_task instead for proper completion tracking with summary.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"],
                        "status": ["type": "string", "description": "New status", "enum": ["todo", "in_progress", "done"]],
                        "priority": ["type": "integer", "description": "New priority (0-4)"],
                        "title": ["type": "string", "description": "New title"],
                        "description": ["type": "string", "description": "New description"],
                        "labels": ["type": "array", "items": ["type": "string"], "description": "New labels array"],
                    ],
                    "required": ["task_id"]
                ]
            ],
            [
                "name": "add_task_note",
                "description": "Add a progress note to a task. Call this after EVERY meaningful step: commits, design decisions, bug discoveries, blockers, completed milestones. This is how context survives across sessions — without notes, the next session starts blind. Keep notes short and frequent. Task-scoped; for project-wide knowledge use create_note.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"],
                        "content": ["type": "string", "description": "Note content"],
                        "session_id": ["type": "string", "description": "Claude session ID (auto-detected if omitted)"],
                    ],
                    "required": ["task_id", "content"]
                ]
            ],
            [
                "name": "list_task_notes",
                "description": "List all notes for a task (task-scoped). These are progress entries logged during task work.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"]
                    ],
                    "required": ["task_id"]
                ]
            ],
            [
                "name": "set_task_plan",
                "description": "Attach or update an execution plan (markdown) on a task. Saves as a .md file visible in the GUI. ALWAYS call this before starting multi-step work. If a PLAN.md file exists in the repo, attach its content here so the task carries the plan.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"],
                        "plan": ["type": "string", "description": "The plan content in markdown format"],
                    ],
                    "required": ["task_id", "plan"]
                ]
            ],
            [
                "name": "get_task_plan",
                "description": "Get the execution plan attached to a task. Returns the markdown plan if one exists.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"]
                    ],
                    "required": ["task_id"]
                ]
            ],
            [
                "name": "add_task_file",
                "description": "Attach a markdown file to a task. EVERY analysis, review, report, audit, plan, or structured output you produce MUST be saved here — do not let deliverables exist only in the conversation. The file is visible and readable in the Workspace GUI. Task-scoped.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"],
                        "filename": ["type": "string", "description": "Filename (e.g. 'code-review.md', 'analysis.md')"],
                        "content": ["type": "string", "description": "Markdown content of the file"],
                    ],
                    "required": ["task_id", "filename", "content"]
                ]
            ],
            [
                "name": "list_notes",
                "description": "List all project-level notes (project-scoped). These are knowledge entries that outlive any single task — architecture decisions, conventions, patterns, reference material. project_id is auto-detected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
                        "pinned_only": ["type": "boolean", "description": "If true, only return pinned notes"],
                        "global": ["type": "boolean", "description": "Set true to list global planner notes instead of project notes"],
                    ]
                ]
            ],
            [
                "name": "get_note",
                "description": "Get the full content of a project note by ID.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "integer", "description": "Note ID"]
                    ],
                    "required": ["note_id"]
                ]
            ],
            [
                "name": "create_note",
                "description": "Create a project-level note for knowledge that outlives any single task: architecture decisions, coding conventions, environment setup, recurring issues, or patterns discovered. Do NOT use for task-specific progress — use add_task_note for that. Check search_notes first to avoid duplicating existing notes. project_id is auto-detected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
                        "title": ["type": "string", "description": "Note title"],
                        "content": ["type": "string", "description": "Note content (supports markdown)"],
                        "pinned": ["type": "boolean", "description": "Pin this note to the top (default: false)"],
                        "session_id": ["type": "string", "description": "Claude session ID that created this note (optional)"],
                        "global": ["type": "boolean", "description": "Set true to create a global planner note"],
                        "force": ["type": "boolean", "description": "Create even if similar notes exist (default: false)"],
                    ],
                    "required": ["title"]
                ]
            ],
            [
                "name": "update_note",
                "description": "Update a project note's title, content, or pinned status.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "integer", "description": "Note ID"],
                        "title": ["type": "string", "description": "New title"],
                        "content": ["type": "string", "description": "New content"],
                        "pinned": ["type": "boolean", "description": "Pin/unpin the note"],
                    ],
                    "required": ["note_id"]
                ]
            ],
            [
                "name": "delete_note",
                "description": "Delete a project note by ID.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "integer", "description": "Note ID"]
                    ],
                    "required": ["note_id"]
                ]
            ],
            [
                "name": "search_notes",
                "description": "Full-text search across all project notes (titles and content). project_id is auto-detected from working directory if omitted.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
                        "query": ["type": "string", "description": "Search query"],
                        "global": ["type": "boolean", "description": "Set true to search global notes instead of project notes"],
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "list_clients",
                "description": "List all clients (used for project grouping in the sidebar).",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ],
            [
                "name": "create_client",
                "description": "Create a new client for grouping projects.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Client name"],
                        "color": ["type": "string", "description": "Hex color (e.g. #3B82F6). Optional, defaults to blue."]
                    ] as [String: Any],
                    "required": ["name"]
                ] as [String: Any]
            ],
            // MARK: - Browser Tools
            [
                "name": "browser_navigate",
                "description": "Navigate the browser to a URL. Opens a new tab if none are open. Waits for page load to complete. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "URL to navigate to"]
                    ] as [String: Any],
                    "required": ["url"]
                ] as [String: Any]
            ],
            [
                "name": "browser_snapshot",
                "description": "Get the accessibility tree of the current page as compact structured text. Returns ARIA roles, labels, and interactive element refs. This is the primary tool for understanding page content and structure. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"],
                        "max_size": ["type": "integer", "description": "Maximum response size in bytes (default: 102400 = 100KB). Set to 0 for unlimited. Large pages may be truncated with a hint to use browser_extract."]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "name": "browser_extract",
                "description": "Extract text content from a page element using a CSS selector. Returns the text content of the first matching element. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "selector": ["type": "string", "description": "CSS selector to find the element"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ] as [String: Any],
                    "required": ["selector"]
                ] as [String: Any]
            ],
            [
                "name": "browser_list_tabs",
                "description": "List all open browser tabs with their URLs, titles, and loading state. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ] as [String: Any]
            ],
            [
                "name": "browser_console_logs",
                "description": "Get JavaScript console log entries (log, warn, error, info) from a browser tab. Useful for debugging web applications. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"],
                        "level": ["type": "string", "description": "Filter by level: log, warn, error, info", "enum": ["log", "warn", "error", "info"]]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "name": "browser_screenshot",
                "description": "Take a PNG screenshot of the current page. Returns the file path so you can read the image. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "name": "browser_tab_open",
                "description": "Open a new browser tab. Optionally navigate to a URL. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "URL to navigate to (optional)"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "name": "browser_tab_close",
                "description": "Close a browser tab by its ID. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "ID of the tab to close"]
                    ] as [String: Any],
                    "required": ["tab_id"]
                ] as [String: Any]
            ],
            [
                "name": "browser_tab_switch",
                "description": "Switch the active browser tab to the specified tab. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "ID of the tab to switch to"]
                    ] as [String: Any],
                    "required": ["tab_id"]
                ] as [String: Any]
            ],
            // Phase 2: Interaction tools
            [
                "name": "browser_click",
                "description": "Click an element by its ref from browser_snapshot. Automatically scrolls into view first. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref from browser_snapshot (e.g. 'e5')"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["ref"]
                ]
            ],
            [
                "name": "browser_type",
                "description": "Type text into an input or textarea element by ref. Clears existing content by default. Works with React and other framework-controlled inputs. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref from browser_snapshot"],
                        "text": ["type": "string", "description": "Text to type"],
                        "clear": ["type": "boolean", "description": "Clear existing content first (default: true)"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["ref", "text"]
                ]
            ],
            [
                "name": "browser_select",
                "description": "Select an option from a <select> dropdown by value or visible label text. On mismatch, returns all available options. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref of the <select> element"],
                        "value": ["type": "string", "description": "Option value to select"],
                        "label": ["type": "string", "description": "Option visible text to select (alternative to value)"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["ref"]
                ]
            ],
            [
                "name": "browser_scroll",
                "description": "Scroll the page by direction/amount, or scroll a specific element into view. Returns scroll position info. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Scroll this element into view (overrides direction/amount)"],
                        "direction": ["type": "string", "description": "Scroll direction", "enum": ["up", "down", "top", "bottom"]],
                        "amount": ["type": "integer", "description": "Pixels to scroll (default: 500, ignored for top/bottom)"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ]
                ]
            ],
            [
                "name": "browser_wait",
                "description": "Wait for an element to appear on the page. Use after clicking something that triggers async loading. Accepts ref or CSS selector. Returns found status, not an error on timeout. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Wait for element with this ref to exist"],
                        "selector": ["type": "string", "description": "CSS selector to wait for (use when element has no ref yet)"],
                        "timeout": ["type": "integer", "description": "Max seconds to wait (default: 5, max: 15)"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ]
                ]
            ],
            // Phase 3: JS execution, keyboard, hover
            [
                "name": "browser_press",
                "description": "Press a key or key combination. Targets a specific element by ref, or the currently focused element if no ref is provided. Handles Enter (submits forms), Tab (moves focus), Escape, arrow keys, and any single character. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string", "description": "Key to press: Enter, Tab, Escape, Backspace, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Space, Delete, Home, End, PageUp, PageDown, or any single character"],
                        "modifiers": ["type": "array", "items": ["type": "string", "enum": ["shift", "ctrl", "alt", "meta"]], "description": "Modifier keys to hold (e.g. ['meta'] for Cmd+key on Mac)"],
                        "ref": ["type": "string", "description": "Element ref to target (defaults to currently focused element)"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["key"]
                ]
            ],
            [
                "name": "browser_eval",
                "description": "Execute JavaScript on the page and return the result. The expression runs inside an async function body, so use 'return' to return values and 'await' for promises. Use for reading page state, calling APIs, or handling edge cases other tools can't cover. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "expression": ["type": "string", "description": "JavaScript to evaluate. Use 'return' to return a value (e.g. 'return document.title')"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["expression"]
                ]
            ],
            [
                "name": "browser_hover",
                "description": "Hover over an element by ref. Dispatches mouseenter and mouseover events. Useful for dropdown menus, tooltips, and hover-state UI that requires mouse presence. Scrolls element into view first. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref from browser_snapshot"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["ref"]
                ]
            ],
            // Phase 4: Upload, drag, iframe, session
            [
                "name": "browser_upload",
                "description": "Set a file on an <input type='file'> element. Reads the file from disk, encodes it, and assigns it to the input. Triggers change and input events. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref of the file input from browser_snapshot"],
                        "path": ["type": "string", "description": "Absolute path to the file on disk"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["ref", "path"]
                ]
            ],
            [
                "name": "browser_drag",
                "description": "Drag an element to a target element using HTML5 drag and drop events. Dispatches the full drag event sequence: dragstart, drag, dragenter, dragover, drop, dragend. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "from_ref": ["type": "string", "description": "Ref of the element to drag"],
                        "to_ref": ["type": "string", "description": "Ref of the drop target element"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["from_ref", "to_ref"]
                ]
            ],
            [
                "name": "browser_iframe",
                "description": "Switch execution context to an iframe for subsequent commands (snapshot, click, type, etc.), or back to the main frame. Call with a ref to enter an iframe, or without ref to return to main frame. Only same-origin iframes are accessible. Use browser_snapshot to see available iframes. Requires Workspace to be running with the browser tab visible.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Ref of the iframe element to enter. Omit to return to main frame."],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ]
                ]
            ],
            [
                "name": "browser_clear_session",
                "description": "Clear browsing data (cookies, cache, localStorage). Useful for resetting login state, clearing cached data, or testing fresh page loads. Clears all data by default. Requires Workspace to be running.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "types": [
                            "type": "array",
                            "items": ["type": "string", "enum": ["cookies", "cache", "localStorage", "all"]],
                            "description": "Data types to clear. Defaults to all."
                        ],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ]
                ]
            ],
            // Storage Inspection
            [
                "name": "browser_get_cookies",
                "description": "Get cookies for the current page, including httpOnly cookies not visible to JavaScript. Useful for debugging authentication, session management, and tracking. Requires Workspace browser.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "domain": ["type": "string", "description": "Filter cookies by domain substring (e.g. 'example.com')"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ]
                ]
            ],
            [
                "name": "browser_get_storage",
                "description": "Read localStorage or sessionStorage contents. Returns item count, key-value pairs, and total size in bytes. Requires Workspace browser.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["localStorage", "sessionStorage"], "description": "Which storage to read"],
                        "prefix": ["type": "string", "description": "Only return keys starting with this prefix"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["type"]
                ]
            ],
            [
                "name": "browser_set_cookie",
                "description": "Set a cookie on the current page. Useful for testing auth flows, spoofing sessions, or setting feature flags. Requires Workspace browser.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Cookie name"],
                        "value": ["type": "string", "description": "Cookie value"],
                        "domain": ["type": "string", "description": "Cookie domain (defaults to current page domain)"],
                        "path": ["type": "string", "description": "Cookie path (defaults to '/')"],
                        "max_age": ["type": "integer", "description": "Max age in seconds"],
                        "secure": ["type": "boolean", "description": "Secure flag"],
                        "same_site": ["type": "string", "enum": ["Strict", "Lax", "None"], "description": "SameSite attribute"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["name", "value"]
                ]
            ],
            // MARK: - Git Tools
            [
                "name": "git_status",
                "description": "Get git status for the current project. Returns current branch, staged files, unstaged changes, and untracked files. Runs directly against the project's git repository.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "git_diff",
                "description": "Get git diff output. Shows unstaged changes by default, or staged changes with staged=true. Optionally filter to a specific file.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "file_path": ["type": "string", "description": "Specific file to diff (relative to project root)"],
                        "staged": ["type": "boolean", "description": "Show staged changes instead of unstaged (default: false)"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "git_log",
                "description": "Get recent git commit history. Returns commit hash, message, author, and relative date.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "count": ["type": "integer", "description": "Number of commits to show (default: 15, max: 50)"],
                        "file_path": ["type": "string", "description": "Show only commits affecting this file"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "git_stage",
                "description": "Stage files for commit. Stage a specific file or all changes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "file_path": ["type": "string", "description": "File to stage (relative to project root). Omit to stage all changes."],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "git_unstage",
                "description": "Unstage files from the staging area. Unstage a specific file or all staged changes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "file_path": ["type": "string", "description": "File to unstage (relative to project root). Omit to unstage all."],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "git_commit",
                "description": "Stage files first with git_stage. Create a git commit with the currently staged changes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "message": ["type": "string", "description": "Commit message"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": ["message"]
                ]
            ],
            [
                "name": "git_push",
                "description": "Push commits to the remote repository. Pushes the current branch to its upstream remote. Use set_upstream=true to push and set upstream tracking for new branches.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "remote": ["type": "string", "description": "Remote name (default: origin)"],
                        "branch": ["type": "string", "description": "Branch to push (default: current branch)"],
                        "set_upstream": ["type": "boolean", "description": "Set upstream tracking with -u (default: false)"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            // MARK: - UI Command Tools
            [
                "name": "set_commit_message",
                "description": "ALWAYS use this tool when the user asks you to generate, write, or suggest a commit message. This writes the message directly into the Workspace app's commit message box. First review the staged diff (via git_diff with staged=true), then call this tool with the message. Do NOT just print the commit message — always use this tool so it appears in the UI.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "message": ["type": "string", "description": "The commit message to set in the UI"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": ["message"]
                ]
            ],
            // MARK: - Network Inspection Tools
            [
                "name": "get_network_requests",
                "description": "Get captured network requests from the browser's network monitor. Returns method, URL, status, duration, size, and type for each request. The network monitor must be active (started via the DevTools panel).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "domain": ["type": "string", "description": "Filter by domain (substring match)"],
                        "status_class": ["type": "string", "enum": ["2xx", "3xx", "4xx", "5xx", "error"], "description": "Filter by status class"],
                        "limit": ["type": "integer", "description": "Max requests to return (default: 50)"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "get_request_detail",
                "description": "Get full details of a specific network request including headers and body content.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "request_id": ["type": "string", "description": "Request ID from get_network_requests"],
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": ["request_id"]
                ]
            ],
            [
                "name": "clear_network_log",
                "description": "Clear all captured network requests from the browser's network monitor.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Tab ID (defaults to active tab)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            // MARK: - Environment Tools
            [
                "name": "detect_services",
                "description": "Detect cloud services and deployment platforms configured in the project. Scans for Firebase, Supabase, Vercel, Netlify, Docker, Railway, and AWS Amplify configurations.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "list_env_files",
                "description": "List environment files (.env, .env.local, .env.development, etc.) in the project with variable counts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "get_env_variables",
                "description": "Parse and return variables from a specific environment file. Values are masked by default for security.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "file_name": ["type": "string", "description": "Environment file name (e.g. '.env', '.env.local')"],
                        "show_values": ["type": "boolean", "description": "Show actual values instead of masked (default: false)"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ],
                    "required": ["file_name"]
                ]
            ],
            // Context Engine
            [
                "name": "context_search",
                "description": "Semantic code search across the current project. Finds functions, classes, documentation, and git history matching a natural language query. Uses hybrid vector similarity + keyword search.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Natural language description of what you're looking for in the codebase"
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum results to return (default 10, max 30)"
                        ],
                        "types": [
                            "type": "array",
                            "items": ["type": "string", "enum": ["function", "class", "block", "doc", "commit"]],
                            "description": "Filter by chunk type (optional, defaults to all)"
                        ]
                    ],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any],
            // MARK: - Smart Task Tools
            [
                "name": "get_next_task",
                "description": "Get the highest-priority non-blocked task to work on next. Returns full context including plan and recent notes. Use when starting a session or finishing a task — prefer this over list_tasks when you need to pick up work. project_id is auto-detected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"]
                    ]
                ]
            ],
            [
                "name": "search_tasks",
                "description": "Search tasks by title or description. Use to find existing tasks before creating new ones, or to find related work.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query (matches against title and description)"],
                        "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
                        "include_done": ["type": "boolean", "description": "Include completed tasks (default: false)"]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "complete_task",
                "description": "Mark a task as done with a completion summary. Preferred over update_task for finishing work. Include key changes, files modified, and decisions made. If you discovered reusable project knowledge during this task, also create a project-level note with create_note.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "integer", "description": "Task ID"],
                        "summary": ["type": "string", "description": "What was accomplished. Include key changes, files modified, and decisions made."]
                    ],
                    "required": ["task_id"]
                ]
            ],
            // Zendesk tools
            [
                "name": "zendesk_list_tickets",
                "description": "List Zendesk tickets from a view. Defaults to the Product Engineering view. Returns ticket ID, subject, status, priority, requester, assignee.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "view_id": ["type": "integer", "description": "Zendesk view ID (default: Product Engineering view)"],
                        "status": ["type": "string", "description": "Filter by status: new, open, pending, hold, solved, closed"],
                    ]
                ]
            ],
            [
                "name": "zendesk_get_ticket",
                "description": "Get full details of a Zendesk ticket including custom fields (Request Area, Issue Type, Scope, Urgency, System/Application), tags, and requester/assignee info.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ticket_id": ["type": "integer", "description": "Ticket ID"],
                    ],
                    "required": ["ticket_id"]
                ]
            ],
            [
                "name": "zendesk_get_comments",
                "description": "Get the conversation/comment history for a Zendesk ticket. Includes public replies and internal notes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ticket_id": ["type": "integer", "description": "Ticket ID"],
                    ],
                    "required": ["ticket_id"]
                ]
            ],
            [
                "name": "zendesk_reply",
                "description": "Reply to a Zendesk ticket. Can send a public reply (visible to requester) or an internal note (agents only).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ticket_id": ["type": "integer", "description": "Ticket ID"],
                        "body": ["type": "string", "description": "Reply text"],
                        "public": ["type": "boolean", "description": "true for public reply (default), false for internal note"],
                    ],
                    "required": ["ticket_id", "body"]
                ]
            ],
            [
                "name": "zendesk_update_status",
                "description": "Update the status of a Zendesk ticket.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ticket_id": ["type": "integer", "description": "Ticket ID"],
                        "status": ["type": "string", "description": "New status: new, open, pending, hold, solved"],
                    ],
                    "required": ["ticket_id", "status"]
                ]
            ],
            [
                "name": "zendesk_assign",
                "description": "Assign a Zendesk ticket to an agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ticket_id": ["type": "integer", "description": "Ticket ID"],
                        "assignee_id": ["type": "integer", "description": "Agent user ID to assign to (0 to unassign)"],
                    ],
                    "required": ["ticket_id", "assignee_id"]
                ]
            ],
            [
                "name": "zendesk_search",
                "description": "Search Zendesk tickets by query string.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query (Zendesk search syntax)"],
                    ],
                    "required": ["query"]
                ]
            ],
        ]
    }

    // MARK: - Tool Handlers

    func handleToolCall(_ req: JSONRPCRequest) -> [String: Any] {
        let params = req.params ?? [:]
        guard let toolName = params["name"]?.value as? String else {
            return errorResponse(id: req.id, code: -32602, message: "Missing tool name")
        }
        let args = (params["arguments"]?.value as? [String: Any]) ?? [:]

        do {
            let result: String
            switch toolName {
            case "get_current_project": result = try getCurrentProject()
            case "get_project_context": result = try getProjectContext()
            case "list_projects":    result = try listProjects()
            case "create_project":   result = try createProject(args)
            case "list_tasks":       result = try listTasks(args)
            case "get_task":         result = try getTask(args)
            case "create_task":      result = try createTask(args)
            case "update_task":      result = try updateTask(args)
            case "add_task_note":    result = try addTaskNote(args)
            case "list_task_notes":  result = try listTaskNotes(args)
            case "set_task_plan":    result = try setTaskPlan(args)
            case "get_task_plan":    result = try getTaskPlan(args)
            case "add_task_file":    result = try addTaskFile(args)
            case "list_notes":       result = try listNotes(args)
            case "get_note":         result = try getNote(args)
            case "create_note":      result = try createNote(args)
            case "update_note":      result = try updateNote(args)
            case "delete_note":      result = try deleteNote(args)
            case "search_notes":     result = try searchNotes(args)
            case "list_clients":     result = try listClients()
            case "create_client":    result = try createClient(args)
            case "browser_navigate":   result = try browserNavigate(args)
            case "browser_snapshot":    result = try browserSnapshot(args)
            case "browser_extract":     result = try browserExtract(args)
            case "browser_list_tabs":   result = try browserListTabs(args)
            case "browser_console_logs": result = try browserConsoleLogs(args)
            case "browser_screenshot":  result = try browserScreenshot(args)
            case "browser_tab_open":    result = try browserTabOpen(args)
            case "browser_tab_close":   result = try browserTabClose(args)
            case "browser_tab_switch":  result = try browserTabSwitch(args)
            case "browser_click":       result = try browserClick(args)
            case "browser_type":        result = try browserType(args)
            case "browser_select":      result = try browserSelect(args)
            case "browser_scroll":      result = try browserScroll(args)
            case "browser_wait":        result = try browserWait(args)
            case "browser_press":       result = try browserPress(args)
            case "browser_eval":        result = try browserEval(args)
            case "browser_hover":       result = try browserHover(args)
            case "browser_upload":     result = try browserUpload(args)
            case "browser_drag":       result = try browserDrag(args)
            case "browser_iframe":     result = try browserIframe(args)
            case "browser_clear_session": result = try browserClearSession(args)
            case "browser_get_cookies": result = try browserGetCookies(args)
            case "browser_get_storage": result = try browserGetStorage(args)
            case "browser_set_cookie":  result = try browserSetCookie(args)
            // Git tools
            case "git_status":         result = try gitStatus(args)
            case "git_diff":           result = try gitDiff(args)
            case "git_log":            result = try gitLog(args)
            case "git_stage":          result = try gitStage(args)
            case "git_unstage":        result = try gitUnstage(args)
            case "git_commit":         result = try gitCommit(args)
            case "git_push":           result = try gitPush(args)
            // UI command tools
            case "set_commit_message":  result = try setCommitMessage(args)
            // Network inspection tools
            case "get_network_requests": result = try getNetworkRequests(args)
            case "get_request_detail":   result = try getRequestDetail(args)
            case "clear_network_log":    result = try clearNetworkLog(args)
            // Environment tools
            case "detect_services":    result = try detectServices(args)
            case "list_env_files":     result = try listEnvFiles(args)
            case "get_env_variables":  result = try getEnvVariables(args)
            case "context_search":     result = try contextSearch(args)
            // Smart task tools
            case "get_next_task":      result = try getNextTask(args)
            case "search_tasks":       result = try searchTasks(args)
            case "complete_task":      result = try completeTask(args)
            // Zendesk tools
            case "zendesk_list_tickets":  result = try zendeskListTickets(args)
            case "zendesk_get_ticket":    result = try zendeskGetTicket(args)
            case "zendesk_get_comments":  result = try zendeskGetComments(args)
            case "zendesk_reply":         result = try zendeskReply(args)
            case "zendesk_update_status": result = try zendeskUpdateStatus(args)
            case "zendesk_assign":        result = try zendeskAssign(args)
            case "zendesk_search":        result = try zendeskSearch(args)
            default:
                return errorResponse(id: req.id, code: -32602, message: "Unknown tool: \(toolName)")
            }

            // Enrich responses with active task context footer.
            // Skip for tools that already return task context to avoid redundancy.
            let skipFooterTools: Set<String> = [
                "get_project_context", "list_tasks", "get_task", "create_task",
                "update_task", "add_task_note", "list_task_notes",
                "complete_task", "get_next_task", "search_tasks",
                "set_task_plan", "get_task_plan", "add_task_file",
            ]
            let enrichedResult: String
            if !skipFooterTools.contains(toolName), let footer = activeTaskContextFooter() {
                enrichedResult = result + footer
            } else {
                enrichedResult = result
            }

            return successResponse(id: req.id, result: [
                "content": [["type": "text", "text": enrichedResult]]
            ])
        } catch {
            return successResponse(id: req.id, result: [
                "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                "isError": true
            ])
        }
    }

    // MARK: - Tool Implementations

    func getCurrentProject() throws -> String {
        guard let id = detectedProjectId, let name = detectedProjectName else {
            return "No project detected for working directory: \(workingDirectory)\nUse list_projects to find the correct project_id and pass it explicitly."
        }
        return "Current project: \(name)\nProject ID: \(id)\nWorking directory: \(workingDirectory)\n\nYou can omit project_id from tool calls — it will default to this project."
    }

    func getProjectContext() throws -> String {
        guard let projectId = detectedProjectId, let projectName = detectedProjectName else {
            return "No project detected for working directory: \(workingDirectory)"
        }

        var sections: [String] = []

        // Header
        sections.append("# Project: \(projectName)")
        sections.append("Path: \(workingDirectory)")
        sections.append("")

        // Tech stack detection
        let fm = FileManager.default
        var techStack: [String] = []
        let indicators: [(String, String)] = [
            ("Package.swift", "Swift Package"),
            ("Cargo.toml", "Rust (Cargo)"),
            ("package.json", "Node.js"),
            ("pyproject.toml", "Python"),
            ("requirements.txt", "Python"),
            ("Gemfile", "Ruby"),
            ("go.mod", "Go"),
            ("build.gradle", "Gradle (Java/Kotlin)"),
            ("pom.xml", "Maven (Java)"),
            ("CMakeLists.txt", "C/C++ (CMake)"),
            ("Makefile", "Make"),
            ("docker-compose.yml", "Docker Compose"),
            ("Dockerfile", "Docker"),
            (".flutter", "Flutter"),
            ("pubspec.yaml", "Dart/Flutter"),
        ]
        for (file, stack) in indicators {
            let path = (workingDirectory as NSString).appendingPathComponent(file)
            if fm.fileExists(atPath: path) {
                techStack.append(stack)
            }
        }
        // Check for Xcode projects
        if let contents = try? fm.contentsOfDirectory(atPath: workingDirectory) {
            if contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                techStack.append("Xcode")
            }
        }

        if !techStack.isEmpty {
            sections.append("Stack: \(techStack.joined(separator: ", "))")
        }

        // Git context (branch + recent commits, compact) — uses runGit to avoid shell injection
        let branchResult = runGit(["branch", "--show-current"], at: workingDirectory)
        if let gitBranch = branchResult.output?.trimmingCharacters(in: .whitespacesAndNewlines), !gitBranch.isEmpty {
            sections.append("Branch: \(gitBranch)")
        }
        let logResult = runGit(["log", "--oneline", "-5"], at: workingDirectory)
        if let gitLog = logResult.output?.trimmingCharacters(in: .whitespacesAndNewlines), !gitLog.isEmpty {
            sections.append("Recent commits:\n\(gitLog)")
        }
        sections.append("")

        // Open tasks summary
        let openTasks = try db.read { db in
            try TaskItem.filter(Column("projectId") == projectId)
                .filter(Column("status") != "done")
                .order(Column("priority").desc, Column("createdAt").desc)
                .fetchAll(db)
        }
        if !openTasks.isEmpty {
            let inProgress = openTasks.filter { $0.status == "in_progress" }
            let todo = openTasks.filter { $0.status == "todo" }

            sections.append("## Open Tasks (\(openTasks.count))")

            if !inProgress.isEmpty {
                sections.append("### In Progress")
                for t in inProgress {
                    sections.append("  #\(t.id ?? 0) \(t.title)")
                }
            }
            if !todo.isEmpty {
                sections.append("### Todo (\(todo.count))")
                for t in todo.prefix(3) {
                    sections.append("  #\(t.id ?? 0) \(t.title)")
                }
                if todo.count > 3 {
                    sections.append("  ... and \(todo.count - 3) more")
                }
            }
            sections.append("")
        }

        // Pinned notes (titles only — use get_note for full content)
        let pinnedNotes = try db.read { db in
            try Note.filter(Column("projectId") == projectId)
                .filter(Column("pinned") == true)
                .order(Column("updatedAt").desc)
                .limit(5)
                .fetchAll(db)
        }
        if !pinnedNotes.isEmpty {
            sections.append("## Pinned Notes")
            for n in pinnedNotes {
                sections.append("  📌 \(n.title)")
            }
            sections.append("")
        }

        // Recent notes (titles only)
        let recentNotes = try db.read { db in
            try Note.filter(Column("projectId") == projectId)
                .filter(Column("pinned") == false)
                .order(Column("updatedAt").desc)
                .limit(3)
                .fetchAll(db)
        }
        if !recentNotes.isEmpty {
            sections.append("## Recent Notes")
            for n in recentNotes {
                sections.append("  📝 \(n.title)")
            }
            sections.append("")
        }

        return sections.joined(separator: "\n")
    }

    /// Run a shell command and return stdout.
    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func listProjects() throws -> String {
        let projects = try db.read { db in
            try Project.fetchAll(db)
        }
        var lines = ["Projects (\(projects.count)):"]
        for p in projects {
            lines.append("  [\(p.id)] \(p.name) — \(p.path)")
        }
        return lines.joined(separator: "\n")
    }

    func createProject(_ args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw MCPError(message: "name is required")
        }
        let rawPath = args["path"] as? String ?? ""
        let path = rawPath.isEmpty ? workingDirectory : rawPath

        // Check-and-insert in a single write transaction to prevent TOCTOU race
        let projectId = UUID().uuidString
        let (project, wasExisting) = try db.write { db -> (Project, Bool) in
            if let existing = try Project.filter(Column("path") == path).fetchOne(db) {
                return (existing, true)
            }
            try db.execute(
                sql: "INSERT INTO projects (id, name, path) VALUES (?, ?, ?)",
                arguments: [projectId, name, path]
            )
            guard let created = try Project.filter(Column("id") == projectId).fetchOne(db) else {
                throw MCPError(message: "Failed to create project")
            }
            return (created, false)
        }

        detectedProjectId = project.id
        detectedProjectName = project.name

        if wasExisting {
            return "Project already exists: [\(project.id)] \(project.name) — \(project.path)\nNow using this project for the session."
        } else {
            return "Created project: [\(project.id)] \(project.name) — \(project.path)\nNow using this project for the session. You can create tasks and notes for it."
        }
    }

    func listTasks(_ args: [String: Any]) throws -> String {
        let projectId = try resolveProjectId(args)
        let statusFilter = args["status"] as? String
        let tasks: [TaskItem] = try db.read { db -> [TaskItem] in
            var query = TaskItem.filter(Column("projectId") == projectId)
            if let status = statusFilter {
                query = query.filter(Column("status") == status)
            }
            return try query.order(Column("priority").desc, Column("createdAt").desc).fetchAll(db)
        }

        if tasks.isEmpty {
            return "No tasks found."
        }

        var lines = ["Tasks (\(tasks.count)):"]
        for t in tasks {
            let priority = ["none", "low", "medium", "high", "urgent"][max(min(t.priority, 4), 0)]
            let labels = t.labels.flatMap { l -> String? in
                guard let data = l.data(using: .utf8),
                      let arr = try? JSONDecoder().decode([String].self, from: data)
                else { return nil }
                return arr.joined(separator: ", ")
            }
            var line = "  #\(t.id ?? 0) [\(t.status)] (\(priority)) \(t.title)"
            if let labels { line += " [\(labels)]" }
            lines.append(line)
            if let desc = t.description {
                let preview = desc.prefix(100).replacingOccurrences(of: "\n", with: " ")
                lines.append("    \(preview)\(desc.count > 100 ? "..." : "")")
            }
        }

        // Add smart summary
        let todoCount = tasks.filter { $0.status == "todo" }.count
        let inProgressCount = tasks.filter { $0.status == "in_progress" }.count
        let doneCount = tasks.filter { $0.status == "done" }.count

        var summaryParts: [String] = []
        if todoCount > 0 { summaryParts.append("\(todoCount) todo") }
        if inProgressCount > 0 { summaryParts.append("\(inProgressCount) in progress") }
        if doneCount > 0 { summaryParts.append("\(doneCount) done") }

        if statusFilter == nil && !summaryParts.isEmpty {
            lines.insert("Summary: \(summaryParts.joined(separator: ", "))", at: 1)
        }

        return lines.joined(separator: "\n")
    }

    func getTask(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }

        guard let task = try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        let notes = try db.read { db in
            try TaskNote.filter(Column("taskId") == Int64(taskId))
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }

        var lines = [
            "Task #\(task.id ?? 0): \(task.title)",
            "Status: \(task.status)",
            "Priority: \(["none", "low", "medium", "high", "urgent"][max(min(task.priority, 4), 0)])",
            "Created: \(task.createdAt)",
        ]
        if let completedAt = task.completedAt { lines.append("Completed: \(completedAt)") }
        if let desc = task.description { lines.append("Description:\n\(desc)") }
        if let labels = task.labels { lines.append("Labels: \(labels)") }
        if let summary = task.completionSummary { lines.append("\nCompletion Summary:\n\(summary)") }

        // Show attached files
        let filePaths = parseAttachmentsArray(task.attachments)
        let mdFiles = filePaths.filter { $0.hasSuffix(".md") }
        let imageFiles = filePaths.filter { !$0.hasSuffix(".md") }
        if !mdFiles.isEmpty {
            lines.append("\nAttached Files:")
            for path in mdFiles {
                let name = (path as NSString).lastPathComponent
                lines.append("  📄 \(name)")
                // Show plan content inline
                if name == "PLAN.md", let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    lines.append("\nPlan:\n\(content)")
                }
            }
        }
        if !imageFiles.isEmpty {
            lines.append("\nImages: \(imageFiles.count) attached")
        }

        if !notes.isEmpty {
            lines.append("\nNotes (\(notes.count)):")
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, HH:mm"
            for note in notes {
                lines.append("  [\(formatter.string(from: note.createdAt))] (\(note.source)) \(note.content)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func createTask(_ args: [String: Any]) throws -> String {
        let projectId = try resolveProjectId(args)
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw MCPError(message: "title is required")
        }

        let description = args["description"] as? String
        let priority = args["priority"] as? Int ?? 0

        var labelsJSON: String? = nil
        if let labels = args["labels"] as? [String], !labels.isEmpty {
            if let data = try? JSONEncoder().encode(labels),
               let str = String(data: data, encoding: .utf8) {
                labelsJSON = str
            }
        }

        // Check for similar existing tasks (non-done)
        let existingTasks = try db.read { db in
            try TaskItem.filter(Column("projectId") == projectId)
                .filter(Column("status") != "done")
                .fetchAll(db)
        }

        let force = args["force"] as? Bool ?? false

        var duplicateWarnings: [String] = []
        for existing in existingTasks {
            let jwScore = jaroWinklerSimilarity(title, existing.title)
            let tokenScore = tokenOverlap(title, existing.title)
            if jwScore > 0.85 || tokenScore > 0.7 {
                let matchPct = Int(max(jwScore, tokenScore) * 100)
                duplicateWarnings.append("#\(existing.id ?? 0) \"\(existing.title)\" (\(matchPct)% match, status: \(existing.status))")
            }
        }

        // If duplicates found and not forced, return the best match for easy resumption
        if !duplicateWarnings.isEmpty && !force {
            var result = "Similar task exists: \(duplicateWarnings[0])"
            if duplicateWarnings.count > 1 {
                for w in duplicateWarnings.dropFirst() { result += "\n  Also: \(w)" }
            }
            return result
        }

        let initialStatus = (args["status"] as? String == "in_progress") ? "in_progress" : "todo"

        var task = TaskItem(
            id: nil,
            projectId: projectId,
            title: title,
            description: description,
            status: initialStatus,
            priority: min(max(priority, 0), 4),
            sourceSession: args["session_id"] as? String,
            source: "claude",
            createdAt: Date(),
            completedAt: nil,
            labels: labelsJSON,
            attachments: nil
        )

        try db.write { db in
            try task.insert(db)
        }

        var result = "Created task #\(task.id ?? 0): \(title)"
        if initialStatus == "in_progress" {
            result += " [in_progress]"
        }

        // Surface related project notes so agent has context before starting
        let relatedNotes = try db.read { db in
            try Note.filter(Column("projectId") == projectId)
                .select(Column("id"), Column("title"))
                .fetchAll(db)
        }
        var noteMatches: [(Int64, String, Double)] = []
        for n in relatedNotes {
            let score = tokenOverlap(title, n.title)
            if score > 0.3 {
                noteMatches.append((n.id ?? 0, n.title, score))
            }
        }
        noteMatches.sort { $0.2 > $1.2 }
        if !noteMatches.isEmpty {
            result += "\n\nRelated project notes:"
            for m in noteMatches.prefix(3) {
                result += "\n  📝 #\(m.0) \(m.1)"
            }
            result += "\nUse get_note to review relevant context before starting work."
        }

        return result
    }

    func updateTask(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }

        guard var task = try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        var changes: [String] = []

        if let status = args["status"] as? String {
            task.status = status
            if status == "done" { task.completedAt = Date() }
            else { task.completedAt = nil }
            changes.append("status → \(status)")
        }
        if let priority = args["priority"] as? Int {
            task.priority = min(max(priority, 0), 4)
            changes.append("priority → \(priority)")
        }
        if let title = args["title"] as? String {
            task.title = title
            changes.append("title updated")
        }
        if let desc = args["description"] as? String {
            task.description = desc
            changes.append("description updated")
        }
        if let labels = args["labels"] as? [String] {
            if labels.isEmpty {
                task.labels = nil
            } else if let data = try? JSONEncoder().encode(labels),
                      let str = String(data: data, encoding: .utf8) {
                task.labels = str
            }
            changes.append("labels → \(labels.joined(separator: ", "))")
        }

        if changes.isEmpty {
            return "No changes specified for task #\(taskId)"
        }

        try db.write { db in
            try task.update(db)
        }

        return "Updated task #\(taskId): \(changes.joined(separator: ", "))"
    }

    func addTaskNote(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }
        guard let content = args["content"] as? String, !content.isEmpty else {
            throw MCPError(message: "content is required")
        }

        // Verify task exists
        guard try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) != nil else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        let sessionId = args["session_id"] as? String

        var note = TaskNote(
            id: nil,
            taskId: Int64(taskId),
            content: content,
            source: "claude",
            sessionId: sessionId,
            createdAt: Date()
        )

        try db.write { db in
            try note.insert(db)
        }

        return "Added note to task #\(taskId)"
    }

    func listTaskNotes(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }

        let notes = try db.read { db in
            try TaskNote.filter(Column("taskId") == Int64(taskId))
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }

        if notes.isEmpty {
            return "No notes for task #\(taskId)"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        var lines = ["Notes for task #\(taskId) (\(notes.count)):"]
        for note in notes {
            lines.append("  [\(formatter.string(from: note.createdAt))] (\(note.source)) \(note.content)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Task Plans

    /// Directory for task file attachments.
    private func taskFilesDir(taskId: Int) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Workspace/task-files/\(taskId)", isDirectory: true)
    }

    func setTaskPlan(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }
        guard let plan = args["plan"] as? String, !plan.isEmpty else {
            throw MCPError(message: "plan is required")
        }

        guard var task = try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        // Save plan as a markdown file
        let dir = taskFilesDir(taskId: taskId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent("PLAN.md")
        try plan.write(to: filePath, atomically: true, encoding: .utf8)

        // Add to attachments array (replace existing PLAN.md if present)
        var paths = parseAttachmentsArray(task.attachments)
        paths.removeAll { ($0 as NSString).lastPathComponent == "PLAN.md" }
        paths.append(filePath.path)
        task.attachments = encodeAttachmentsArray(paths)

        try db.write { db in
            try task.update(db)
        }

        return "Plan saved to task #\(taskId) (\(plan.count) chars) at \(filePath.path)"
    }

    func getTaskPlan(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }

        guard let task = try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        let paths = parseAttachmentsArray(task.attachments)
        if let planPath = paths.first(where: { ($0 as NSString).lastPathComponent == "PLAN.md" }),
           let content = try? String(contentsOfFile: planPath, encoding: .utf8) {
            return "Plan for task #\(taskId):\n\n\(content)"
        }

        return "No plan attached to task #\(taskId)"
    }

    func addTaskFile(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }
        guard let filename = args["filename"] as? String, !filename.isEmpty else {
            throw MCPError(message: "filename is required")
        }
        guard let content = args["content"] as? String, !content.isEmpty else {
            throw MCPError(message: "content is required")
        }

        guard var task = try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        // Sanitize filename: take only the last component and strip unsafe characters
        let baseName = (filename as NSString).lastPathComponent
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let safeName = String(baseName.unicodeScalars.filter { allowedChars.contains($0) })
        guard !safeName.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else {
            throw MCPError(message: "filename contains no valid characters")
        }
        let finalName = safeName.hasSuffix(".md") ? safeName : safeName + ".md"

        let dir = taskFilesDir(taskId: taskId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent(finalName)
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        // Add to attachments array (replace existing file with same name)
        var paths = parseAttachmentsArray(task.attachments)
        paths.removeAll { ($0 as NSString).lastPathComponent == finalName }
        paths.append(filePath.path)
        task.attachments = encodeAttachmentsArray(paths)

        try db.write { db in
            try task.update(db)
        }

        return "File '\(finalName)' attached to task #\(taskId) (\(content.count) chars)"
    }

    // MARK: - Smart Task Implementations

    func getNextTask(_ args: [String: Any]) throws -> String {
        let projectId = try resolveProjectId(args)

        // Get non-done tasks ordered by priority desc, then oldest first
        let allTasks = try db.read { db in
            try TaskItem.filter(Column("projectId") == projectId)
                .filter(Column("status") != "done")
                .order(Column("priority").desc, Column("createdAt").asc)
                .fetchAll(db)
        }

        // Filter out blocked tasks (tasks whose blockedBy dependencies aren't all done)
        let doneTaskIds = try db.read { db in
            try Int64.fetchAll(db, TaskItem
                .select(Column("id"))
                .filter(Column("projectId") == projectId)
                .filter(Column("status") == "done"))
        }
        let doneSet = Set(doneTaskIds)

        let tasks = allTasks.filter { task in
            guard let json = task.blockedBy,
                  let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([Int64].self, from: data),
                  !ids.isEmpty
            else { return true } // not blocked
            return ids.allSatisfy { doneSet.contains($0) } // all blockers are done
        }

        guard let next = tasks.first else {
            if !allTasks.isEmpty {
                return "All \(allTasks.count) open task(s) are blocked by incomplete dependencies.\nUse list_tasks to see what's blocking them."
            }
            return "No actionable tasks found. All tasks are done or none exist.\nUse create_task to add new work."
        }

        let nextId = next.id ?? 0

        // Get notes for context
        let notes = try db.read { db in
            try TaskNote.filter(Column("taskId") == Int64(nextId))
                .order(Column("createdAt").desc)
                .limit(3)
                .fetchAll(db)
        }

        // Check for plan file
        let taskFilesDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Workspace/task-files/\(nextId)")
        let planPath = taskFilesDir.appendingPathComponent("PLAN.md")
        let hasPlan = FileManager.default.fileExists(atPath: planPath.path)

        var lines = [
            "## Next Task: #\(nextId)",
            "**\(next.title)**",
            "Priority: \(["none", "low", "medium", "high", "urgent"][max(min(next.priority, 4), 0)])",
            "Status: \(next.status)",
        ]
        if let desc = next.description { lines.append("\nDescription:\n\(desc)") }
        if let labels = next.labels { lines.append("Labels: \(labels)") }

        if hasPlan {
            lines.append("\n📋 This task has an execution plan. Call get_task_plan(\(nextId)) to review it.")
        }

        if !notes.isEmpty {
            lines.append("\nRecent notes:")
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, HH:mm"
            for note in notes {
                lines.append("  [\(formatter.string(from: note.createdAt))] \(note.content.prefix(200))")
            }
        }

        // Summary of other open tasks
        let otherCount = tasks.count - 1
        if otherCount > 0 {
            lines.append("\n(\(otherCount) other open task\(otherCount == 1 ? "" : "s") in queue)")
        }

        lines.append("\n→ Call update_task(\(nextId), status: \"in_progress\") to start working on this task.")

        return lines.joined(separator: "\n")
    }

    func searchTasks(_ args: [String: Any]) throws -> String {
        let projectId = try resolveProjectId(args)
        guard let query = args["query"] as? String, !query.isEmpty else {
            throw MCPError(message: "query is required")
        }
        let includeDone = args["include_done"] as? Bool ?? false

        let allTasks = try db.read { db in
            var request = TaskItem.filter(Column("projectId") == projectId)
            if !includeDone {
                request = request.filter(Column("status") != "done")
            }
            return try request.order(Column("priority").desc).fetchAll(db)
        }

        // Score each task by similarity to query
        var scored: [(task: TaskItem, score: Double)] = []
        for task in allTasks {
            let titleScore = max(jaroWinklerSimilarity(query, task.title), tokenOverlap(query, task.title))
            var descScore: Double = 0
            if let desc = task.description {
                descScore = tokenOverlap(query, desc) * 0.7 // Description match weighted less
            }
            let score = max(titleScore, descScore)
            if score > 0.3 { // Minimum relevance threshold
                scored.append((task, score))
            }
        }

        scored.sort { $0.score > $1.score }
        let results = scored.prefix(10)

        if results.isEmpty {
            return "No tasks matching '\(query)' found."
        }

        var lines = ["Search results for '\(query)' (\(results.count) match\(results.count == 1 ? "" : "es")):"]
        for (task, score) in results {
            let pct = Int(score * 100)
            lines.append("  #\(task.id ?? 0) [\(task.status)] \(task.title) (\(pct)% relevance)")
            if let desc = task.description {
                lines.append("    \(desc.prefix(80).replacingOccurrences(of: "\n", with: " "))\(desc.count > 80 ? "..." : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    func completeTask(_ args: [String: Any]) throws -> String {
        guard let taskId = args["task_id"] as? Int ?? (args["task_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "task_id is required")
        }

        guard var task = try db.read({ db in
            try TaskItem.fetchOne(db, key: Int64(taskId))
        }) else {
            throw MCPError(message: "Task #\(taskId) not found")
        }

        let summary = args["summary"] as? String
        task.status = "done"
        task.completedAt = Date()
        if let summary = summary, !summary.isEmpty {
            task.completionSummary = summary
        }

        try db.write { db in
            try task.update(db)
        }

        // Also add completion summary as a system note for timeline visibility
        if let summary = summary, !summary.isEmpty {
            var note = TaskNote(
                id: nil,
                taskId: Int64(taskId),
                content: "Completed: \(summary)",
                source: "system",
                sessionId: nil,
                createdAt: Date()
            )
            try db.write { db in
                try note.insert(db)
            }
        }

        // Check task richness — nudge if sparse
        let noteCount = try db.read { db in
            try TaskNote.filter(Column("taskId") == Int64(taskId)).fetchCount(db)
        }
        let taskFilesDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Workspace/task-files/\(taskId)")
        let fileCount = (try? FileManager.default.contentsOfDirectory(atPath: taskFilesDir.path).count) ?? 0

        var result = "Task #\(taskId) completed: \(task.title)"

        // Specific nudges based on what's missing
        var nudges: [String] = []
        if noteCount <= 1 { // 1 because the completion note itself was just added
            nudges.append("This task has no progress notes. Next time, use add_task_note after each step so context survives across sessions.")
        }
        if fileCount == 0 {
            nudges.append("No files were attached. If you produced any analysis, reviews, or reports during this task, attach them now with add_task_file before moving on.")
        }
        nudges.append("If you discovered reusable knowledge (patterns, conventions, gotchas), capture it with create_note.")

        result += "\n\n" + nudges.joined(separator: "\n")
        return result
    }

    // MARK: - Attachments Array Helpers

    private func parseAttachmentsArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }

    private func encodeAttachmentsArray(_ paths: [String]) -> String? {
        guard !paths.isEmpty,
              let data = try? JSONEncoder().encode(paths),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - Project Notes

    func listNotes(_ args: [String: Any]) throws -> String {
        let isGlobal = args["global"] as? Bool ?? false

        let notes: [Note]
        if isGlobal {
            let pinnedOnly = args["pinned_only"] as? Bool ?? false
            notes = try db.read { db -> [Note] in
                var query = Note.filter(Column("isGlobal") == true)
                if pinnedOnly {
                    query = query.filter(Column("pinned") == true)
                }
                return try query.order(Column("pinned").desc, Column("updatedAt").desc).fetchAll(db)
            }
        } else {
            let projectId = try resolveProjectId(args)
            let pinnedOnly = args["pinned_only"] as? Bool ?? false
            notes = try db.read { db -> [Note] in
                var query = Note.filter(Column("projectId") == projectId)
                if pinnedOnly {
                    query = query.filter(Column("pinned") == true)
                }
                return try query.order(Column("pinned").desc, Column("updatedAt").desc).fetchAll(db)
            }
        }

        if notes.isEmpty {
            return "No notes found."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        var lines = ["Notes (\(notes.count)):"]
        for note in notes {
            let pin = note.pinned ? " [pinned]" : ""
            let preview = note.content.prefix(80).replacingOccurrences(of: "\n", with: " ")
            lines.append("  #\(note.id ?? 0)\(pin) \(note.title)")
            lines.append("    Updated: \(formatter.string(from: note.updatedAt))")
            if !preview.isEmpty {
                lines.append("    \(preview)\(note.content.count > 80 ? "..." : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    func getNote(_ args: [String: Any]) throws -> String {
        guard let noteId = args["note_id"] as? Int ?? (args["note_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "note_id is required")
        }

        guard let note = try db.read({ db in
            try Note.fetchOne(db, key: Int64(noteId))
        }) else {
            throw MCPError(message: "Note #\(noteId) not found")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [
            "Note #\(note.id ?? 0): \(note.title)",
            "Pinned: \(note.pinned ? "yes" : "no")",
            "Created: \(formatter.string(from: note.createdAt))",
            "Updated: \(formatter.string(from: note.updatedAt))",
        ]
        if let sid = note.sessionId { lines.append("Session: \(sid)") }
        lines.append("\n\(note.content)")
        return lines.joined(separator: "\n")
    }

    func createNote(_ args: [String: Any]) throws -> String {
        let isGlobal = args["global"] as? Bool ?? false
        let projectId: String
        if isGlobal {
            projectId = "__global__"
        } else {
            projectId = try resolveProjectId(args)
        }
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw MCPError(message: "title is required")
        }

        let content = args["content"] as? String ?? ""
        let pinned = args["pinned"] as? Bool ?? false
        let sessionId = args["session_id"] as? String
        let force = args["force"] as? Bool ?? false
        let now = Date()

        // Check for similar existing notes — block creation unless force=true
        if !force {
            var similarNotes: [String] = []
            let existingNotes = try db.read { db in
                try Note.filter(Column("projectId") == projectId)
                    .fetchAll(db)
            }
            for existing in existingNotes {
                let jwScore = jaroWinklerSimilarity(title, existing.title)
                let tokenScore = tokenOverlap(title, existing.title)
                if jwScore > 0.7 || tokenScore > 0.6 {
                    let matchPct = Int(max(jwScore, tokenScore) * 100)
                    similarNotes.append("#\(existing.id ?? 0) \"\(existing.title)\" (\(matchPct)% similar)")
                }
            }
            if !similarNotes.isEmpty {
                var result = "Similar notes already exist — update instead of creating a duplicate:\n"
                for s in similarNotes { result += "  \(s)\n" }
                result += "Use update_note to merge content, or pass force=true to create anyway."
                return result
            }
        }

        var note = Note(
            id: nil,
            projectId: projectId,
            title: title,
            content: content,
            pinned: pinned,
            sessionId: sessionId,
            createdAt: now,
            updatedAt: now,
            isGlobal: isGlobal
        )

        try db.write { db in
            try note.insert(db)
        }

        return "Created note #\(note.id ?? 0): \(title)"
    }

    func updateNote(_ args: [String: Any]) throws -> String {
        guard let noteId = args["note_id"] as? Int ?? (args["note_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "note_id is required")
        }

        guard var note = try db.read({ db in
            try Note.fetchOne(db, key: Int64(noteId))
        }) else {
            throw MCPError(message: "Note #\(noteId) not found")
        }

        var changes: [String] = []

        if let title = args["title"] as? String {
            note.title = title
            changes.append("title updated")
        }
        if let content = args["content"] as? String {
            note.content = content
            changes.append("content updated")
        }
        if let pinned = args["pinned"] as? Bool {
            note.pinned = pinned
            changes.append(pinned ? "pinned" : "unpinned")
        }

        if changes.isEmpty {
            return "No changes specified for note #\(noteId)"
        }

        note.updatedAt = Date()

        try db.write { db in
            try note.update(db)
        }

        return "Updated note #\(noteId): \(changes.joined(separator: ", "))"
    }

    func deleteNote(_ args: [String: Any]) throws -> String {
        guard let noteId = args["note_id"] as? Int ?? (args["note_id"] as? Int64).map(Int.init) else {
            throw MCPError(message: "note_id is required")
        }

        let deleted = try db.write { db in
            try Note.deleteOne(db, key: Int64(noteId))
        }

        if deleted {
            return "Deleted note #\(noteId)"
        } else {
            throw MCPError(message: "Note #\(noteId) not found")
        }
    }

    func searchNotes(_ args: [String: Any]) throws -> String {
        let isGlobal = args["global"] as? Bool ?? false

        guard let query = args["query"] as? String, !query.isEmpty else {
            throw MCPError(message: "query is required")
        }

        // Escape FTS5 special characters by quoting the query
        let escapedQuery = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""

        let notes: [Note]
        if isGlobal {
            notes = try db.read { db in
                let sql = """
                    SELECT notes.* FROM notes
                    JOIN notesFts ON notesFts.rowid = notes.id
                    WHERE notes.isGlobal = 1
                    AND notesFts MATCH ?
                    ORDER BY notes.updatedAt DESC
                    """
                return try Note.fetchAll(db, sql: sql, arguments: [escapedQuery])
            }
        } else {
            let projectId = try resolveProjectId(args)
            // Use FTS5 search via raw SQL joining notesFts virtual table
            notes = try db.read { db in
                let sql = """
                    SELECT notes.* FROM notes
                    JOIN notesFts ON notesFts.rowid = notes.id
                    WHERE notes.projectId = ?
                    AND notesFts MATCH ?
                    ORDER BY notes.updatedAt DESC
                    """
                return try Note.fetchAll(db, sql: sql, arguments: [projectId, escapedQuery])
            }
        }

        if notes.isEmpty {
            return "No notes matching '\(query)'"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        var lines = ["Search results for '\(query)' (\(notes.count)):"]
        for note in notes {
            let pin = note.pinned ? " [pinned]" : ""
            let preview = note.content.prefix(100).replacingOccurrences(of: "\n", with: " ")
            lines.append("  #\(note.id ?? 0)\(pin) \(note.title)")
            if !preview.isEmpty {
                lines.append("    \(preview)\(note.content.count > 100 ? "..." : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

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

    // MARK: - Client Handlers

    func listClients() throws -> String {
        let clients = try db.read { db in
            try Client.order(Column("sortOrder").asc, Column("name").asc).fetchAll(db)
        }
        if clients.isEmpty {
            return "No clients found. Use create_client to add one."
        }
        var lines = ["Clients (\(clients.count)):"]
        for c in clients {
            lines.append("  [\(c.id)] \(c.name) (color: \(c.color))")
        }
        return lines.joined(separator: "\n")
    }

    func createClient(_ args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw MCPError(message: "name is required")
        }
        let color = args["color"] as? String ?? "#3B82F6"

        let existingCount = try db.read { db in
            try Client.fetchCount(db)
        }

        var client = Client(
            id: UUID().uuidString,
            name: name,
            color: color,
            sortOrder: existingCount,
            createdAt: Date()
        )

        try db.write { db in
            try client.insert(db)
        }

        return "Created client '\(name)' with ID \(client.id)"
    }

    // MARK: - Browser Tool Handlers

    func browserNavigate(_ args: [String: Any]) throws -> String {
        guard let url = args["url"] as? String, !url.isEmpty else {
            throw MCPError(message: "url is required")
        }
        return try executeBrowserCommand(tool: "browser_navigate", args: ["url": url], timeout: 15.0)
    }

    func browserSnapshot(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        if let maxSize = args["max_size"] as? Int { cmdArgs["max_size"] = maxSize }
        return try executeBrowserCommand(tool: "browser_snapshot", args: cmdArgs, timeout: 10.0)
    }

    func browserExtract(_ args: [String: Any]) throws -> String {
        guard let selector = args["selector"] as? String, !selector.isEmpty else {
            throw MCPError(message: "selector is required")
        }
        var cmdArgs: [String: Any] = ["selector": selector]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_extract", args: cmdArgs)
    }

    func browserListTabs(_ args: [String: Any]) throws -> String {
        return try executeBrowserCommand(tool: "browser_list_tabs")
    }

    func browserConsoleLogs(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        if let level = args["level"] as? String { cmdArgs["level"] = level }
        return try executeBrowserCommand(tool: "browser_console_logs", args: cmdArgs)
    }

    func browserScreenshot(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_screenshot", args: cmdArgs, timeout: 10.0)
    }

    func browserTabOpen(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let url = args["url"] as? String { cmdArgs["url"] = url }
        return try executeBrowserCommand(tool: "browser_tab_open", args: cmdArgs, timeout: 15.0)
    }

    func browserTabClose(_ args: [String: Any]) throws -> String {
        guard let tabId = args["tab_id"] as? String, !tabId.isEmpty else {
            throw MCPError(message: "tab_id is required")
        }
        return try executeBrowserCommand(tool: "browser_tab_close", args: ["tab_id": tabId])
    }

    func browserTabSwitch(_ args: [String: Any]) throws -> String {
        guard let tabId = args["tab_id"] as? String, !tabId.isEmpty else {
            throw MCPError(message: "tab_id is required")
        }
        return try executeBrowserCommand(tool: "browser_tab_switch", args: ["tab_id": tabId])
    }

    // MARK: - Phase 2: Interaction Tools

    func browserClick(_ args: [String: Any]) throws -> String {
        guard let ref = args["ref"] as? String, !ref.isEmpty else {
            throw MCPError(message: "ref is required")
        }
        var cmdArgs: [String: Any] = ["ref": ref]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_click", args: cmdArgs)
    }

    func browserType(_ args: [String: Any]) throws -> String {
        guard let ref = args["ref"] as? String, !ref.isEmpty else {
            throw MCPError(message: "ref is required")
        }
        guard let text = args["text"] as? String else {
            throw MCPError(message: "text is required")
        }
        var cmdArgs: [String: Any] = ["ref": ref, "text": text]
        if let clear = args["clear"] as? Bool { cmdArgs["clear"] = clear }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_type", args: cmdArgs)
    }

    func browserSelect(_ args: [String: Any]) throws -> String {
        guard let ref = args["ref"] as? String, !ref.isEmpty else {
            throw MCPError(message: "ref is required")
        }
        let value = args["value"] as? String
        let label = args["label"] as? String
        guard value != nil || label != nil else {
            throw MCPError(message: "value or label is required")
        }
        var cmdArgs: [String: Any] = ["ref": ref]
        if let v = value { cmdArgs["value"] = v }
        if let l = label { cmdArgs["label"] = l }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_select", args: cmdArgs)
    }

    func browserScroll(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let ref = args["ref"] as? String { cmdArgs["ref"] = ref }
        if let direction = args["direction"] as? String { cmdArgs["direction"] = direction }
        if let amount = args["amount"] as? Int { cmdArgs["amount"] = amount }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_scroll", args: cmdArgs)
    }

    func browserWait(_ args: [String: Any]) throws -> String {
        let ref = args["ref"] as? String
        let selector = args["selector"] as? String
        guard ref != nil || selector != nil else {
            throw MCPError(message: "ref or selector is required")
        }
        var cmdArgs: [String: Any] = [:]
        if let r = ref { cmdArgs["ref"] = r }
        if let s = selector { cmdArgs["selector"] = s }
        let timeout = args["timeout"] as? Int ?? 5
        cmdArgs["timeout"] = timeout
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        let swiftTimeout = TimeInterval(min(timeout, 15)) + 3.0
        return try executeBrowserCommand(tool: "browser_wait", args: cmdArgs, timeout: swiftTimeout)
    }

    // MARK: - Phase 3: JS Execution, Keyboard, Hover

    func browserPress(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, !key.isEmpty else {
            throw MCPError(message: "key is required")
        }
        var cmdArgs: [String: Any] = ["key": key]
        if let ref = args["ref"] as? String { cmdArgs["ref"] = ref }
        if let modifiers = args["modifiers"] as? [Any] {
            cmdArgs["modifiers"] = modifiers
        }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_press", args: cmdArgs)
    }

    func browserEval(_ args: [String: Any]) throws -> String {
        guard let expression = args["expression"] as? String, !expression.isEmpty else {
            throw MCPError(message: "expression is required")
        }
        var cmdArgs: [String: Any] = ["expression": expression]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_eval", args: cmdArgs, timeout: 10.0)
    }

    func browserHover(_ args: [String: Any]) throws -> String {
        guard let ref = args["ref"] as? String, !ref.isEmpty else {
            throw MCPError(message: "ref is required")
        }
        var cmdArgs: [String: Any] = ["ref": ref]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_hover", args: cmdArgs)
    }

    // MARK: - Phase 4: Upload, Drag, Iframe, Session

    func browserUpload(_ args: [String: Any]) throws -> String {
        guard let ref = args["ref"] as? String, !ref.isEmpty else {
            throw MCPError(message: "ref is required")
        }
        guard let path = args["path"] as? String, !path.isEmpty else {
            throw MCPError(message: "path is required")
        }
        var cmdArgs: [String: Any] = ["ref": ref, "path": path]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_upload", args: cmdArgs, timeout: 10.0)
    }

    func browserDrag(_ args: [String: Any]) throws -> String {
        guard let fromRef = args["from_ref"] as? String, !fromRef.isEmpty else {
            throw MCPError(message: "from_ref is required")
        }
        guard let toRef = args["to_ref"] as? String, !toRef.isEmpty else {
            throw MCPError(message: "to_ref is required")
        }
        var cmdArgs: [String: Any] = ["from_ref": fromRef, "to_ref": toRef]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_drag", args: cmdArgs)
    }

    func browserIframe(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let ref = args["ref"] as? String { cmdArgs["ref"] = ref }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_iframe", args: cmdArgs)
    }

    func browserClearSession(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let types = args["types"] as? [String] { cmdArgs["types"] = types }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_clear_session", args: cmdArgs, timeout: 10.0)
    }

    func browserGetCookies(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let domain = args["domain"] as? String { cmdArgs["domain"] = domain }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_get_cookies", args: cmdArgs)
    }

    func browserGetStorage(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        cmdArgs["type"] = args["type"] as? String ?? "localStorage"
        if let prefix = args["prefix"] as? String { cmdArgs["prefix"] = prefix }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_get_storage", args: cmdArgs)
    }

    func browserSetCookie(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        cmdArgs["name"] = args["name"]
        cmdArgs["value"] = args["value"]
        if let domain = args["domain"] as? String { cmdArgs["domain"] = domain }
        if let path = args["path"] as? String { cmdArgs["path"] = path }
        if let maxAge = args["max_age"] as? Int { cmdArgs["max_age"] = maxAge }
        if let secure = args["secure"] as? Bool { cmdArgs["secure"] = secure }
        if let sameSite = args["same_site"] as? String { cmdArgs["same_site"] = sameSite }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "browser_set_cookie", args: cmdArgs)
    }

    // MARK: - Git Tool Implementations

    /// Resolve project path from args or auto-detected project.
    func resolveProjectPath(_ args: [String: Any]) throws -> String {
        let projectId = try resolveProjectId(args)
        guard let path = try db.read({ conn in
            try String.fetchOne(conn, sql: "SELECT path FROM projects WHERE id = ?", arguments: [projectId])
        }) else {
            throw MCPError(message: "Could not resolve project path for project \(projectId)")
        }
        return path
    }

    /// Run a git command and return (output, exitCode).
    func runGit(_ arguments: [String], at path: String) -> (output: String?, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return (output, process.terminationStatus)
        } catch {
            return (nil, -1)
        }
    }

    func gitStatus(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)

        // Get branch
        let branchResult = runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: path)
        let branch = branchResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

        // Get status
        let statusResult = runGit(["status", "--porcelain"], at: path)
        guard statusResult.exitCode == 0 else {
            throw MCPError(message: "Not a git repository or git not available at \(path)")
        }

        var staged: [[String: String]] = []
        var unstaged: [[String: String]] = []
        var untracked: [[String: String]] = []

        let lines = (statusResult.output ?? "").components(separatedBy: "\n")
        for line in lines {
            guard line.count >= 3 else { continue }
            let indexChar = line[line.startIndex]
            let workTreeChar = line[line.index(after: line.startIndex)]
            let filePath = String(line.dropFirst(3))

            if indexChar == "?" && workTreeChar == "?" {
                untracked.append(["status": "?", "path": filePath])
                continue
            }
            if indexChar != " " && indexChar != "?" {
                staged.append(["status": String(indexChar), "path": filePath])
            }
            if workTreeChar != " " && workTreeChar != "?" {
                unstaged.append(["status": String(workTreeChar), "path": filePath])
            }
        }

        let result: [String: Any] = [
            "branch": branch,
            "staged": staged,
            "unstaged": unstaged,
            "untracked": untracked,
            "staged_count": staged.count,
            "unstaged_count": unstaged.count,
            "untracked_count": untracked.count,
            "clean": staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
        ]

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Branch: \(branch), \(staged.count) staged, \(unstaged.count) unstaged, \(untracked.count) untracked"
    }

    func gitDiff(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        var gitArgs = ["diff", "--no-color"]
        if args["staged"] as? Bool == true {
            gitArgs.append("--staged")
        }
        if let filePath = args["file_path"] as? String {
            gitArgs.append(contentsOf: ["--", filePath])
        }

        let result = runGit(gitArgs, at: path)
        guard result.exitCode == 0 else {
            throw MCPError(message: "git diff failed")
        }

        let output = result.output ?? ""
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = args["staged"] as? Bool == true ? "staged" : "unstaged"
            return "No \(target) changes" + (args["file_path"] != nil ? " for \(args["file_path"] as! String)" : "")
        }
        return output
    }

    func gitLog(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        let count = min(args["count"] as? Int ?? 15, 50)
        var gitArgs = ["log", "--format=%H\u{1F}%h\u{1F}%s\u{1F}%an\u{1F}%ar", "-\(count)"]
        if let filePath = args["file_path"] as? String {
            gitArgs.append(contentsOf: ["--", filePath])
        }

        let result = runGit(gitArgs, at: path)
        guard result.exitCode == 0 else {
            throw MCPError(message: "git log failed (is this a git repository?)")
        }

        var commits: [[String: String]] = []
        let lines = (result.output ?? "").components(separatedBy: "\n")
        for line in lines {
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 5 else { continue }
            commits.append([
                "sha": parts[0],
                "short_sha": parts[1],
                "message": parts[2],
                "author": parts[3],
                "date": parts[4]
            ])
        }

        if let data = try? JSONSerialization.data(withJSONObject: ["commits": commits, "count": commits.count], options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return result.output ?? ""
    }

    func gitStage(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        var gitArgs: [String]
        if let filePath = args["file_path"] as? String {
            gitArgs = ["add", "--", filePath]
        } else {
            gitArgs = ["add", "-A"]
        }

        let result = runGit(gitArgs, at: path)
        guard result.exitCode == 0 else {
            throw MCPError(message: "git stage failed: \(result.output ?? "unknown error")")
        }

        let target = (args["file_path"] as? String) ?? "all changes"
        return "Staged: \(target)"
    }

    func gitUnstage(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        var gitArgs: [String]
        if let filePath = args["file_path"] as? String {
            gitArgs = ["restore", "--staged", "--", filePath]
        } else {
            gitArgs = ["restore", "--staged", "."]
        }

        let result = runGit(gitArgs, at: path)
        guard result.exitCode == 0 else {
            throw MCPError(message: "git unstage failed: \(result.output ?? "unknown error")")
        }

        let target = (args["file_path"] as? String) ?? "all staged changes"
        return "Unstaged: \(target)"
    }

    func gitCommit(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        guard let message = args["message"] as? String, !message.isEmpty else {
            throw MCPError(message: "Commit message is required")
        }

        let result = runGit(["commit", "-m", message], at: path)
        guard result.exitCode == 0 else {
            throw MCPError(message: "git commit failed: \(result.output ?? "nothing to commit?")")
        }

        var output = result.output ?? "Committed successfully"
        // Nudge agent to log the commit as a task note
        output += "\n\nLog this commit as a task note with add_task_note so it's captured in the task timeline."
        return output
    }

    func gitPush(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        let remote = args["remote"] as? String ?? "origin"
        let setUpstream = args["set_upstream"] as? Bool ?? false

        var gitArgs = ["push"]
        if setUpstream {
            gitArgs.append("-u")
        }
        gitArgs.append(remote)

        if let branch = args["branch"] as? String {
            gitArgs.append(branch)
        }

        let result = runGit(gitArgs, at: path)
        guard result.exitCode == 0 else {
            throw MCPError(message: "git push failed: \(result.output ?? "unknown error")")
        }

        return result.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? result.output!
            : "Pushed successfully"
    }

    // MARK: - UI Command Tool Implementations

    func setCommitMessage(_ args: [String: Any]) throws -> String {
        guard let message = args["message"] as? String, !message.isEmpty else {
            throw MCPError(message: "message is required")
        }

        let projectId = try? resolveProjectId(args)

        let argsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: ["message": message]),
           let str = String(data: data, encoding: .utf8) {
            argsJSON = str
        } else {
            throw MCPError(message: "Failed to encode message")
        }

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO uiCommands (command, args, projectId, status, createdAt)
                    VALUES (?, ?, ?, 'pending', ?)
                """,
                arguments: ["set_commit_message", argsJSON, projectId, Date()]
            )
        }

        return "Commit message set in the UI. The user can review and edit it before committing."
    }

    // MARK: - Network Inspection Tool Implementations

    func getNetworkRequests(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let domain = args["domain"] as? String { cmdArgs["domain"] = domain }
        if let statusClass = args["status_class"] as? String { cmdArgs["status_class"] = statusClass }
        if let limit = args["limit"] as? Int { cmdArgs["limit"] = limit }
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "get_network_requests", args: cmdArgs)
    }

    func getRequestDetail(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        guard let requestId = args["request_id"] as? String else {
            throw MCPError(message: "request_id is required")
        }
        cmdArgs["request_id"] = requestId
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "get_request_detail", args: cmdArgs)
    }

    func clearNetworkLog(_ args: [String: Any]) throws -> String {
        var cmdArgs: [String: Any] = [:]
        if let tabId = args["tab_id"] as? String { cmdArgs["tab_id"] = tabId }
        return try executeBrowserCommand(tool: "clear_network_log", args: cmdArgs)
    }

    // MARK: - Environment Tool Implementations

    func detectServices(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        let fm = FileManager.default

        var services: [[String: Any]] = []

        // Service detection config: (type, config files, dashboard URL pattern)
        let checks: [(String, [String], String?)] = [
            ("Firebase", ["firebase.json", ".firebaserc"], "https://console.firebase.google.com"),
            ("Supabase", ["supabase/config.toml"], "https://supabase.com/dashboard"),
            ("Vercel", ["vercel.json", ".vercel/project.json"], "https://vercel.com/dashboard"),
            ("Netlify", ["netlify.toml"], "https://app.netlify.com"),
            ("Docker", ["docker-compose.yml", "docker-compose.yaml", "Dockerfile"], nil),
            ("Railway", ["railway.toml", "railway.json"], "https://railway.app/dashboard"),
        ]

        for (serviceName, configFiles, dashboardURL) in checks {
            for configFile in configFiles {
                let fullPath = (path as NSString).appendingPathComponent(configFile)
                if fm.fileExists(atPath: fullPath) {
                    var entry: [String: Any] = [
                        "service": serviceName,
                        "config_file": configFile
                    ]
                    if let url = dashboardURL { entry["dashboard_url"] = url }
                    services.append(entry)
                    break // Only add each service type once
                }
            }
        }

        // Check for amplify directory
        let amplifyDir = (path as NSString).appendingPathComponent("amplify")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: amplifyDir, isDirectory: &isDir), isDir.boolValue {
            services.append([
                "service": "AWS Amplify",
                "config_file": "amplify/",
                "dashboard_url": "https://console.aws.amazon.com/amplify"
            ])
        }

        if let data = try? JSONSerialization.data(withJSONObject: ["services": services, "count": services.count], options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Found \(services.count) services"
    }

    func listEnvFiles(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        let fm = FileManager.default
        let envFileNames = [".env", ".env.local", ".env.development", ".env.staging", ".env.production", ".env.example", ".env.template", ".env.sample"]

        var files: [[String: Any]] = []
        for name in envFileNames {
            let fullPath = (path as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: fullPath),
                  let contents = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

            let varCount = contents.components(separatedBy: .newlines)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed.contains("=")
                }.count

            files.append([
                "name": name,
                "variable_count": varCount
            ])
        }

        if let data = try? JSONSerialization.data(withJSONObject: ["files": files, "count": files.count], options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Found \(files.count) env files"
    }

    func getEnvVariables(_ args: [String: Any]) throws -> String {
        let path = try resolveProjectPath(args)
        guard let fileName = args["file_name"] as? String else {
            throw MCPError(message: "file_name is required")
        }
        let showValues = args["show_values"] as? Bool ?? false

        let fullPath = (path as NSString).appendingPathComponent(fileName)
        // Prevent path traversal — resolved path must stay within project root
        let resolvedPath = URL(fileURLWithPath: fullPath).standardized.path
        guard resolvedPath.hasPrefix(path) else {
            throw MCPError(message: "file_name must be within the project directory")
        }
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw MCPError(message: "File not found: \(fileName)")
        }
        guard let contents = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            throw MCPError(message: "Could not read file: \(fileName)")
        }

        var variables: [[String: String]] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            let displayValue: String
            if showValues {
                displayValue = value
            } else {
                // Mask: show first 2 chars + asterisks
                if value.count <= 4 {
                    displayValue = String(repeating: "*", count: value.count)
                } else {
                    displayValue = String(value.prefix(2)) + String(repeating: "*", count: min(value.count - 2, 20))
                }
            }
            variables.append(["key": key, "value": displayValue])
        }

        if let data = try? JSONSerialization.data(withJSONObject: [
            "file": fileName,
            "variables": variables,
            "count": variables.count,
            "values_masked": !showValues
        ] as [String: Any], options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Found \(variables.count) variables in \(fileName)"
    }

    // MARK: - Browser Command Execution

    func executeBrowserCommand(tool: String, args: [String: Any] = [:], timeout: TimeInterval = 5.0, retries: Int = 1) throws -> String {
        let argsJSON: String?
        if args.isEmpty {
            argsJSON = nil
        } else if let data = try? JSONSerialization.data(withJSONObject: args),
                  let str = String(data: data, encoding: .utf8) {
            argsJSON = str
        } else {
            argsJSON = nil
        }

        var lastError: String?

        for attempt in 0...retries {
            var command = BrowserCommand(
                id: nil,
                tool: tool,
                args: argsJSON,
                status: "pending",
                result: nil,
                createdAt: Date(),
                completedAt: nil
            )

            try db.write { db in
                try command.insert(db)
            }

            guard let commandId = command.id else {
                throw MCPError(message: "Failed to insert browser command")
            }

            let startTime = Date()
            // Adaptive polling: start fast (20ms), ramp up to 200ms
            var pollInterval: TimeInterval = 0.02
            // Once GUI claims the command, extend deadline so in-flight work isn't killed
            var effectiveTimeout = timeout
            var wasPickedUp = false

            while Date().timeIntervalSince(startTime) < effectiveTimeout {
                Thread.sleep(forTimeInterval: pollInterval)
                pollInterval = min(pollInterval * 1.5, 0.2)

                let updated = try db.read { db in
                    try BrowserCommand.fetchOne(db, key: commandId)
                }

                guard let cmd = updated else {
                    // Command disappeared — GUI may have cleaned it up
                    lastError = "Browser command disappeared unexpectedly"
                    break
                }

                switch cmd.status {
                case "completed":
                    _ = try? db.write { db in
                        try BrowserCommand.deleteOne(db, key: commandId)
                    }
                    return cmd.result ?? "{}"

                case "error":
                    _ = try? db.write { db in
                        try BrowserCommand.deleteOne(db, key: commandId)
                    }
                    throw MCPError(message: cmd.result ?? "Browser command failed")

                case "executing":
                    // GUI picked it up — give it extra time to finish (up to 30s total)
                    if !wasPickedUp {
                        wasPickedUp = true
                        effectiveTimeout = max(effectiveTimeout, 30.0)
                    }
                    pollInterval = 0.1
                    continue

                default:
                    continue
                }
            }

            // Timeout — mark as timed_out so GUI knows to skip it, then clean up
            _ = try? db.write { db in
                try db.execute(
                    sql: "UPDATE browserCommands SET status = 'timed_out' WHERE id = ? AND status = 'pending'",
                    arguments: [commandId]
                )
                // Only delete if still pending/timed_out (not if GUI grabbed it)
                try db.execute(
                    sql: "DELETE FROM browserCommands WHERE id = ? AND status IN ('timed_out')",
                    arguments: [commandId]
                )
            }

            lastError = "Browser command timed out after \(Int(timeout))s"

            if attempt < retries {
                // Brief pause before retry
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        throw MCPError(message: "\(lastError ?? "Browser command failed"). Is Workspace running with the browser tab visible?")
    }

    // MARK: - Context Engine

    func contextSearch(_ args: [String: Any]?) throws -> String {
        guard let query = args?["query"] as? String, !query.isEmpty else {
            throw MCPError(message: "Missing required parameter: query")
        }

        let limit = args?["limit"] as? Int ?? 10
        let types = args?["types"] as? [String]

        guard let projectId = detectedProjectId else {
            throw MCPError(message: "No project detected. Run from within a project directory.")
        }

        // Check index state
        let state = try db.read { conn in
            try IndexState.fetchOne(conn, sql: "SELECT * FROM indexState WHERE projectId = ?", arguments: [projectId])
        }

        let indexStatus = state?.status ?? "not_indexed"

        if indexStatus == "not_indexed" || state == nil {
            // Request indexing from the GUI app via IPC
            let projectPath = try db.read { conn -> String? in
                try Project.fetchOne(conn, sql: "SELECT * FROM projects WHERE id = ?", arguments: [projectId])?.path
            } ?? workingDirectory

            let existingRequest = try db.read { conn in
                try Row.fetchOne(conn, sql: "SELECT 1 FROM indexRequests WHERE projectId = ? AND status = 'pending'", arguments: [projectId])
            }

            if existingRequest == nil {
                try db.write { conn in
                    try conn.execute(
                        sql: "INSERT INTO indexRequests (projectId, projectPath, status, createdAt) VALUES (?, ?, 'pending', ?)",
                        arguments: [projectId, projectPath, Date()]
                    )
                }
            }

            return formatJSON([
                "results": [] as [Any],
                "index_status": "indexing_requested",
                "message": "Indexing has been requested. The Context app will begin indexing this project shortly. Try again in a few seconds."
            ])
        }

        // --- Step 1: Preprocess query ---

        let processed = QueryPreprocessor.process(query)

        // --- Step 2: FTS5 keyword search (always works, no API call needed) ---

        // Build FTS query from original terms + expanded terms (OR'd)
        var allTerms = query
            .replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: ":", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Add expanded terms from preprocessor
        for term in processed.expandedTerms {
            let cleaned = term.replacingOccurrences(of: "\"", with: "\"\"")
            if !allTerms.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                allTerms.append(cleaned)
            }
        }

        let ftsQuery = allTerms.map { "\"\($0)\"" }.joined(separator: " OR ")

        // Dictionary keyed by chunk ID for merging: (path, chunk, ftsScore, semanticScore)
        var ftsScores: [String: (path: String, chunk: CodeChunk, score: Float)] = [:]

        if !ftsQuery.isEmpty {
            let ftsRows: [(CodeChunk, String, Double)] = (try? db.read { conn in
                var sql = """
                    SELECT c.*, f.relativePath, bm25(codeChunksFts) AS rank
                    FROM codeChunksFts fts
                    JOIN codeChunks c ON c.rowid = fts.rowid
                    JOIN indexedFiles f ON c.fileId = f.id
                    WHERE codeChunksFts MATCH ? AND c.projectId = ?
                """
                var arguments: [DatabaseValueConvertible] = [ftsQuery, projectId]

                if let types = types, !types.isEmpty {
                    let placeholders = types.map { _ in "?" }.joined(separator: ", ")
                    sql += " AND c.chunkType IN (\(placeholders))"
                    arguments.append(contentsOf: types)
                }

                sql += " ORDER BY rank LIMIT 50"

                let rows = try Row.fetchAll(conn, sql: sql, arguments: StatementArguments(arguments))
                return try rows.map { row in
                    let chunk = try CodeChunk(row: row)
                    let path: String = row["relativePath"]
                    let rank: Double = row["rank"] ?? 0
                    return (chunk, path, rank)
                }
            }) ?? []

            let maxRank = ftsRows.map { abs($0.2) }.max() ?? 1.0
            for (chunk, path, rank) in ftsRows {
                let normalizedScore = Float(abs(rank) / max(maxRank, 0.001))
                ftsScores[chunk.id] = (path, chunk, normalizedScore)
            }
        }

        // --- Step 3: Semantic search (optional — requires API key + embeddings) ---

        let appDefaults = UserDefaults(suiteName: "com.workspace.app")
        let apiKey = appDefaults?.string(forKey: "openRouterAPIKey")
        let hasApiKey = apiKey != nil && !apiKey!.isEmpty

        // Determine embedding status
        let embeddingStatus: String
        if !hasApiKey {
            embeddingStatus = "none"
        } else {
            let hasUnembedded = (try? db.read { conn in
                try Row.fetchOne(conn, sql: "SELECT 1 FROM codeChunks WHERE projectId = ? AND embedding IS NULL LIMIT 1", arguments: [projectId])
            }) != nil
            embeddingStatus = hasUnembedded ? "in_progress" : "complete"
        }

        var semanticScores: [String: (path: String, chunk: CodeChunk, score: Float)] = [:]

        if hasApiKey {
            // Check if any chunks have embeddings before attempting semantic search
            let hasEmbeddings = (try? db.read { conn in
                try Row.fetchOne(conn, sql: "SELECT 1 FROM codeChunks WHERE projectId = ? AND embedding IS NOT NULL LIMIT 1", arguments: [projectId])
            }) != nil

            if hasEmbeddings {
                let model = appDefaults?.string(forKey: "embeddingModel") ?? "openai/text-embedding-3-small"
                let embeddingQuery = processed.tokenizedQuery.isEmpty ? query : processed.tokenizedQuery

                // Check embedding cache first
                let queryVector: [Float]?
                if let cached = self.embeddingCache.get(embeddingQuery) {
                    queryVector = cached
                } else if let fetched = try? self.embedQuery(query: embeddingQuery, apiKey: apiKey!, model: model) {
                    self.embeddingCache.set(embeddingQuery, vector: fetched)
                    queryVector = fetched
                } else {
                    queryVector = nil
                }

                if let queryVector = queryVector {
                    // Load chunks WITH embeddings only
                    let chunks: [(CodeChunk, String)] = (try? db.read { conn in
                        var sql = """
                            SELECT c.*, f.relativePath
                            FROM codeChunks c
                            JOIN indexedFiles f ON c.fileId = f.id
                            WHERE c.projectId = ? AND c.embedding IS NOT NULL
                        """
                        var arguments: [DatabaseValueConvertible] = [projectId]

                        if let types = types, !types.isEmpty {
                            let placeholders = types.map { _ in "?" }.joined(separator: ", ")
                            sql += " AND c.chunkType IN (\(placeholders))"
                            arguments.append(contentsOf: types)
                        }

                        let rows = try Row.fetchAll(conn, sql: sql, arguments: StatementArguments(arguments))
                        return try rows.map { row in
                            let chunk = try CodeChunk(row: row)
                            let path: String = row["relativePath"]
                            return (chunk, path)
                        }
                    }) ?? []

                    for (chunk, path) in chunks {
                        guard let vector = chunk.embeddingVector else { continue }
                        let sim = self.cosineSimilarity(queryVector, vector)
                        if sim > 0.15 {
                            semanticScores[chunk.id] = (path, chunk, sim)
                        }
                    }
                }
            }
        }

        // --- Step 4: Merge results using adaptive weights ---

        let semWeight = processed.semanticWeight
        let kwWeight = processed.keywordWeight
        let allChunkIds = Set(ftsScores.keys).union(semanticScores.keys)

        var merged: [(path: String, chunk: CodeChunk, score: Float)] = []

        for chunkId in allChunkIds {
            let fts = ftsScores[chunkId]
            let sem = semanticScores[chunkId]

            let path: String
            let chunk: CodeChunk
            let score: Float

            if let fts = fts, let sem = sem {
                // Found in both — combine with adaptive weights
                path = fts.path
                chunk = fts.chunk
                score = (kwWeight * fts.score) + (semWeight * sem.score)
            } else if let fts = fts {
                // FTS only
                path = fts.path
                chunk = fts.chunk
                score = kwWeight * fts.score
            } else if let sem = sem {
                // Semantic only
                path = sem.path
                chunk = sem.chunk
                score = semWeight * sem.score
            } else {
                continue
            }

            merged.append((path, chunk, score))
        }

        // --- Step 5: Apply chunk importance multipliers ---

        for i in 0..<merged.count {
            var multiplier: Float = 1.0

            // Type multiplier
            switch merged[i].chunk.chunkType {
            case "function": multiplier *= 1.0
            case "class":    multiplier *= 1.0
            case "doc":      multiplier *= 0.9
            case "block":    multiplier *= 0.7
            case "header":   multiplier *= 0.5
            case "commit":   multiplier *= 0.6
            default:         multiplier *= 0.8
            }

            // File path multiplier
            let pathLower = merged[i].path.lowercased()
            if pathLower.contains("test") || pathLower.contains("spec") || pathLower.contains("mock") {
                multiplier *= 0.6
            }
            if pathLower.contains("generated") || pathLower.contains(".build/") || pathLower.contains("vendor/") {
                multiplier *= 0.3
            }

            // Visibility boost: public/export/open in first 200 chars
            let contentPrefix = String(merged[i].chunk.content.prefix(200)).lowercased()
            if contentPrefix.contains("public ") || contentPrefix.contains("export ") || contentPrefix.contains("open ") {
                multiplier *= 1.2
            }

            merged[i].score *= multiplier
        }

        // --- Step 6: Apply dynamic threshold ---

        merged.sort { $0.score > $1.score }

        let threshold: Float
        if merged.count >= 3 {
            let topN = Array(merged.prefix(5))
            let scores = topN.map { $0.score }
            let mean = scores.reduce(0, +) / Float(scores.count)
            let variance = scores.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(max(scores.count - 1, 1))
            let stddev = sqrt(variance)
            threshold = max(mean - stddev, 0.05)
        } else {
            threshold = 0.05
        }

        let filtered = merged.filter { $0.score >= threshold }

        // --- Step 7: Result consolidation — max 2 chunks per file ---

        var fileChunkCounts: [String: Int] = [:]
        var fileExtraCounts: [String: Int] = [:]
        var consolidated: [(path: String, chunk: CodeChunk, score: Float)] = []

        for item in filtered {
            let count = fileChunkCounts[item.path, default: 0]
            if count < 2 {
                consolidated.append(item)
                fileChunkCounts[item.path] = count + 1
            } else {
                fileExtraCounts[item.path, default: 0] += 1
            }
        }

        let topResults = consolidated.prefix(min(limit, 30))

        // --- Step 8: Format output ---

        let queryTypeStr: String
        switch processed.queryType {
        case .symbol:  queryTypeStr = "symbol"
        case .concept: queryTypeStr = "concept"
        case .pattern: queryTypeStr = "pattern"
        }

        let formatted: [[String: Any]] = topResults.map { item in
            var result: [String: Any] = [
                "file": item.path,
                "type": item.chunk.chunkType,
                "score": Double(item.score),
                "content": item.chunk.content
            ]
            if let symbol = item.chunk.symbolName {
                result["symbol"] = symbol
            }
            if let start = item.chunk.startLine, let end = item.chunk.endLine {
                result["lines"] = "\(start)-\(end)"
            }
            let moreInFile = fileExtraCounts[item.path, default: 0]
            if moreInFile > 0 {
                result["more_in_file"] = moreInFile
            }
            return result
        }

        return formatJSON([
            "results": formatted,
            "query_type": queryTypeStr,
            "index_status": indexStatus,
            "embedding_status": embeddingStatus,
            "total_chunks": state?.totalChunks ?? 0
        ])
    }

    /// Embed a query string using OpenRouter's embeddings API (synchronous for MCP).
    private func embedQuery(query: String, apiKey: String, model: String) throws -> [Float] {
        let url = URL(string: "https://openrouter.ai/api/v1/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Workspace", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 15

        let body: [String: Any] = ["model": model, "input": query]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw MCPError(message: "Failed to encode embedding request")
        }
        request.httpBody = bodyData

        var result: (vector: [Float]?, error: String?) = (nil, nil)
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                result.error = error.localizedDescription
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.error = "Invalid embedding response"
                return
            }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                result.error = message
                return
            }

            guard let dataArray = json["data"] as? [[String: Any]],
                  let first = dataArray.first,
                  let embedding = first["embedding"] as? [NSNumber] else {
                result.error = "Missing embedding in response"
                return
            }

            result.vector = embedding.map { $0.floatValue }
        }.resume()

        semaphore.wait()

        if let error = result.error {
            throw MCPError(message: "Embedding failed: \(error)")
        }

        guard let vector = result.vector else {
            throw MCPError(message: "No embedding returned")
        }

        return vector
    }

    /// Cosine similarity between two Float vectors.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Serialize a dictionary to a formatted JSON string.
    private func formatJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - JSON-RPC Helpers

    func successResponse(id: JSONRPCID?, result: [String: Any]) -> [String: Any] {
        var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { resp["id"] = id == .int(0) ? 0 : (id == .string("") ? "" : idValue(id)) }
        return resp
    }

    func errorResponse(id: JSONRPCID?, code: Int, message: String) -> [String: Any] {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { resp["id"] = idValue(id) }
        return resp
    }

    func idValue(_ id: JSONRPCID) -> Any {
        switch id {
        case .int(let i): return i
        case .string(let s): return s
        }
    }

    func write(_ response: [String: Any]) {
        guard !response.isEmpty else { return }
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let str = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write((str + "\n").data(using: .utf8)!)
        }
    }

    // MARK: - Zendesk API

    private static let zendeskBaseURL = "https://iprosystemssupport.zendesk.com/api/v2"
    private static let productEngineeringViewId = 46807113687963

    // Well-known custom field IDs
    private static let zendeskFields: [(Int, String)] = [
        (45899209917339, "Request Area"),
        (45905903171995, "Issue Type"),
        (45906480974875, "System / Application"),
        (45906589672347, "Urgency"),
        (45906931657115, "Scope"),
    ]

    private func zendeskAuth() throws -> String {
        let credURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Workspace/.credentials.json")
        guard let data = try? Data(contentsOf: credURL),
              let creds = try? JSONDecoder().decode([String: String].self, from: data),
              let email = creds["zendesk_email"]?.trimmingCharacters(in: .whitespaces),
              let token = creds["zendesk_api_token"]?.trimmingCharacters(in: .whitespaces),
              !email.isEmpty, !token.isEmpty else {
            throw MCPError(message: "Zendesk not configured. Add email and API token in Workspace Settings > Zendesk.")
        }
        let credentials = "\(email)/token:\(token)"
        return "Basic " + Data(credentials.utf8).base64EncodedString()
    }

    private func zendeskGet(_ path: String) throws -> Data {
        let auth = try zendeskAuth()
        let urlStr = path.hasPrefix("http") ? path : Self.zendeskBaseURL + path
        guard let url = URL(string: urlStr) else { throw MCPError(message: "Invalid URL: \(urlStr)") }

        var request = URLRequest(url: url)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { resultError = error }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                resultError = MCPError(message: "Zendesk API error: HTTP \(http.statusCode)")
            } else {
                resultData = data
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        if let error = resultError { throw error }
        guard let data = resultData else { throw MCPError(message: "No response from Zendesk") }
        return data
    }

    private func zendeskPut(_ path: String, payload: [String: Any]) throws -> Data {
        let auth = try zendeskAuth()
        let urlStr = Self.zendeskBaseURL + path
        guard let url = URL(string: urlStr),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw MCPError(message: "Invalid request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { resultError = error }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                resultError = MCPError(message: "Zendesk update failed: HTTP \(http.statusCode)")
            } else {
                resultData = data
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        if let error = resultError { throw error }
        return resultData ?? Data()
    }

    private func zendeskResolveUser(_ userId: Int) -> String {
        guard let data = try? zendeskGet("/users/\(userId).json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any] else { return "Unknown" }
        return user["name"] as? String ?? user["email"] as? String ?? "Unknown"
    }

    private func formatTicket(_ t: [String: Any]) -> String {
        let id = t["id"] as? Int ?? 0
        let subject = t["subject"] as? String ?? "(no subject)"
        let status = t["status"] as? String ?? "?"
        let priority = t["priority"] as? String ?? "none"
        let requesterId = t["requester_id"] as? Int
        let assigneeId = t["assignee_id"] as? Int
        let createdAt = t["created_at"] as? String ?? ""
        let updatedAt = t["updated_at"] as? String ?? ""

        var lines = [
            "Ticket #\(id): \(subject)",
            "Status: \(status) | Priority: \(priority)",
            "Requester: \(requesterId.map { zendeskResolveUser($0) } ?? "Unknown")",
            "Assignee: \(assigneeId.map { zendeskResolveUser($0) } ?? "Unassigned")",
            "Created: \(createdAt) | Updated: \(updatedAt)",
        ]

        // Custom fields
        if let customFields = t["custom_fields"] as? [[String: Any]] {
            for (fieldId, fieldName) in Self.zendeskFields {
                if let field = customFields.first(where: { ($0["id"] as? Int) == fieldId }),
                   let value = field["value"] as? String, !value.isEmpty {
                    lines.append("\(fieldName): \(value.replacingOccurrences(of: "_", with: " "))")
                }
            }
        }

        // Tags
        if let tags = t["tags"] as? [String], !tags.isEmpty {
            lines.append("Tags: \(tags.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Zendesk Tool Implementations

    func zendeskListTickets(_ args: [String: Any]) throws -> String {
        let viewId = args["view_id"] as? Int ?? Self.productEngineeringViewId
        let data = try zendeskGet("/views/\(viewId)/tickets.json")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tickets = json["tickets"] as? [[String: Any]] else {
            return "No tickets found"
        }

        var filtered = tickets
        if let status = args["status"] as? String {
            filtered = tickets.filter { ($0["status"] as? String) == status }
        }

        if filtered.isEmpty { return "No tickets found" }

        let lines = filtered.map { t -> String in
            let id = t["id"] as? Int ?? 0
            let subject = t["subject"] as? String ?? ""
            let status = t["status"] as? String ?? "?"
            let priority = t["priority"] as? String ?? ""
            return "#\(id) [\(status)] \(priority) — \(subject)"
        }

        return "Found \(filtered.count) tickets:\n\n" + lines.joined(separator: "\n")
    }

    func zendeskGetTicket(_ args: [String: Any]) throws -> String {
        guard let ticketId = args["ticket_id"] as? Int else {
            throw MCPError(message: "ticket_id is required")
        }
        let data = try zendeskGet("/tickets/\(ticketId).json")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = json["ticket"] as? [String: Any] else {
            throw MCPError(message: "Ticket #\(ticketId) not found")
        }
        return formatTicket(ticket)
    }

    func zendeskGetComments(_ args: [String: Any]) throws -> String {
        guard let ticketId = args["ticket_id"] as? Int else {
            throw MCPError(message: "ticket_id is required")
        }
        let data = try zendeskGet("/tickets/\(ticketId)/comments.json")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let comments = json["comments"] as? [[String: Any]] else {
            return "No comments found"
        }

        let formatted = comments.map { c -> String in
            let authorId = c["author_id"] as? Int
            let author = authorId.map { zendeskResolveUser($0) } ?? "Unknown"
            let body = c["body"] as? String ?? ""
            let createdAt = c["created_at"] as? String ?? ""
            let isPublic = c["public"] as? Bool ?? true
            let visibility = isPublic ? "Public" : "Internal"

            return "[\(visibility)] \(author) (\(createdAt)):\n\(body)"
        }

        return "Ticket #\(ticketId) — \(comments.count) comments:\n\n" + formatted.joined(separator: "\n\n---\n\n")
    }

    func zendeskReply(_ args: [String: Any]) throws -> String {
        guard let ticketId = args["ticket_id"] as? Int else {
            throw MCPError(message: "ticket_id is required")
        }
        guard let body = args["body"] as? String, !body.isEmpty else {
            throw MCPError(message: "body is required")
        }
        let isPublic = args["public"] as? Bool ?? true

        let payload: [String: Any] = [
            "ticket": [
                "comment": [
                    "body": body,
                    "public": isPublic,
                ]
            ]
        ]

        _ = try zendeskPut("/tickets/\(ticketId).json", payload: payload)
        return isPublic
            ? "Public reply sent on ticket #\(ticketId)"
            : "Internal note added to ticket #\(ticketId)"
    }

    func zendeskUpdateStatus(_ args: [String: Any]) throws -> String {
        guard let ticketId = args["ticket_id"] as? Int else {
            throw MCPError(message: "ticket_id is required")
        }
        guard let status = args["status"] as? String else {
            throw MCPError(message: "status is required (new, open, pending, hold, solved)")
        }

        let payload: [String: Any] = ["ticket": ["status": status]]
        _ = try zendeskPut("/tickets/\(ticketId).json", payload: payload)
        return "Ticket #\(ticketId) status updated to \(status)"
    }

    func zendeskAssign(_ args: [String: Any]) throws -> String {
        guard let ticketId = args["ticket_id"] as? Int else {
            throw MCPError(message: "ticket_id is required")
        }
        guard let assigneeId = args["assignee_id"] as? Int else {
            throw MCPError(message: "assignee_id is required")
        }

        let payload: [String: Any] = ["ticket": ["assignee_id": assigneeId]]
        _ = try zendeskPut("/tickets/\(ticketId).json", payload: payload)

        if assigneeId == 0 {
            return "Ticket #\(ticketId) unassigned"
        }
        let name = zendeskResolveUser(assigneeId)
        return "Ticket #\(ticketId) assigned to \(name)"
    }

    func zendeskSearch(_ args: [String: Any]) throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            throw MCPError(message: "query is required")
        }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw MCPError(message: "Invalid query")
        }

        let data = try zendeskGet("/search.json?query=type:ticket \(encoded)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return "No results found"
        }

        if results.isEmpty { return "No tickets matched '\(query)'" }

        let lines = results.map { t -> String in
            let id = t["id"] as? Int ?? 0
            let subject = t["subject"] as? String ?? ""
            let status = t["status"] as? String ?? "?"
            return "#\(id) [\(status)] — \(subject)"
        }

        return "Found \(results.count) tickets:\n\n" + lines.joined(separator: "\n")
    }
}

// MARK: - JSON Decoder for MCP

extension JSONDecoder {
    static let mcp: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Notification Subcommand

/// Writes a notification request file that the main Workspace app picks up and displays.
/// Usage: WorkspaceMCP notify --title "Title" --body "Body" [--subtitle "Sub"]
func handleNotifyCommand(_ args: [String]) {
    var title = "Workspace"
    var body = ""
    var subtitle = ""

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--title" where i + 1 < args.count:
            i += 1; title = args[i]
        case "--body" where i + 1 < args.count:
            i += 1; body = args[i]
        case "--subtitle" where i + 1 < args.count:
            i += 1; subtitle = args[i]
        default: break
        }
        i += 1
    }

    let notifyDir = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("Workspace/notifications", isDirectory: true)
    try? FileManager.default.createDirectory(at: notifyDir, withIntermediateDirectories: true)

    let payload: [String: String] = ["title": title, "body": body, "subtitle": subtitle]
    let file = notifyDir.appendingPathComponent("\(UUID().uuidString).json")
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "notify" {
    handleNotifyCommand(Array(args.dropFirst(2)))
    exit(0)
}

do {
    let db = try openDatabase()
    let server = MCPServer(db: db)
    server.run()
} catch {
    let errMsg = """
    {"jsonrpc":"2.0","error":{"code":-32603,"message":"\(error.localizedDescription)"},"id":null}
    """
    FileHandle.standardError.write(errMsg.data(using: .utf8)!)
    exit(1)
}
