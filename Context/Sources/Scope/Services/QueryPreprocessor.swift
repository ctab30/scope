import Foundation

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
    /// Key is the group name (unused), value is an array of related terms.
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
