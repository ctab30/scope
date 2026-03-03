# Context Engine Design

## Overview

A local semantic code search engine that replaces Augment MCP's `codebase-retrieval` tool. Indexes code, documentation, and git history for the current project, generates embeddings via OpenRouter, and exposes a `context_search` MCP tool for Claude Code to query.

**Goal:** Give Claude Code fast, semantic understanding of any project's codebase without external dependencies or subscriptions.

**Key decisions:**

- **Embedding model:** `openai/text-embedding-3-small` via OpenRouter API (1536 dimensions, ~$0.02/1M tokens)
- **Index scope:** Current project only (indexed on project open, updated via FSEvents)
- **MCP topology:** New `context_search` tool on existing ScopeMCP server
- **Chunking:** Smart line-based regex heuristics (no Tree-sitter dependency)
- **Vector storage:** Raw BLOBs in SQLite + cosine similarity in Swift
- **Content indexed:** Code files + markdown/docs + git commit history

---

## Architecture

The GUI app (long-running process) owns the indexing pipeline. The MCP server reads the pre-computed index for search.

```
                    GUI App (long-running)
                    +-----------------------------+
                    |                             |
  File changes ---> |  ContextEngine              |
  (FSEvents)        |    |                        |
                    |    +- CodeChunker            |
                    |    |   (regex split)         |
                    |    |                         |
                    |    +- EmbeddingClient --HTTP--> OpenRouter
                    |    |   (batch embed)         |   /embeddings
                    |    |                         |
                    |    +- GRDB writes ------+    |
                    |                         |    |
                    |  ChunkSearchEngine      |    |
                    |    (cosine + FTS5)  <---+    |
                    +-----------------------------+
                                  ^
                                  | Shared SQLite (WAL)
                                  v
                    +-----------------------------+
                    |  ScopeMCP                  |
                    |                             |
                    |  context_search tool         |
                    |    -> reads codeChunks       |
                    |    -> loads embeddings       |
                    |    -> cosine similarity      |
                    |    -> returns ranked results |
                    +-----------------------------+
```

The MCP server performs search in-process (not via SQLite IPC queue) because the query embedding + cosine similarity must happen synchronously in the MCP request/response cycle.

---

## Data Model

Three new tables in the existing `context.db` (GRDB + SQLite):

### `indexedFiles`

Tracks which files are indexed and their content state.

| Column | Type | Purpose |
|--------|------|---------|
| id | TEXT PK | UUID |
| projectId | TEXT FK | Which project |
| relativePath | TEXT | Path relative to project root |
| contentHash | TEXT | SHA-256 of file content (skip re-chunking if unchanged) |
| language | TEXT | swift, typescript, python, etc. |
| lastIndexedAt | DATE | When this file was last processed |

### `codeChunks`

The searchable units with their embeddings.

| Column | Type | Purpose |
|--------|------|---------|
| id | TEXT PK | UUID |
| fileId | TEXT FK | Parent indexedFile |
| projectId | TEXT FK | For fast project-scoped queries |
| chunkType | TEXT | "function", "class", "block", "doc", "commit" |
| symbolName | TEXT | e.g. "BrowserTab.uploadFile" (nullable for blocks/docs/commits) |
| content | TEXT | The actual code/text |
| startLine | INT | Line number in file (nullable for commits) |
| endLine | INT | End line (nullable for commits) |
| embedding | BLOB | 1536 floats as raw bytes (~6KB per chunk) |

### `indexState`

Per-project index metadata.

| Column | Type | Purpose |
|--------|------|---------|
| projectId | TEXT PK | One row per project |
| status | TEXT | "idle", "indexing", "ready", "error" |
| lastFullIndexAt | DATE | Last complete index build |
| totalChunks | INT | Quick count for UI display |
| lastError | TEXT | Error message if indexing failed |

### FTS5 Virtual Table

`codeChunksFts` synced to `codeChunks.content` + `codeChunks.symbolName` for keyword search fallback.

### Storage Estimate

A 500-file project with ~3,000 chunks at 6KB per embedding = ~18MB of vectors. Manageable within SQLite.

---

## Chunking Strategy

Smart line-based chunker using regex heuristics per language. No external dependencies.

### Process

1. Read file content
2. Detect language from file extension
3. Walk lines, detecting boundaries with language-specific patterns
4. Emit chunks with metadata (symbol name, type, line range)

### Language Patterns

| Language | Function boundary | Class boundary | Other |
|----------|------------------|----------------|-------|
| Swift | `func `, `init(`, `deinit` | `class `, `struct `, `enum `, `protocol `, `extension ` | `// MARK:` sections |
| TypeScript/JS | `function `, `=> {`, `async ` | `class `, `interface `, `type ` | `export default` |
| Python | `def `, `async def ` | `class ` | Decorators `@` grouped with their function |
| Rust | `fn `, `pub fn ` | `struct `, `enum `, `impl `, `trait ` | `mod ` |
| Go | `func ` | `type ... struct`, `type ... interface` | -- |
| Dart | method signatures | `class `, `mixin ` | -- |
| Java | method signatures | `class `, `interface `, `enum ` | -- |

### Chunking Rules

- **Max chunk size:** ~100 lines. Longer functions split at logical breaks (blank lines, inner blocks)
- **Min chunk size:** 5 lines. Very small functions merged with adjacent ones
- **Context preservation:** Each chunk includes the parent class/struct name in `symbolName` (e.g., `BrowserTab.uploadFile`)
- **Imports/headers:** File-level imports become a single "header" chunk per file
- **Orphan lines:** Code between detected boundaries grouped into "block" chunks

### Non-Code Content

- **Markdown/docs:** Split at `## ` headings. Each section = one chunk
- **Git commits:** Each commit message + diff stat = one chunk. Cap at last 200 commits. Refreshed on git activity via FSEvents watching `.git/`

### Skip List

Reuse `ProjectAnalyzer`'s existing skip list: `node_modules`, `.build`, `__pycache__`, `.next`, `dist`, `.gradle`, etc. Plus binary files, images, lock files.

---

## Indexing Pipeline

### Startup Flow

```
Project selected
  -> Check indexState for this project
  -> If no index exists: full index
  -> If index exists: incremental update (compare contentHash)
  -> Start FSEvents watcher for project directory
```

### Full Index Flow

1. Set `indexState.status = "indexing"`
2. Enumerate all files (reuse ProjectAnalyzer's file walker + skip list)
3. For each file:
   a. Compute SHA-256 hash
   b. Check if indexedFile exists with same hash -> skip
   c. Chunk the file (language-specific splitter)
   d. Batch chunks (collect up to ~20 chunks)
   e. Send batch to OpenRouter `/embeddings` endpoint
   f. Store chunks + embeddings in database
   g. Update/insert indexedFile record
4. Index git commits (last 200, if not already indexed)
5. Delete orphaned indexedFiles (files that no longer exist on disk)
6. Set `indexState.status = "ready"`

### Incremental Update Flow

Triggered by FSEvents file change, debounced 2 seconds:

1. Compute new contentHash
2. If hash matches indexedFile -> ignore
3. If changed:
   a. Delete old codeChunks for this file
   b. Re-chunk the file
   c. Embed new chunks via OpenRouter
   d. Insert new chunks + update indexedFile hash
4. If file deleted:
   a. Delete indexedFile + its codeChunks

### Embedding Batching

OpenRouter's `/embeddings` endpoint accepts an array of strings. Batch up to 20 chunks per request (~4,000 tokens per request at ~200 tokens per chunk).

### Error Handling

- **API rate limit / network error:** Retry with exponential backoff (3 attempts)
- **Chunk embedding failure:** Store chunk without embedding (FTS5 keyword search still works)
- **Full index failure:** Set `indexState.status = "error"` with message
- **Individual file failure:** Skip gracefully, don't block remaining files

### Cost Control

- `contentHash` comparison: unchanged files are never re-embedded
- Debounce: prevents rapid re-indexing during active editing
- Git commits: indexed once, only new commits added on refresh
- Estimated cost: ~$0.02 for initial index of a 500-file project

---

## Search & Ranking

Hybrid search combining semantic (vector) and keyword (FTS5) results.

### Search Flow

```
Query string arrives
  -> 1. Embed query via OpenRouter /embeddings (single string)
  -> 2. Cosine similarity against all codeChunks.embedding for this project
  -> 3. FTS5 match against codeChunksFts
  -> 4. Merge & re-rank results
  -> 5. Return top N chunks with context
```

### Cosine Similarity

Computed in Swift at query time:

```swift
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, normA: Float = 0, normB: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    return dot / (sqrt(normA) * sqrt(normB))
}
```

For 3,000 chunks at 1536 dimensions: ~10ms on Apple Silicon.

### Hybrid Ranking

```
finalScore = (0.7 * semanticScore) + (0.3 * keywordScore)
```

- `semanticScore`: cosine similarity (0.0-1.0), handles conceptual queries
- `keywordScore`: FTS5 BM25 rank normalized to 0.0-1.0, handles exact matches

Results with only a keyword match (no embedding) still surface with the keyword score only.

### MCP Tool Definition

```json
{
  "name": "context_search",
  "description": "Semantic code search across the current project. Finds functions, classes, documentation, and git history matching a natural language query.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Natural language description of what you're looking for"
      },
      "limit": {
        "type": "integer",
        "description": "Max results to return (default 10, max 30)"
      },
      "types": {
        "type": "array",
        "items": { "type": "string", "enum": ["function", "class", "block", "doc", "commit"] },
        "description": "Filter by chunk type (optional, defaults to all)"
      }
    },
    "required": ["query"]
  }
}
```

### Response Format

```json
{
  "results": [
    {
      "file": "Sources/Context/Views/Browser/BrowserTab.swift",
      "symbol": "BrowserTab.uploadFile",
      "type": "function",
      "lines": "245-280",
      "score": 0.87,
      "content": "func uploadFile(ref: String, fileData: String, ...) async throws -> String { ... }"
    }
  ],
  "index_status": "ready",
  "total_chunks": 3042
}
```

---

## Settings & API Key Management

### OpenRouter API Key

Move from chat popover (`ChatDrawerView`) to main Settings window. The key stays in `UserDefaults` as `openRouterAPIKey` — same storage, just relocating the UI.

`ClaudeService.openRouterAPIKey` remains the single accessor. Both chat and context engine read from it.

The chat popover's settings section gets replaced with a link to Settings.

### New AppSettings Properties

```swift
@Published var contextSearchEnabled: Bool    // default true
@Published var embeddingModel: String         // default "openai/text-embedding-3-small"
```

### Context Engine Settings Tab Layout

The existing "Context Engine" tab in Settings gets reorganized:

- **OpenRouter API section:** API key field, connection status
- **Code Search section:** Embedding model picker, index status, rebuild/clear buttons
- **Automation section:** Existing toggles (auto-snapshot, auto-update, MCP auto-start, CLAUDE.md injection, debounce)

---

## Files

### New Files

| File | Purpose |
|------|---------|
| `Services/ContextEngine.swift` | Main orchestrator -- indexing lifecycle, file watching, triggers re-indexing |
| `Services/CodeChunker.swift` | Splits files into semantic chunks using regex heuristics per language |
| `Services/EmbeddingClient.swift` | HTTP client for OpenRouter /embeddings endpoint, batching, retries |
| `Services/ChunkSearchEngine.swift` | Hybrid search -- loads embeddings, cosine similarity, merges with FTS5 |
| `Models/IndexedFile.swift` | GRDB model for `indexedFiles` table |
| `Models/CodeChunk.swift` | GRDB model for `codeChunks` table |
| `Models/IndexState.swift` | GRDB model for `indexState` table |

### Modified Files

| File | Change |
|------|--------|
| `Services/DatabaseService.swift` | Add migrations for 3 new tables + FTS5 virtual table |
| `Services/AppSettings.swift` | Add `contextSearchEnabled`, `embeddingModel` properties |
| `Views/SettingsView.swift` | Reorganize Context Engine tab with OpenRouter key + search config |
| `Views/Chat/ChatDrawerView.swift` | Replace inline API key popover with link to Settings |
| `ContextApp.swift` | Initialize `ContextEngine`, pass to views |
| `Sources/ScopeMCP/main.swift` | Add `context_search` tool definition, dispatch, and handler |

---

## Error States

| Condition | Behavior |
|-----------|----------|
| No OpenRouter API key | Index skipped, `context_search` returns error: "OpenRouter API key not configured" |
| GUI app not running | MCP searches stale index (last known state), returns `index_status: "stale"` |
| Project not yet indexed | MCP returns empty results with `index_status: "not_indexed"` |
| Embedding API down | Chunks stored without embeddings, FTS5 keyword search still works |
| File deleted mid-index | Gracefully skip, clean up on next incremental pass |
