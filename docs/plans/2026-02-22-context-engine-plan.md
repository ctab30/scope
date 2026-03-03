# Context Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a local semantic code search engine that indexes code, docs, and git history using OpenRouter embeddings, exposed as a `context_search` MCP tool.

**Architecture:** The GUI app (long-running) owns the indexing pipeline — file watching, chunking, embedding via OpenRouter, and storing in SQLite. The MCP server reads the pre-computed index at query time, embeds the query, computes cosine similarity, and returns ranked results. Both processes share the existing `context.db` via WAL mode.

**Tech Stack:** Swift, GRDB/SQLite, FTS5, OpenRouter Embeddings API (`openai/text-embedding-3-small`), FSEvents

**Design doc:** `docs/plans/2026-02-22-context-engine-design.md`

---

### Task 1: Database Migration — Three New Tables + FTS5

Add the `indexedFiles`, `codeChunks`, and `indexState` tables plus a `codeChunksFts` virtual table to the existing migration chain.

**Files:**
- Modify: `Context/Sources/Context/Services/DatabaseService.swift` (add migration `v15_createContextEngine`)

**Step 1: Add the migration**

In `DatabaseService.swift`, inside the `migrator` computed property, before `return migrator`, add:

```swift
migrator.registerMigration("v15_createContextEngine") { db in
    try db.create(table: "indexedFiles") { t in
        t.primaryKey("id", .text)
        t.column("projectId", .text).notNull()
        t.column("relativePath", .text).notNull()
        t.column("contentHash", .text).notNull()
        t.column("language", .text)
        t.column("lastIndexedAt", .datetime).notNull()
    }
    try db.create(index: "indexedFiles_projectId", on: "indexedFiles", columns: ["projectId"])
    try db.create(index: "indexedFiles_path", on: "indexedFiles", columns: ["projectId", "relativePath"], unique: true)

    try db.create(table: "codeChunks") { t in
        t.primaryKey("id", .text)
        t.column("fileId", .text).notNull()
        t.column("projectId", .text).notNull()
        t.column("chunkType", .text).notNull()
        t.column("symbolName", .text)
        t.column("content", .text).notNull()
        t.column("startLine", .integer)
        t.column("endLine", .integer)
        t.column("embedding", .blob)
    }
    try db.create(index: "codeChunks_projectId", on: "codeChunks", columns: ["projectId"])
    try db.create(index: "codeChunks_fileId", on: "codeChunks", columns: ["fileId"])

    try db.create(table: "indexState") { t in
        t.primaryKey("projectId", .text)
        t.column("status", .text).notNull().defaults(to: "idle")
        t.column("lastFullIndexAt", .datetime)
        t.column("totalChunks", .integer).notNull().defaults(to: 0)
        t.column("lastError", .text)
    }

    try db.create(virtualTable: "codeChunksFts", using: FTS5()) { t in
        t.synchronize(withTable: "codeChunks")
        t.column("content")
        t.column("symbolName")
    }
}
```

**Step 2: Build to verify migration compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/DatabaseService.swift
git commit -m "feat: add database migration for context engine tables"
```

---

### Task 2: GRDB Models — IndexedFile, CodeChunk, IndexState

Create the three GRDB model structs following the existing pattern (see `Note.swift`, `TaskItem.swift`).

**Files:**
- Create: `Context/Sources/Context/Models/IndexedFile.swift`
- Create: `Context/Sources/Context/Models/CodeChunk.swift`
- Create: `Context/Sources/Context/Models/IndexState.swift`

**Step 1: Create IndexedFile model**

Create `Context/Sources/Context/Models/IndexedFile.swift`:

```swift
import Foundation
import GRDB

struct IndexedFile: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var relativePath: String
    var contentHash: String
    var language: String?
    var lastIndexedAt: Date

    static let databaseTableName = "indexedFiles"
}
```

**Step 2: Create CodeChunk model**

Create `Context/Sources/Context/Models/CodeChunk.swift`:

```swift
import Foundation
import GRDB

struct CodeChunk: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var fileId: String
    var projectId: String
    var chunkType: String      // "function", "class", "block", "doc", "commit"
    var symbolName: String?
    var content: String
    var startLine: Int?
    var endLine: Int?
    var embedding: Data?       // 1536 × 4 bytes = 6144 bytes (Float array as raw Data)

    static let databaseTableName = "codeChunks"

    /// Decode the BLOB back into a Float array for similarity computation.
    var embeddingVector: [Float]? {
        guard let data = embedding else { return nil }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    /// Encode a Float array into Data for storage.
    static func encodeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
```

**Step 3: Create IndexState model**

Create `Context/Sources/Context/Models/IndexState.swift`:

```swift
import Foundation
import GRDB

struct IndexState: Codable, FetchableRecord, MutablePersistableRecord {
    var projectId: String
    var status: String         // "idle", "indexing", "ready", "error"
    var lastFullIndexAt: Date?
    var totalChunks: Int
    var lastError: String?

    static let databaseTableName = "indexState"
}
```

**Step 4: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 5: Commit**

```bash
git add Context/Sources/Context/Models/IndexedFile.swift Context/Sources/Context/Models/CodeChunk.swift Context/Sources/Context/Models/IndexState.swift
git commit -m "feat: add GRDB models for IndexedFile, CodeChunk, IndexState"
```

---

### Task 3: EmbeddingClient — OpenRouter HTTP Client

HTTP client that calls OpenRouter's `/embeddings` endpoint with batching and retry logic. Reuses the existing `openRouterAPIKey` from `ClaudeService`.

**Files:**
- Create: `Context/Sources/Context/Services/EmbeddingClient.swift`

**Step 1: Create EmbeddingClient**

Create `Context/Sources/Context/Services/EmbeddingClient.swift`:

```swift
import Foundation

/// Calls OpenRouter's /embeddings endpoint to generate vector embeddings.
/// Supports batching (up to 20 texts per request) and retry with exponential backoff.
class EmbeddingClient {

    struct EmbeddingResult {
        let embeddings: [[Float]]
        let error: String?
    }

    private let maxRetries = 3
    private let batchSize = 20

    /// Embed a single text string. Returns 1536-dimensional vector or nil on failure.
    func embed(_ text: String) async -> (vector: [Float]?, error: String?) {
        let result = await embedBatch([text])
        if let error = result.error {
            return (nil, error)
        }
        return (result.embeddings.first, nil)
    }

    /// Embed multiple texts in batches of 20. Returns one vector per input text.
    /// If a batch fails after retries, those entries get nil embeddings.
    func embedBatch(_ texts: [String]) async -> EmbeddingResult {
        guard let apiKey = ClaudeService.openRouterAPIKey, !apiKey.isEmpty else {
            return EmbeddingResult(embeddings: [], error: "OpenRouter API key not configured")
        }

        let model = UserDefaults.standard.string(forKey: "embeddingModel") ?? "openai/text-embedding-3-small"
        var allEmbeddings: [[Float]] = []

        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            var lastError: String?
            var batchEmbeddings: [[Float]]?

            for attempt in 0..<maxRetries {
                if attempt > 0 {
                    // Exponential backoff: 1s, 2s, 4s
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000)
                }

                let result = await callOpenRouterEmbeddings(
                    apiKey: apiKey,
                    model: model,
                    inputs: batch
                )

                if let error = result.error {
                    lastError = error
                    continue
                }

                batchEmbeddings = result.embeddings
                break
            }

            if let embeddings = batchEmbeddings {
                allEmbeddings.append(contentsOf: embeddings)
            } else {
                // Fill with empty arrays for failed batch (chunks stored without embeddings)
                for _ in batch {
                    allEmbeddings.append([])
                }
                if allEmbeddings.isEmpty {
                    return EmbeddingResult(embeddings: allEmbeddings, error: lastError)
                }
            }
        }

        return EmbeddingResult(embeddings: allEmbeddings, error: nil)
    }

    // MARK: - HTTP Call

    private func callOpenRouterEmbeddings(
        apiKey: String,
        model: String,
        inputs: [String]
    ) async -> EmbeddingResult {
        let url = URL(string: "https://openrouter.ai/api/v1/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Context App", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "input": inputs
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return EmbeddingResult(embeddings: [], error: "Failed to encode request")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return EmbeddingResult(embeddings: [], error: "Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                let raw = String(data: data, encoding: .utf8) ?? "Unknown"
                return EmbeddingResult(embeddings: [], error: "HTTP \(httpResponse.statusCode): \(String(raw.prefix(200)))")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return EmbeddingResult(embeddings: [], error: "Invalid JSON response")
            }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return EmbeddingResult(embeddings: [], error: message)
            }

            guard let dataArray = json["data"] as? [[String: Any]] else {
                return EmbeddingResult(embeddings: [], error: "Missing 'data' in response")
            }

            // Sort by index to ensure correct ordering
            let sorted = dataArray.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }

            let embeddings: [[Float]] = sorted.compactMap { item in
                guard let embedding = item["embedding"] as? [NSNumber] else { return nil }
                return embedding.map { $0.floatValue }
            }

            guard embeddings.count == inputs.count else {
                return EmbeddingResult(embeddings: [], error: "Embedding count mismatch: got \(embeddings.count), expected \(inputs.count)")
            }

            return EmbeddingResult(embeddings: embeddings, error: nil)
        } catch {
            return EmbeddingResult(embeddings: [], error: error.localizedDescription)
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/EmbeddingClient.swift
git commit -m "feat: add EmbeddingClient for OpenRouter embeddings API"
```

---

### Task 4: CodeChunker — Smart Line-Based Chunking

Splits source files into semantically meaningful chunks using regex heuristics per language. Also handles markdown docs and git commit history.

**Files:**
- Create: `Context/Sources/Context/Services/CodeChunker.swift`

**Step 1: Create CodeChunker**

Create `Context/Sources/Context/Services/CodeChunker.swift`:

```swift
import Foundation

/// Splits source code files into semantic chunks (functions, classes, blocks)
/// using regex heuristics. Also handles markdown docs and git commits.
struct CodeChunker {

    struct Chunk {
        let chunkType: String       // "function", "class", "block", "doc", "commit", "header"
        let symbolName: String?     // e.g. "BrowserTab.uploadFile"
        let content: String
        let startLine: Int?
        let endLine: Int?
    }

    // MARK: - Public API

    /// Chunk a source code file based on its language.
    static func chunkFile(content: String, language: String, filePath: String) -> [Chunk] {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        switch language {
        case "swift":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: swiftPatterns)
        case "typescript", "javascript", "tsx", "jsx":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: tsPatterns)
        case "python":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: pythonPatterns)
        case "rust":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: rustPatterns)
        case "go":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: goPatterns)
        case "dart":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: dartPatterns)
        case "java":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: javaPatterns)
        default:
            return chunkByFixedSize(lines: lines, filePath: filePath)
        }
    }

    /// Chunk a markdown file by headings.
    static func chunkMarkdown(content: String, filePath: String) -> [Chunk] {
        let lines = content.components(separatedBy: "\n")
        var chunks: [Chunk] = []
        var currentSection: [String] = []
        var currentHeading: String? = nil
        var sectionStart = 1

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                // Emit previous section
                if !currentSection.isEmpty {
                    let text = currentSection.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.count >= 20 {
                        chunks.append(Chunk(
                            chunkType: "doc",
                            symbolName: currentHeading,
                            content: text,
                            startLine: sectionStart,
                            endLine: i
                        ))
                    }
                }
                currentHeading = line.trimmingCharacters(in: .init(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
                currentSection = [line]
                sectionStart = i + 1
            } else {
                currentSection.append(line)
            }
        }

        // Emit final section
        if !currentSection.isEmpty {
            let text = currentSection.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 20 {
                chunks.append(Chunk(
                    chunkType: "doc",
                    symbolName: currentHeading,
                    content: text,
                    startLine: sectionStart,
                    endLine: lines.count
                ))
            }
        }

        return chunks
    }

    /// Create chunks from git commit history.
    /// Input: output of `git log --oneline --stat -200`
    static func chunkGitHistory(_ gitLog: String) -> [Chunk] {
        // Split on commit boundaries (lines starting with a short hash)
        let lines = gitLog.components(separatedBy: "\n")
        var chunks: [Chunk] = []
        var current: [String] = []

        for line in lines {
            // Detect commit line: starts with 7+ hex chars followed by space
            if line.range(of: #"^[0-9a-f]{7,} "#, options: .regularExpression) != nil {
                if !current.isEmpty {
                    let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        chunks.append(Chunk(
                            chunkType: "commit",
                            symbolName: nil,
                            content: text,
                            startLine: nil,
                            endLine: nil
                        ))
                    }
                }
                current = [line]
            } else {
                current.append(line)
            }
        }

        // Final commit
        if !current.isEmpty {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunks.append(Chunk(
                    chunkType: "commit",
                    symbolName: nil,
                    content: text,
                    startLine: nil,
                    endLine: nil
                ))
            }
        }

        return chunks
    }

    // MARK: - Language Patterns

    struct BoundaryPattern {
        let regex: String
        let type: String           // "function" or "class"
        let nameExtractor: (String) -> String?
    }

    static let swiftPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(public |private |internal |open |fileprivate )?(static |class )?(func |init\(|deinit\b)"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:func\s+(\w+)|init\(|deinit)"#) }),
        BoundaryPattern(regex: #"^\s*(public |private |internal |open |fileprivate )?(final )?(class |struct |enum |protocol |extension )"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|struct|enum|protocol|extension)\s+(\w+)"#) }),
    ]

    static let tsPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(export\s+)?(async\s+)?function\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"function\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*(export\s+)?(const|let|var)\s+\w+\s*=\s*(async\s+)?\("#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:const|let|var)\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*(export\s+)?(abstract\s+)?(class|interface|type)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|interface|type)\s+(\w+)"#) }),
    ]

    static let pythonPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(async\s+)?def\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"def\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*class\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"class\s+(\w+)"#) }),
    ]

    static let rustPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(pub\s+)?(async\s+)?fn\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"fn\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*(pub\s+)?(struct|enum|impl|trait)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:struct|enum|impl|trait)\s+(\w+)"#) }),
    ]

    static let goPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^func\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"func\s+(?:\(\w+\s+\*?\w+\)\s+)?(\w+)"#) }),
        BoundaryPattern(regex: #"^type\s+\w+\s+(struct|interface)"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"type\s+(\w+)"#) }),
    ]

    static let dartPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(static\s+)?\w+[\w<>,\s]*\s+\w+\s*\("#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(\w+)\s*\("#) }),
        BoundaryPattern(regex: #"^\s*(abstract\s+)?(class|mixin)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|mixin)\s+(\w+)"#) }),
    ]

    static let javaPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(public |private |protected )?(static )?\w+[\w<>,\s]*\s+\w+\s*\("#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(\w+)\s*\("#) }),
        BoundaryPattern(regex: #"^\s*(public |private |protected )?(abstract )?(class|interface|enum)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|interface|enum)\s+(\w+)"#) }),
    ]

    // MARK: - Chunking Logic

    private static let maxChunkLines = 100
    private static let minChunkLines = 5

    /// Chunk code by detecting boundary lines (function/class declarations).
    private static func chunkByBoundaries(lines: [String], filePath: String, patterns: [BoundaryPattern]) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentLines: [String] = []
        var currentType = "block"
        var currentSymbol: String? = nil
        var currentParent: String? = nil
        var chunkStartLine = 1

        // Detect import/header section (lines before first boundary)
        var headerEnd = 0
        for (i, line) in lines.enumerated() {
            if matchesBoundary(line, patterns: patterns) != nil {
                headerEnd = i
                break
            }
            if i > 30 { headerEnd = i; break }  // Cap header at 30 lines
        }

        if headerEnd > 0 {
            let headerContent = lines[0..<headerEnd].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !headerContent.isEmpty {
                chunks.append(Chunk(
                    chunkType: "header",
                    symbolName: nil,
                    content: headerContent,
                    startLine: 1,
                    endLine: headerEnd
                ))
            }
        }

        // Walk remaining lines
        for i in headerEnd..<lines.count {
            let line = lines[i]

            if let match = matchesBoundary(line, patterns: patterns) {
                // Emit previous chunk
                if !currentLines.isEmpty {
                    emitChunk(
                        lines: currentLines,
                        type: currentType,
                        symbol: currentSymbol,
                        parent: currentParent,
                        startLine: chunkStartLine,
                        into: &chunks
                    )
                }

                // Track parent class for nested symbols
                if match.type == "class" {
                    currentParent = match.name
                }

                currentLines = [line]
                currentType = match.type
                if match.type == "function", let parent = currentParent {
                    currentSymbol = "\(parent).\(match.name ?? "unknown")"
                } else {
                    currentSymbol = match.name
                }
                chunkStartLine = i + 1
            } else {
                currentLines.append(line)

                // Split oversized chunks at blank lines
                if currentLines.count >= maxChunkLines {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        emitChunk(
                            lines: currentLines,
                            type: currentType,
                            symbol: currentSymbol,
                            parent: currentParent,
                            startLine: chunkStartLine,
                            into: &chunks
                        )
                        currentLines = []
                        currentType = "block"
                        currentSymbol = nil
                        chunkStartLine = i + 2
                    }
                }
            }
        }

        // Emit final chunk
        if !currentLines.isEmpty {
            emitChunk(
                lines: currentLines,
                type: currentType,
                symbol: currentSymbol,
                parent: currentParent,
                startLine: chunkStartLine,
                into: &chunks
            )
        }

        return chunks
    }

    /// Fallback: fixed-size chunks for unknown languages.
    private static func chunkByFixedSize(lines: [String], filePath: String) -> [Chunk] {
        var chunks: [Chunk] = []
        let windowSize = 50
        let overlap = 10

        var i = 0
        while i < lines.count {
            let end = min(i + windowSize, lines.count)
            let content = lines[i..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                chunks.append(Chunk(
                    chunkType: "block",
                    symbolName: nil,
                    content: content,
                    startLine: i + 1,
                    endLine: end
                ))
            }
            i += windowSize - overlap
        }

        return chunks
    }

    // MARK: - Helpers

    private struct BoundaryMatch {
        let type: String
        let name: String?
    }

    private static func matchesBoundary(_ line: String, patterns: [BoundaryPattern]) -> BoundaryMatch? {
        for pattern in patterns {
            if line.range(of: pattern.regex, options: .regularExpression) != nil {
                let name = pattern.nameExtractor(line)
                return BoundaryMatch(type: pattern.type, name: name)
            }
        }
        return nil
    }

    private static func extractName(from line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) {
            return String(line[range])
        }
        return nil
    }

    private static func emitChunk(
        lines: [String],
        type: String,
        symbol: String?,
        parent: String?,
        startLine: Int,
        into chunks: inout [Chunk]
    ) {
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 20 else { return }  // Skip trivially small chunks

        // Merge very small chunks by skipping them (they'll be picked up as part of next chunk)
        if lines.count < minChunkLines && type == "block" { return }

        chunks.append(Chunk(
            chunkType: type,
            symbolName: symbol,
            content: content,
            startLine: startLine,
            endLine: startLine + lines.count - 1
        ))
    }

    // MARK: - Language Detection

    /// Detect language from file extension.
    static func detectLanguage(from path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "js": return "javascript"
        case "jsx": return "jsx"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "dart": return "dart"
        case "java": return "java"
        case "md", "markdown": return "markdown"
        default: return nil
        }
    }

    /// Check if a file should be indexed based on extension.
    static func isIndexable(_ path: String) -> Bool {
        return detectLanguage(from: path) != nil
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/CodeChunker.swift
git commit -m "feat: add CodeChunker with language-specific regex heuristics"
```

---

### Task 5: ChunkSearchEngine — Hybrid Vector + FTS5 Search

Search engine that loads embeddings from the database, computes cosine similarity with a query vector, merges with FTS5 keyword results, and returns ranked chunks.

**Files:**
- Create: `Context/Sources/Context/Services/ChunkSearchEngine.swift`

**Step 1: Create ChunkSearchEngine**

Create `Context/Sources/Context/Services/ChunkSearchEngine.swift`:

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
    }

    /// Search for chunks matching a query using hybrid ranking.
    /// - Parameters:
    ///   - queryVector: The embedded query (1536-dim Float array)
    ///   - projectId: Project to search within
    ///   - query: Original query text for FTS5 keyword search
    ///   - limit: Max results (default 10, max 30)
    ///   - types: Optional filter by chunk type
    ///   - db: Database queue to read from
    static func search(
        queryVector: [Float],
        projectId: String,
        query: String,
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

        // 2. Keyword search — FTS5 match
        let keywordResults = try keywordSearch(
            query: query,
            projectId: projectId,
            types: types,
            db: db
        )

        // 3. Merge and rank
        return mergeResults(
            semantic: semanticResults,
            keyword: keywordResults,
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
        // Load all chunks with embeddings for this project
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
            return rows.map { row in
                let chunk = CodeChunk(row: row)
                let path = row["relativePath"] as String
                return (chunk, path)
            }
        }

        // Compute cosine similarity for each
        var scored: [ScoredChunk] = []
        for (chunk, path) in chunks {
            guard let vector = chunk.embeddingVector else { continue }
            let sim = cosineSimilarity(queryVector, vector)
            if sim > 0.3 {  // Minimum threshold
                scored.append(ScoredChunk(chunk: chunk, file: path, score: sim))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(50))  // Keep top 50 for merging
    }

    // MARK: - Keyword Search

    private static func keywordSearch(
        query: String,
        projectId: String,
        types: [String]?,
        db: DatabaseQueue
    ) throws -> [ScoredChunk] {
        return try db.read { conn in
            // FTS5 match query — escape special characters
            let ftsQuery = query
                .replacingOccurrences(of: "\"", with: "\"\"")
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { "\"\($0)\"" }
                .joined(separator: " OR ")

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

            // Normalize BM25 scores to 0-1 range
            let ranks = rows.compactMap { $0["rank"] as? Double }
            let maxRank = ranks.map { abs($0) }.max() ?? 1.0

            return rows.map { row in
                let chunk = CodeChunk(row: row)
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
        limit: Int
    ) -> [SearchResult] {
        // Combine scores: 70% semantic, 30% keyword
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

        let ranked = combined.values
            .map { entry -> (ScoredChunk, Float) in
                let final = (0.7 * entry.semanticScore) + (0.3 * entry.keywordScore)
                return (entry.chunk, final)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)

        return ranked.map { (scored, finalScore) in
            let lines: String? = {
                if let start = scored.chunk.startLine, let end = scored.chunk.endLine {
                    return "\(start)-\(end)"
                }
                return nil
            }()

            return SearchResult(
                file: scored.file,
                symbol: scored.chunk.symbolName,
                type: scored.chunk.chunkType,
                lines: lines,
                score: finalScore,
                content: scored.chunk.content
            )
        }
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

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/ChunkSearchEngine.swift
git commit -m "feat: add ChunkSearchEngine with hybrid vector + FTS5 ranking"
```

---

### Task 6: ContextEngine — Main Orchestrator

The central service that coordinates file watching, chunking, embedding, and indexing. Runs in the GUI app, manages the full lifecycle per project.

**Files:**
- Create: `Context/Sources/Context/Services/ContextEngine.swift`

**Step 1: Create ContextEngine**

Create `Context/Sources/Context/Services/ContextEngine.swift`:

```swift
import Foundation
import GRDB
import CryptoKit

/// Main orchestrator for the context engine. Manages file watching,
/// chunking, embedding, and index lifecycle for the current project.
@MainActor
class ContextEngine: ObservableObject {
    @Published var indexStatus: String = "idle"
    @Published var totalChunks: Int = 0
    @Published var isIndexing: Bool = false
    @Published var lastError: String?

    private let embeddingClient = EmbeddingClient()
    private var fileWatcher: FileWatcher?
    private var currentProjectId: String?
    private var currentProjectPath: String?

    private let skipDirs: Set<String> = [
        "node_modules", ".build", "build", ".dart_tool", "__pycache__",
        ".next", "dist", ".git", ".gradle", "Pods", ".pub-cache",
        ".pub", "ios/Pods", "android/.gradle", ".swiftpm", "DerivedData",
        ".expo", "coverage", "vendor", "target"
    ]

    private let skipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "ico", "webp",
        "woff", "woff2", "ttf", "eot",
        "zip", "tar", "gz", "dmg",
        "mp3", "mp4", "wav", "mov",
        "pdf", "lock", "sum"
    ]

    // MARK: - Public API

    /// Start indexing a project. Call when a project is selected.
    func startIndexing(projectId: String, projectPath: String) {
        guard !isIndexing else { return }

        // Stop watching previous project
        stopWatching()

        currentProjectId = projectId
        currentProjectPath = projectPath

        // Start file watcher
        fileWatcher = FileWatcher(paths: [projectPath], debounceInterval: 2.0) { [weak self] changedPaths in
            guard let self = self else { return }
            Task { @MainActor in
                await self.handleFileChanges(changedPaths)
            }
        }
        fileWatcher?.start()

        // Run initial index
        Task {
            await performFullIndex()
        }
    }

    /// Stop watching and clean up.
    func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    /// Force a full re-index of the current project.
    func rebuildIndex() {
        guard let projectId = currentProjectId, let path = currentProjectPath else { return }
        Task {
            // Clear existing index
            try? DatabaseService.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM codeChunks WHERE projectId = ?", arguments: [projectId])
                try db.execute(sql: "DELETE FROM indexedFiles WHERE projectId = ?", arguments: [projectId])
            }
            await performFullIndex()
        }
    }

    /// Clear the index for the current project.
    func clearIndex() {
        guard let projectId = currentProjectId else { return }
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM codeChunks WHERE projectId = ?", arguments: [projectId])
                try db.execute(sql: "DELETE FROM indexedFiles WHERE projectId = ?", arguments: [projectId])
                try db.execute(sql: "DELETE FROM indexState WHERE projectId = ?", arguments: [projectId])
            }
            indexStatus = "idle"
            totalChunks = 0
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Full Index

    private func performFullIndex() async {
        guard let projectId = currentProjectId, let projectPath = currentProjectPath else { return }

        // Check API key
        guard ClaudeService.openRouterAPIKey != nil else {
            lastError = "OpenRouter API key not configured"
            return
        }

        isIndexing = true
        indexStatus = "indexing"
        lastError = nil
        updateIndexState(projectId: projectId, status: "indexing")

        do {
            // 1. Enumerate files
            let files = enumerateFiles(at: projectPath)

            // 2. Process each file
            var processedChunks = 0
            var pendingChunks: [(CodeChunk, String)] = []  // (chunk without embedding, text to embed)

            for (relativePath, fileURL) in files {
                let content: String
                do {
                    content = try String(contentsOf: fileURL, encoding: .utf8)
                } catch {
                    continue  // Skip unreadable files
                }

                // Check content hash
                let hash = sha256(content)
                let existingFile = try? DatabaseService.shared.dbQueue.read { db in
                    try IndexedFile
                        .filter(Column("projectId") == projectId && Column("relativePath") == relativePath)
                        .fetchOne(db)
                }

                if let existing = existingFile, existing.contentHash == hash {
                    continue  // File unchanged, skip
                }

                // Delete old chunks for this file if it existed
                if let existing = existingFile {
                    try? DatabaseService.shared.dbQueue.write { db in
                        try db.execute(sql: "DELETE FROM codeChunks WHERE fileId = ?", arguments: [existing.id])
                    }
                }

                // Chunk the file
                let language = CodeChunker.detectLanguage(from: relativePath)
                let chunks: [CodeChunker.Chunk]

                if language == "markdown" {
                    chunks = CodeChunker.chunkMarkdown(content: content, filePath: relativePath)
                } else if let lang = language {
                    chunks = CodeChunker.chunkFile(content: content, language: lang, filePath: relativePath)
                } else {
                    continue  // Skip unknown file types
                }

                // Create/update IndexedFile record
                let fileId = existingFile?.id ?? UUID().uuidString
                let indexedFile = IndexedFile(
                    id: fileId,
                    projectId: projectId,
                    relativePath: relativePath,
                    contentHash: hash,
                    language: language,
                    lastIndexedAt: Date()
                )
                try DatabaseService.shared.dbQueue.write { db in
                    try indexedFile.save(db)
                }

                // Queue chunks for embedding
                for chunk in chunks {
                    let codeChunk = CodeChunk(
                        id: UUID().uuidString,
                        fileId: fileId,
                        projectId: projectId,
                        chunkType: chunk.chunkType,
                        symbolName: chunk.symbolName,
                        content: chunk.content,
                        startLine: chunk.startLine,
                        endLine: chunk.endLine,
                        embedding: nil
                    )
                    pendingChunks.append((codeChunk, chunk.content))

                    // Batch embed when we hit 20
                    if pendingChunks.count >= 20 {
                        processedChunks += try await embedAndStore(pendingChunks)
                        pendingChunks.removeAll()

                        await MainActor.run {
                            self.totalChunks = processedChunks
                        }
                    }
                }
            }

            // Embed remaining chunks
            if !pendingChunks.isEmpty {
                processedChunks += try await embedAndStore(pendingChunks)
            }

            // 3. Index git history
            processedChunks += await indexGitHistory(projectId: projectId, projectPath: projectPath)

            // 4. Clean up orphaned files
            try cleanupOrphanedFiles(projectId: projectId, projectPath: projectPath)

            // 5. Update state
            totalChunks = processedChunks
            indexStatus = "ready"
            isIndexing = false
            updateIndexState(projectId: projectId, status: "ready", totalChunks: processedChunks)

        } catch {
            lastError = error.localizedDescription
            indexStatus = "error"
            isIndexing = false
            updateIndexState(projectId: projectId, status: "error", error: error.localizedDescription)
        }
    }

    // MARK: - Incremental Update

    private func handleFileChanges(_ changedPaths: [String]) async {
        guard let projectId = currentProjectId, let projectPath = currentProjectPath else { return }
        guard !isIndexing else { return }  // Don't interrupt full index

        for path in changedPaths {
            // Filter to project directory
            guard path.hasPrefix(projectPath) else { continue }
            let relativePath = String(path.dropFirst(projectPath.count + 1))

            // Skip non-indexable files
            guard shouldIndex(relativePath: relativePath) else { continue }

            let fileURL = URL(fileURLWithPath: path)
            let fm = FileManager.default

            if fm.fileExists(atPath: path) {
                // File created or modified
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let hash = sha256(content)

                // Check if unchanged
                let existing = try? DatabaseService.shared.dbQueue.read { db in
                    try IndexedFile
                        .filter(Column("projectId") == projectId && Column("relativePath") == relativePath)
                        .fetchOne(db)
                }

                if let existing = existing, existing.contentHash == hash { continue }

                // Re-index this file
                if let existing = existing {
                    try? DatabaseService.shared.dbQueue.write { db in
                        try db.execute(sql: "DELETE FROM codeChunks WHERE fileId = ?", arguments: [existing.id])
                    }
                }

                let language = CodeChunker.detectLanguage(from: relativePath)
                let chunks: [CodeChunker.Chunk]

                if language == "markdown" {
                    chunks = CodeChunker.chunkMarkdown(content: content, filePath: relativePath)
                } else if let lang = language {
                    chunks = CodeChunker.chunkFile(content: content, language: lang, filePath: relativePath)
                } else {
                    continue
                }

                let fileId = existing?.id ?? UUID().uuidString
                let indexedFile = IndexedFile(
                    id: fileId,
                    projectId: projectId,
                    relativePath: relativePath,
                    contentHash: hash,
                    language: language,
                    lastIndexedAt: Date()
                )

                try? DatabaseService.shared.dbQueue.write { db in
                    try indexedFile.save(db)
                }

                var pendingChunks: [(CodeChunk, String)] = chunks.map { chunk in
                    let codeChunk = CodeChunk(
                        id: UUID().uuidString,
                        fileId: fileId,
                        projectId: projectId,
                        chunkType: chunk.chunkType,
                        symbolName: chunk.symbolName,
                        content: chunk.content,
                        startLine: chunk.startLine,
                        endLine: chunk.endLine,
                        embedding: nil
                    )
                    return (codeChunk, chunk.content)
                }

                if !pendingChunks.isEmpty {
                    _ = try? await embedAndStore(pendingChunks)
                }

                // Update total count
                updateTotalChunks(projectId: projectId)

            } else {
                // File deleted
                if let existing = try? DatabaseService.shared.dbQueue.read({ db in
                    try IndexedFile
                        .filter(Column("projectId") == projectId && Column("relativePath") == relativePath)
                        .fetchOne(db)
                }) {
                    try? DatabaseService.shared.dbQueue.write { db in
                        try db.execute(sql: "DELETE FROM codeChunks WHERE fileId = ?", arguments: [existing.id])
                        try existing.delete(db)
                    }
                    updateTotalChunks(projectId: projectId)
                }
            }
        }
    }

    // MARK: - Git History Indexing

    private func indexGitHistory(projectId: String, projectPath: String) async -> Int {
        // Check if git repo
        let gitDir = (projectPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else { return 0 }

        // Run git log
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["log", "--oneline", "--stat", "-200"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let gitLog = String(data: data, encoding: .utf8), !gitLog.isEmpty else { return 0 }

        let chunks = CodeChunker.chunkGitHistory(gitLog)
        guard !chunks.isEmpty else { return 0 }

        // Use a special fileId for git history
        let gitFileId = "\(projectId)__git_history"

        // Delete existing git chunks
        try? DatabaseService.shared.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM codeChunks WHERE fileId = ?", arguments: [gitFileId])
            // Ensure IndexedFile record exists for git history
            let gitFile = IndexedFile(
                id: gitFileId,
                projectId: projectId,
                relativePath: ".git/history",
                contentHash: sha256(gitLog),
                language: nil,
                lastIndexedAt: Date()
            )
            try gitFile.save(db)
        }

        var pendingChunks: [(CodeChunk, String)] = chunks.map { chunk in
            let codeChunk = CodeChunk(
                id: UUID().uuidString,
                fileId: gitFileId,
                projectId: projectId,
                chunkType: chunk.chunkType,
                symbolName: chunk.symbolName,
                content: chunk.content,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                embedding: nil
            )
            return (codeChunk, chunk.content)
        }

        return (try? await embedAndStore(pendingChunks)) ?? 0
    }

    // MARK: - Helpers

    private func embedAndStore(_ chunks: [(CodeChunk, String)]) async throws -> Int {
        let texts = chunks.map { $0.1 }
        let result = await embeddingClient.embedBatch(texts)

        try DatabaseService.shared.dbQueue.write { db in
            for (i, (var chunk, _)) in chunks.enumerated() {
                if i < result.embeddings.count && !result.embeddings[i].isEmpty {
                    chunk.embedding = CodeChunk.encodeEmbedding(result.embeddings[i])
                }
                try chunk.insert(db)
            }
        }

        return chunks.count
    }

    private func enumerateFiles(at path: String) -> [(String, URL)] {
        let fm = FileManager.default
        var results: [(String, URL)] = []

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: path + "/", with: "")

            // Skip directories
            if skipDirs.contains(where: { relativePath.hasPrefix($0 + "/") || relativePath == $0 }) {
                continue
            }

            // Skip non-indexable extensions
            let ext = fileURL.pathExtension.lowercased()
            if skipExtensions.contains(ext) { continue }

            // Only index known file types
            guard shouldIndex(relativePath: relativePath) else { continue }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            results.append((relativePath, fileURL))
        }

        return results
    }

    private func shouldIndex(relativePath: String) -> Bool {
        // Check skip dirs
        if skipDirs.contains(where: { relativePath.hasPrefix($0 + "/") }) { return false }

        // Check extension
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if skipExtensions.contains(ext) { return false }

        return CodeChunker.isIndexable(relativePath)
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupOrphanedFiles(projectId: String, projectPath: String) throws {
        let indexed = try DatabaseService.shared.dbQueue.read { db in
            try IndexedFile.filter(Column("projectId") == projectId).fetchAll(db)
        }

        let fm = FileManager.default
        for file in indexed {
            if file.relativePath == ".git/history" { continue }  // Special case
            let fullPath = (projectPath as NSString).appendingPathComponent(file.relativePath)
            if !fm.fileExists(atPath: fullPath) {
                try DatabaseService.shared.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM codeChunks WHERE fileId = ?", arguments: [file.id])
                    try file.delete(db)
                }
            }
        }
    }

    private func updateIndexState(projectId: String, status: String, totalChunks: Int? = nil, error: String? = nil) {
        try? DatabaseService.shared.dbQueue.write { db in
            var state = try IndexState.fetchOne(db, key: projectId) ?? IndexState(
                projectId: projectId,
                status: status,
                totalChunks: 0
            )
            state.status = status
            if let total = totalChunks { state.totalChunks = total }
            if let error = error { state.lastError = error }
            if status == "ready" { state.lastFullIndexAt = Date() }
            try state.save(db)
        }
    }

    private func updateTotalChunks(projectId: String) {
        let count = try? DatabaseService.shared.dbQueue.read { db in
            try CodeChunk.filter(Column("projectId") == projectId).fetchCount(db)
        }
        if let count = count {
            totalChunks = count
            updateIndexState(projectId: projectId, status: "ready", totalChunks: count)
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/ContextEngine.swift
git commit -m "feat: add ContextEngine orchestrator with full and incremental indexing"
```

---

### Task 7: App Integration — Wire ContextEngine into the App

Initialize ContextEngine in ContextApp, trigger indexing on project selection, and update the Settings UI.

**Files:**
- Modify: `Context/Sources/Context/ContextApp.swift`
- Modify: `Context/Sources/Context/Services/AppSettings.swift`
- Modify: `Context/Sources/Context/Views/SettingsView.swift`

**Step 1: Add AppSettings properties**

In `AppSettings.swift`, add two new properties after `gmailSyncInterval`:

```swift
@Published var contextSearchEnabled: Bool {
    didSet { UserDefaults.standard.set(contextSearchEnabled, forKey: "contextSearchEnabled") }
}
@Published var embeddingModel: String {
    didSet { UserDefaults.standard.set(embeddingModel, forKey: "embeddingModel") }
}
```

And in `init()`, add after the `gmailSyncInterval` initialization:

```swift
self.contextSearchEnabled = defaults.object(forKey: "contextSearchEnabled") as? Bool ?? true
self.embeddingModel = defaults.string(forKey: "embeddingModel") ?? "openai/text-embedding-3-small"
```

**Step 2: Add ContextEngine to ContextApp**

In `ContextApp.swift`, add a new `@StateObject`:

```swift
@StateObject private var contextEngine = ContextEngine()
```

Add it as an environment object:

```swift
.environmentObject(contextEngine)
```

In the `.onChange(of: appState.currentProject)` handler, after `githubService.startMonitoring(...)`, add:

```swift
if appSettings.contextSearchEnabled {
    contextEngine.startIndexing(projectId: project.id, projectPath: project.path)
}
```

**Step 3: Update SettingsView — Context Engine tab**

Replace the `ContextEngineSettingsTab` struct in `SettingsView.swift` with:

```swift
private struct ContextEngineSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject var contextEngine: ContextEngine
    @State private var apiKey: String = ClaudeService.openRouterAPIKey ?? ""

    var body: some View {
        Form {
            Section("OpenRouter API") {
                SecureField("API Key (sk-or-...)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, val in
                        ClaudeService.openRouterAPIKey = val.isEmpty ? nil : val
                    }
                HStack {
                    Circle()
                        .fill(apiKey.isEmpty ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    Text(apiKey.isEmpty ? "No API key set" : "API key configured")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Code Search") {
                Toggle("Enable context search", isOn: $settings.contextSearchEnabled)

                Picker("Embedding Model", selection: $settings.embeddingModel) {
                    Text("text-embedding-3-small").tag("openai/text-embedding-3-small")
                    Text("text-embedding-3-large").tag("openai/text-embedding-3-large")
                }

                HStack {
                    Text("Index Status:")
                        .font(.system(size: 12))
                    Text(contextEngine.indexStatus.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(statusColor)
                    if contextEngine.isIndexing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }

                if contextEngine.totalChunks > 0 {
                    Text("\(contextEngine.totalChunks) chunks indexed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let error = contextEngine.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }

                HStack {
                    Button("Rebuild Index") { contextEngine.rebuildIndex() }
                        .disabled(contextEngine.isIndexing)
                    Button("Clear Index") { contextEngine.clearIndex() }
                        .disabled(contextEngine.isIndexing)
                }
            }

            Section("Automation") {
                Toggle("Auto-snapshot sessions", isOn: $settings.autoSnapshotSessions)
                Toggle("Auto-update codebase tree", isOn: $settings.autoUpdateCodebaseTree)
                Toggle("MCP server auto-start", isOn: $settings.mcpServerAutoStart)
                Toggle("CLAUDE.md injection", isOn: $settings.claudeMDInjection)

                HStack {
                    Text("Snapshot debounce: \(Int(settings.snapshotDebounce))s")
                    Slider(
                        value: $settings.snapshotDebounce,
                        in: 5...120,
                        step: 5
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statusColor: Color {
        switch contextEngine.indexStatus {
        case "ready": return .green
        case "indexing": return .orange
        case "error": return .red
        default: return .secondary
        }
    }
}
```

**Step 4: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 5: Commit**

```bash
git add Context/Sources/Context/ContextApp.swift Context/Sources/Context/Services/AppSettings.swift Context/Sources/Context/Views/SettingsView.swift
git commit -m "feat: integrate ContextEngine into app lifecycle and settings UI"
```

---

### Task 8: MCP Tool — context_search on ScopeMCP

Add the `context_search` tool definition, dispatch case, and handler to the existing MCP server. The MCP server embeds the query, runs hybrid search, and returns ranked results.

**Files:**
- Modify: `Context/Sources/ScopeMCP/main.swift`

**Step 1: Add CodeChunk model to ScopeMCP**

Near the top of `main.swift`, after the existing `TaskNote` struct (around line 78), add the lightweight model copies needed by the MCP server:

```swift
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
```

**Step 2: Add tool definition**

In the `listTools()` method, add after the last browser tool definition:

```swift
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
```

**Step 3: Add dispatch case**

In `handleToolCall`, add after the last `browser_clear_session` case:

```swift
case "context_search":     result = try contextSearch(args)
```

**Step 4: Add handler function**

Add the handler function (after the browser handler functions):

```swift
// MARK: - Context Engine

func contextSearch(_ args: [String: Any]?) throws -> String {
    guard let query = args?["query"] as? String, !query.isEmpty else {
        throw MCPError(message: "Missing required parameter: query")
    }

    let limit = args?["limit"] as? Int ?? 10
    let types = args?["types"] as? [String]

    guard let projectId = projectId else {
        throw MCPError(message: "No project detected. Run from within a project directory.")
    }

    // Check index state
    let state = try db.read { conn in
        try IndexState.fetchOne(conn, key: projectId)
    }

    let indexStatus = state?.status ?? "not_indexed"

    if indexStatus == "not_indexed" || state == nil {
        return formatJSON([
            "results": [] as [Any],
            "index_status": "not_indexed",
            "message": "Project not yet indexed. Open the project in Scope.app to start indexing."
        ])
    }

    // Get API key for query embedding
    guard let apiKey = UserDefaults.standard.string(forKey: "openRouterAPIKey"), !apiKey.isEmpty else {
        throw MCPError(message: "OpenRouter API key not configured. Set it in Scope.app Settings > Context Engine.")
    }

    let model = UserDefaults.standard.string(forKey: "embeddingModel") ?? "openai/text-embedding-3-small"

    // Embed the query
    let queryVector = try embedQuery(query: query, apiKey: apiKey, model: model)

    // Load all chunks with embeddings for this project
    let chunks: [(CodeChunk, String)] = try db.read { conn in
        var sql = """
            SELECT c.*, f.relativePath
            FROM codeChunks c
            JOIN indexedFiles f ON c.fileId = f.id
            WHERE c.projectId = ?
        """
        var arguments: [DatabaseValueConvertible] = [projectId]

        if let types = types, !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ", ")
            sql += " AND c.chunkType IN (\(placeholders))"
            arguments.append(contentsOf: types)
        }

        let rows = try Row.fetchAll(conn, sql: sql, arguments: StatementArguments(arguments))
        return rows.map { row in
            let chunk = CodeChunk(row: row)
            let path = row["relativePath"] as String
            return (chunk, path)
        }
    }

    // Compute cosine similarity
    var results: [(path: String, chunk: CodeChunk, score: Float)] = []

    for (chunk, path) in chunks {
        guard let vector = chunk.embeddingVector else { continue }
        let sim = cosineSimilarity(queryVector, vector)
        if sim > 0.3 {
            results.append((path, chunk, sim))
        }
    }

    // Also do FTS5 keyword search
    let ftsQuery = query
        .replacingOccurrences(of: "\"", with: "\"\"")
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .map { "\"\($0)\"" }
        .joined(separator: " OR ")

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
            return rows.map { row in
                let chunk = CodeChunk(row: row)
                let path = row["relativePath"] as String
                let rank = row["rank"] as? Double ?? 0
                return (chunk, path, rank)
            }
        }) ?? []

        // Merge FTS results with semantic results
        let maxRank = ftsRows.map { abs($0.2) }.max() ?? 1.0
        let existingIds = Set(results.map { $0.chunk.id })

        for (chunk, path, rank) in ftsRows {
            let normalizedScore = Float(abs(rank) / max(maxRank, 0.001))
            if existingIds.contains(chunk.id) {
                // Boost existing semantic result with keyword score
                if let idx = results.firstIndex(where: { $0.chunk.id == chunk.id }) {
                    results[idx].score = (0.7 * results[idx].score) + (0.3 * normalizedScore)
                }
            } else {
                // Add keyword-only result
                results.append((path, chunk, 0.3 * normalizedScore))
            }
        }
    }

    // Sort by score, take top N
    results.sort { $0.score > $1.score }
    let topResults = results.prefix(min(limit, 30))

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
        return result
    }

    return formatJSON([
        "results": formatted,
        "index_status": indexStatus,
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
    request.setValue("Context App", forHTTPHeaderField: "X-Title")
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
```

**Step 5: Build both products**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Then verify tool count:

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build --product ScopeMCP 2>&1`

Expected: `Build complete!`

**Step 6: Commit**

```bash
git add Context/Sources/ScopeMCP/main.swift
git commit -m "feat: add context_search MCP tool with hybrid vector + keyword search"
```

---

### Task 9: Settings Migration — Move OpenRouter Key from Chat Popover

Move the OpenRouter API key configuration from the chat drawer's settings popover to the main Settings window (already done in Task 7). Update the chat popover to link to Settings instead.

**Files:**
- Modify: `Context/Sources/Context/Views/Chat/ChatDrawerView.swift`

**Step 1: Update ChatSettingsPopover**

In `ChatDrawerView.swift`, replace the `ChatSettingsPopover` struct (around line 442) with a simplified version that points to Settings:

```swift
private struct ChatSettingsPopover: View {
    @State private var selectedModel: String = ClaudeService.openRouterModel

    private let models = [
        ("google/gemini-3.1-pro-preview", "Gemini 3.1 Pro"),
        ("anthropic/claude-sonnet-4", "Claude Sonnet 4"),
        ("openai/gpt-4o", "GPT-4o"),
        ("anthropic/claude-haiku-4", "Claude Haiku 4"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat Settings")
                .font(.system(size: 13, weight: .semibold))

            GroupBox("Model") {
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.0) { (id, label) in
                        Text(label).tag(id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedModel) { _, newValue in
                    ClaudeService.openRouterModel = newValue
                }
            }

            GroupBox("API Key") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(ClaudeService.openRouterAPIKey?.isEmpty == false ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(ClaudeService.openRouterAPIKey?.isEmpty == false ? "API key configured" : "No API key set")
                            .font(.system(size: 11))
                    }
                    Text("Configure in Settings \u{2192} Context Engine")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(4)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Chat/ChatDrawerView.swift
git commit -m "refactor: move OpenRouter API key config to main Settings, simplify chat popover"
```

---

### Task 10: Build, Verify, and Final Review

Build both products, verify the tool count, and do a final holistic check.

**Step 1: Clean build both products**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Expected: `Build complete!`

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build --product ScopeMCP 2>&1`

Expected: `Build complete!`

**Step 2: Verify MCP tool count**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build --product ScopeMCP 2>&1 && .build/debug/ScopeMCP 2>/dev/null &; sleep 1; echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | timeout 2 cat - | head -1`

Or manually count: should be 22 tools (21 existing + 1 `context_search`).

**Step 3: Review all new files**

Verify these files exist and are correct:
- `Context/Sources/Context/Models/IndexedFile.swift`
- `Context/Sources/Context/Models/CodeChunk.swift`
- `Context/Sources/Context/Models/IndexState.swift`
- `Context/Sources/Context/Services/EmbeddingClient.swift`
- `Context/Sources/Context/Services/CodeChunker.swift`
- `Context/Sources/Context/Services/ChunkSearchEngine.swift`
- `Context/Sources/Context/Services/ContextEngine.swift`

**Step 4: Review all modified files**

Verify changes in:
- `Context/Sources/Context/Services/DatabaseService.swift` (migration v15)
- `Context/Sources/Context/Services/AppSettings.swift` (2 new properties)
- `Context/Sources/Context/Views/SettingsView.swift` (Context Engine tab redesign)
- `Context/Sources/Context/ContextApp.swift` (ContextEngine integration)
- `Context/Sources/ScopeMCP/main.swift` (context_search tool)
- `Context/Sources/Context/Views/Chat/ChatDrawerView.swift` (simplified popover)
