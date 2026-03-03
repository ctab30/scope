# Semantic Search Quality Enhancement — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve context_search result quality through query preprocessing, adaptive scoring, and smarter filtering.

**Architecture:** New QueryPreprocessor classifies queries (symbol/concept/pattern), expands concept queries with synonyms, and selects adaptive semantic/keyword weights. Enhanced ChunkSearchEngine applies importance multipliers, dynamic thresholds, and result consolidation. EmbeddingCache avoids redundant API calls.

**Tech Stack:** Swift, GRDB, SQLite FTS5, OpenRouter Embeddings API

---

### Task 1: Create QueryPreprocessor

**Files:**
- Create: `Context/Sources/Context/Services/QueryPreprocessor.swift`

**Step 1: Create the file with query classification**

```swift
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
        let queryType = classify(query)
        let tokenized = tokenize(query)
        let expanded = queryType == .concept ? expand(query) : []
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
        let codeOperators: [Character] = [".", "(", ")", "<", ">", "_", ":"]
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

        return expansions
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
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build complete

**Step 3: Commit**

```
git add Context/Sources/Context/Services/QueryPreprocessor.swift
git commit -m "feat(search): add QueryPreprocessor with classification, tokenization, and expansion"
```

---

### Task 2: Create EmbeddingCache

**Files:**
- Create: `Context/Sources/ScopeMCP/EmbeddingCache.swift`

Note: This lives in ScopeMCP (not Context) because the MCP server process is where query embeddings happen.

**Step 1: Create the LRU cache**

```swift
import Foundation

/// LRU cache for query embedding vectors. Avoids redundant OpenRouter API calls
/// for repeated or similar queries within the same MCP session.
final class EmbeddingCache {
    private var cache: [String: (vector: [Float], timestamp: Date)] = [:]
    private var accessOrder: [String] = []
    private let maxEntries: Int

    init(maxEntries: Int = 50) {
        self.maxEntries = maxEntries
    }

    /// Get a cached embedding vector for the given query, or nil if not cached.
    func get(_ query: String) -> [Float]? {
        let key = normalize(query)
        guard let entry = cache[key] else { return nil }

        // Move to end of access order (most recently used)
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
            accessOrder.append(key)
        }

        return entry.vector
    }

    /// Store an embedding vector for the given query.
    func set(_ query: String, vector: [Float]) {
        let key = normalize(query)

        // Evict oldest if at capacity
        if cache[key] == nil && cache.count >= maxEntries {
            if let oldest = accessOrder.first {
                cache.removeValue(forKey: oldest)
                accessOrder.removeFirst()
            }
        }

        cache[key] = (vector: vector, timestamp: Date())
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
    }

    /// Normalize query string for cache key (lowercase, trim, collapse whitespace).
    private func normalize(_ query: String) -> String {
        query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build complete

**Step 3: Commit**

```
git add Context/Sources/ScopeMCP/EmbeddingCache.swift
git commit -m "feat(search): add LRU embedding cache for MCP query vectors"
```

---

### Task 3: Enhance ChunkSearchEngine — Adaptive Weights & Importance Scoring

**Files:**
- Modify: `Context/Sources/Context/Services/ChunkSearchEngine.swift`

**Step 1: Update the search function signature to accept preprocessed query info**

The `search` function currently takes raw query + fixed weights. Update it to accept adaptive weights from the preprocessor. Also add importance scoring and dynamic threshold.

Replace the entire `ChunkSearchEngine.swift` with:

```swift
import Foundation
import GRDB

/// Hybrid search engine combining semantic (cosine similarity) and keyword (FTS5) results.
struct ChunkSearchEngine {

    struct SearchResult {
        let file: String           // relative path
        let symbol: String?
        let type: String           // chunk type
        let lines: String?         // "245-280"
        let score: Float
        let content: String
        let moreInFile: Int        // count of additional matches from same file (0 if none)
    }

    /// Search for chunks matching a query using hybrid ranking.
    static func search(
        queryVector: [Float],
        projectId: String,
        query: String,
        ftsTerms: [String]? = nil,    // expanded terms for FTS (from QueryPreprocessor)
        semanticWeight: Float = 0.70,
        keywordWeight: Float = 0.30,
        limit: Int = 10,
        types: [String]? = nil,
        db: DatabaseQueue
    ) throws -> [SearchResult] {
        let effectiveLimit = min(max(limit, 1), 30)

        // 1. Semantic search — cosine similarity against all embeddings
        let semanticResults = try semanticSearch(
            queryVector: queryVector,
            projectId: projectId,
            types: types,
            db: db
        )

        // 2. Keyword search — FTS5 match with optional expanded terms
        let keywordResults = try keywordSearch(
            query: query,
            expandedTerms: ftsTerms,
            projectId: projectId,
            types: types,
            db: db
        )

        // 3. Merge, score, and rank
        return mergeResults(
            semantic: semanticResults,
            keyword: keywordResults,
            semanticWeight: semanticWeight,
            keywordWeight: keywordWeight,
            limit: effectiveLimit
        )
    }

    // MARK: - Semantic Search

    private struct ScoredChunk {
        let chunk: CodeChunk
        let file: String
        let score: Float
    }

    private static func semanticSearch(
        queryVector: [Float],
        projectId: String,
        types: [String]?,
        db: DatabaseQueue
    ) throws -> [ScoredChunk] {
        let chunks: [(CodeChunk, String)] = try db.read { conn in
            var sql = """
                SELECT c.*, f.relativePath
                FROM codeChunks c
                JOIN indexedFiles f ON c.fileId = f.id
                WHERE c.projectId = ? AND c.embedding IS NOT NULL
            """
            var args: [DatabaseValueConvertible] = [projectId]

            if let types = types, !types.isEmpty {
                let placeholders = types.map { _ in "?" }.joined(separator: ", ")
                sql += " AND c.chunkType IN (\(placeholders))"
                args.append(contentsOf: types)
            }

            let rows = try Row.fetchAll(conn, sql: sql, arguments: StatementArguments(args))
            return try rows.map { row in
                let chunk = try CodeChunk(row: row)
                let path = row["relativePath"] as String
                return (chunk, path)
            }
        }

        var scored: [ScoredChunk] = []
        for (chunk, path) in chunks {
            guard let vector = chunk.embeddingVector else { continue }
            let sim = cosineSimilarity(queryVector, vector)
            // Use a low floor here; dynamic threshold applied later in merge
            if sim > 0.15 {
                scored.append(ScoredChunk(chunk: chunk, file: path, score: sim))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(50))
    }

    // MARK: - Keyword Search

    private static func keywordSearch(
        query: String,
        expandedTerms: [String]?,
        projectId: String,
        types: [String]?,
        db: DatabaseQueue
    ) throws -> [ScoredChunk] {
        return try db.read { conn in
            // Build FTS query: original terms OR'd together
            var allTerms = query
                .replacingOccurrences(of: "\"", with: "\"\"")
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { "\"\($0)\"" }

            // Add expanded synonym terms
            if let expanded = expandedTerms {
                for term in expanded {
                    let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                    allTerms.append("\"\(escaped)\"")
                }
            }

            let ftsQuery = allTerms.joined(separator: " OR ")
            guard !ftsQuery.isEmpty else { return [] }

            var sql = """
                SELECT c.*, f.relativePath, bm25(codeChunksFts) AS rank
                FROM codeChunksFts fts
                JOIN codeChunks c ON c.rowid = fts.rowid
                JOIN indexedFiles f ON c.fileId = f.id
                WHERE codeChunksFts MATCH ? AND c.projectId = ?
            """
            var args: [DatabaseValueConvertible] = [ftsQuery, projectId]

            if let types = types, !types.isEmpty {
                let placeholders = types.map { _ in "?" }.joined(separator: ", ")
                sql += " AND c.chunkType IN (\(placeholders))"
                args.append(contentsOf: types)
            }

            sql += " ORDER BY rank LIMIT 50"

            let rows = try Row.fetchAll(conn, sql: sql, arguments: StatementArguments(args))

            let ranks = rows.compactMap { $0["rank"] as? Double }
            let maxRank = ranks.map { abs($0) }.max() ?? 1.0

            return try rows.map { row in
                let chunk = try CodeChunk(row: row)
                let path = row["relativePath"] as String
                let rank = abs(row["rank"] as? Double ?? 0)
                let normalized = Float(rank / max(maxRank, 0.001))
                return ScoredChunk(chunk: chunk, file: path, score: normalized)
            }
        }
    }

    // MARK: - Merge

    private static func mergeResults(
        semantic: [ScoredChunk],
        keyword: [ScoredChunk],
        semanticWeight: Float,
        keywordWeight: Float,
        limit: Int
    ) -> [SearchResult] {
        // Combine scores with adaptive weights
        var combined: [String: (chunk: ScoredChunk, semanticScore: Float, keywordScore: Float)] = [:]

        for s in semantic {
            combined[s.chunk.id] = (chunk: s, semanticScore: s.score, keywordScore: 0)
        }

        for k in keyword {
            if var existing = combined[k.chunk.id] {
                existing.keywordScore = k.score
                combined[k.chunk.id] = existing
            } else {
                combined[k.chunk.id] = (chunk: k, semanticScore: 0, keywordScore: k.score)
            }
        }

        // Score with adaptive weights + importance multiplier
        var scored = combined.values.map { entry -> (ScoredChunk, Float) in
            let baseScore = (semanticWeight * entry.semanticScore) + (keywordWeight * entry.keywordScore)
            let importance = chunkImportance(entry.chunk)
            return (entry.chunk, baseScore * importance)
        }

        scored.sort { $0.1 > $1.1 }

        // Dynamic threshold: mean of top 5 minus 1 stddev, floor at 0.05
        let threshold = dynamicThreshold(scores: scored.map { $0.1 })
        scored = scored.filter { $0.1 >= threshold }

        // Consolidate: limit per-file results, track extras
        return consolidateResults(scored: scored, limit: limit)
    }

    // MARK: - Chunk Importance

    /// Multiplier based on chunk type and file path heuristics.
    private static func chunkImportance(_ scored: ScoredChunk) -> Float {
        var multiplier: Float = 1.0

        // Type-based importance
        switch scored.chunk.chunkType {
        case "function": multiplier *= 1.0
        case "class":    multiplier *= 1.0
        case "doc":      multiplier *= 0.9
        case "block":    multiplier *= 0.7
        case "header":   multiplier *= 0.5
        case "commit":   multiplier *= 0.6
        default:         multiplier *= 0.8
        }

        // File path heuristics
        let path = scored.file.lowercased()
        if path.contains("test") || path.contains("spec") || path.contains("mock") {
            multiplier *= 0.6
        }
        if path.contains("generated") || path.contains(".build/") || path.contains("vendor/") {
            multiplier *= 0.3
        }

        // Visibility heuristic: check if content starts with public/export
        let contentStart = scored.chunk.content.prefix(200).lowercased()
        if contentStart.contains("public ") || contentStart.contains("export ") || contentStart.contains("open ") {
            multiplier *= 1.2
        }

        return multiplier
    }

    // MARK: - Dynamic Threshold

    private static func dynamicThreshold(scores: [Float]) -> Float {
        guard scores.count >= 3 else { return 0.05 }

        let top = Array(scores.prefix(5))
        let mean = top.reduce(0, +) / Float(top.count)
        let variance = top.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(top.count)
        let stddev = sqrt(variance)

        return max(mean - stddev, 0.05)
    }

    // MARK: - Result Consolidation

    /// Limit per-file results to 2, track count of additional matches.
    private static func consolidateResults(
        scored: [(ScoredChunk, Float)],
        limit: Int
    ) -> [SearchResult] {
        var fileCount: [String: Int] = [:]
        var fileExtras: [String: Int] = [:]
        var results: [SearchResult] = []

        for (chunk, finalScore) in scored {
            let file = chunk.file
            let count = fileCount[file, default: 0]

            if count >= 2 {
                fileExtras[file, default: 0] += 1
                continue
            }

            fileCount[file, default: 0] += 1

            let lines: String? = {
                if let start = chunk.chunk.startLine, let end = chunk.chunk.endLine {
                    return "\(start)-\(end)"
                }
                return nil
            }()

            results.append(SearchResult(
                file: file,
                symbol: chunk.chunk.symbolName,
                type: chunk.chunk.chunkType,
                lines: lines,
                score: finalScore,
                content: chunk.chunk.content,
                moreInFile: 0  // updated below
            ))

            if results.count >= limit { break }
        }

        // Backfill moreInFile counts
        for i in 0..<results.count {
            if let extras = fileExtras[results[i].file] {
                results[i] = SearchResult(
                    file: results[i].file,
                    symbol: results[i].symbol,
                    type: results[i].type,
                    lines: results[i].lines,
                    score: results[i].score,
                    content: results[i].content,
                    moreInFile: extras
                )
            }
        }

        return results
    }

    // MARK: - Cosine Similarity

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build complete (may have warnings about unused `moreInFile` in callers — that's fine, we wire it up in Task 4)

**Step 3: Commit**

```
git add Context/Sources/Context/Services/ChunkSearchEngine.swift
git commit -m "feat(search): enhance ChunkSearchEngine with adaptive weights, importance scoring, and consolidation"
```

---

### Task 4: Wire QueryPreprocessor + Cache into ScopeMCP

**Files:**
- Modify: `Context/Sources/ScopeMCP/main.swift`

This is the critical integration point. The `contextSearch` function in main.swift currently does its own inline search. We need to:

1. Add QueryPreprocessor import (it's in the Context module — but ScopeMCP can't import Context. So we need to **copy the QueryPreprocessor logic into ScopeMCP** or make a shared module. The simplest approach: add a lightweight copy of just the `process()` logic into main.swift, similar to how CodeChunk is already duplicated between the two targets.)

2. Add EmbeddingCache as a property on MCPServer
3. Use the preprocessor to classify/tokenize/expand the query
4. Use the cache for query embeddings
5. Pass adaptive weights to the merge step
6. Apply importance multipliers in the inline search logic
7. Apply dynamic threshold
8. Add `moreInFile` to output

**Step 1: Add QueryPreprocessor copy + EmbeddingCache property to MCPServer**

At the top of main.swift, after the existing model definitions (after `struct IndexState`), add the `QueryPreprocessor` struct. Since ScopeMCP is a separate target that can't import the Context module, we duplicate the preprocessor here (same pattern as CodeChunk).

In `class MCPServer`, add:
```swift
let embeddingCache = EmbeddingCache()
```

**Step 2: Rewrite the `contextSearch` function**

Replace the existing `contextSearch(_ args:)` function body to:
1. Run query through QueryPreprocessor.process()
2. Check embeddingCache before calling embedQuery()
3. Pass expanded terms to FTS query construction
4. Use adaptive weights from the preprocessor
5. Apply chunk importance multipliers
6. Apply dynamic threshold
7. Consolidate per-file results
8. Include `more_in_file` count in output

The key changes inside contextSearch:
- Before embedding: `let processed = QueryPreprocessor.process(query)`
- Tokenized query for embedding: `processed.tokenizedQuery`
- Expanded terms for FTS: `processed.expandedTerms` OR'd into the FTS query
- Adaptive weights: `processed.semanticWeight` and `processed.keywordWeight` in the merge step
- Cache: `embeddingCache.get(processed.tokenizedQuery)` / `embeddingCache.set(processed.tokenizedQuery, vector: queryVector)`
- Output: add `"query_type": processed.queryType` and `"more_in_file"` count per result

**Step 3: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build complete

**Step 4: Commit**

```
git add Context/Sources/ScopeMCP/main.swift Context/Sources/ScopeMCP/EmbeddingCache.swift
git commit -m "feat(search): integrate QueryPreprocessor and EmbeddingCache into context_search MCP tool"
```

---

### Task 5: Update GUI-Side ChunkSearchEngine Callers

**Files:**
- Modify: `Context/Sources/Context/Services/ContextAssembler.swift` (if it calls ChunkSearchEngine.search)

**Step 1: Find all callers of ChunkSearchEngine.search**

Search for `ChunkSearchEngine.search` in the Context target. Update any callers to pass the new parameters (or use defaults — the function has sensible defaults for all new params).

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build complete with no errors

**Step 3: Commit**

```
git add -A
git commit -m "fix(search): update ChunkSearchEngine callers for new search signature"
```

---

### Task 6: Add `moreInFile` to MCP Search Output

**Files:**
- Modify: `Context/Sources/ScopeMCP/main.swift` (the result formatting section of contextSearch)

**Step 1: Add `more_in_file` to formatted output**

In the `contextSearch` function's result formatting section (the `formatted` map at the end), include the `moreInFile` field when > 0:

```swift
if result.moreInFile > 0 {
    entry["more_in_file"] = result.moreInFile
}
```

Also add `"query_type"` to the response metadata so callers can see how the query was classified:

```swift
"query_type": String(describing: processed.queryType)
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build complete

**Step 3: Commit**

```
git add Context/Sources/ScopeMCP/main.swift
git commit -m "feat(search): expose query_type and more_in_file in context_search results"
```

---

### Task 7: Final Verification

**Step 1: Clean build**

Run: `cd Context && swift build 2>&1`
Expected: Build complete with no errors

**Step 2: Smoke test MCP**

```bash
echo '{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{}},"id":1}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"context_search","arguments":{"query":"how does authentication work"}},"id":2}' | .build/debug/ScopeMCP
```

Expected: Response with `query_type: "concept"` and results

```bash
echo '{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{}},"id":1}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"context_search","arguments":{"query":"BrowserTab.uploadFile"}},"id":2}' | .build/debug/ScopeMCP
```

Expected: Response with `query_type: "symbol"` and results

**Step 3: Commit any remaining fixes**

```
git add -A
git commit -m "fix(search): address issues found during smoke testing"
```

---

## Summary

| Task | What | New/Modified |
|------|------|-------------|
| 1 | QueryPreprocessor (classify, tokenize, expand) | New: `QueryPreprocessor.swift` |
| 2 | EmbeddingCache (LRU, 50 entries) | New: `EmbeddingCache.swift` |
| 3 | ChunkSearchEngine (adaptive weights, importance, threshold, consolidation) | Modified: `ChunkSearchEngine.swift` |
| 4 | Wire into ScopeMCP (preprocessor + cache + integration) | Modified: `main.swift` |
| 5 | Update GUI-side callers | Modified: `ContextAssembler.swift` |
| 6 | Expose new fields in MCP output | Modified: `main.swift` |
| 7 | Final verification + smoke test | — |
