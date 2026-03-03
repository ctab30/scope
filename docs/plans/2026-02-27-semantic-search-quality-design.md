# Semantic Search Quality Enhancement — Design

## Problem

The context engine's `context_search` returns results but ranking quality is inconsistent. Natural language queries miss key code, symbol lookups return irrelevant chunks, and noisy results (boilerplate, headers, test files) dilute useful matches. The fixed 70/30 semantic/keyword weighting doesn't adapt to different query types.

## Solution

Two-layer improvement: (1) smarter scoring and filtering in ChunkSearchEngine, and (2) a new QueryPreprocessor that understands the query before searching.

## Architecture

```
User query
    → QueryPreprocessor
        1. Classify (symbol / concept / pattern)
        2. Tokenize (strip filler words, preserve code tokens)
        3. Expand (concept queries only, static synonym map)
        4. Select weights (adaptive blend based on classification)
    → ChunkSearchEngine (enhanced)
        5. Check embedding cache → hit: reuse vector, miss: call OpenRouter
        6. Semantic search (with tokenized query)
        7. Keyword search (with expanded terms for FTS)
        8. Merge with adaptive weights from step 4
        9. Apply chunk importance multipliers
        10. Dynamic threshold filtering
        11. Consolidate per-file results
    → Return ranked results
```

No changes to: embedding model, database schema, indexing pipeline, or MCP tool interface. Existing indexed projects work immediately (chunk importance metadata enriches on next re-index).

## Component Details

### QueryPreprocessor (new file)

**Query Classification** — Heuristic-based, no LLM call:
- **Symbol query**: camelCase/snake_case tokens, dots, parens, 1-2 words matching code patterns → heavily favor keyword search, exact + fuzzy symbol name matching
- **Concept query**: natural language with question words (how, where, what), 3+ words, no code operators → favor semantic search, apply query expansion
- **Pattern query**: looking for code patterns ("async function returning Array"), balanced blend, no expansion

Detection signals: camelCase/snake_case regex, presence of `.()/<>`, query length, question words.

**Query Expansion** — Concept queries only:
- Static synonym map (~30-40 concept groups): `auth → [authentication, login, session, signin, credential]`, `db → [database, sql, query, migration]`, `api → [endpoint, route, request, handler]`, `ui → [view, component, interface, layout]`, etc.
- Expanded terms added to FTS query (OR'd with originals)
- Semantic search uses original query only (embedding model handles synonyms naturally)

**Code-Aware Tokenization**:
- Strip filler words ("the", "that", "which", "a", "is", "of", "in") only when query is 4+ words
- Preserve code tokens: anything with dots, underscores, camelCase, or parentheses
- Collapse whitespace, normalize quotes

**Adaptive Weight Selection**:
- Symbol queries: 40% semantic / 60% keyword
- Concept queries: 85% semantic / 15% keyword
- Pattern queries: 70% semantic / 30% keyword (current default)

### EmbeddingCache (new file)

- In-memory LRU cache, 50 entries
- Keyed by normalized query string
- Cache hit skips OpenRouter API call entirely
- Lives for MCP server process lifetime (reset on restart)

### ChunkSearchEngine Enhancements

**Chunk Importance Scoring** — Multiplier applied after merge:
- Chunk type: functions (1.0x), classes (1.0x), blocks (0.7x), headers (0.5x), docs (0.9x), commits (0.6x)
- Symbol visibility: public/exported symbols get 1.2x boost
- File category: test files (0.6x), generated files (0.3x), source files (1.0x)

**Dynamic Threshold** — Replace fixed 0.3:
- Calculate mean and standard deviation of top 5 result scores
- Floor = mean - 1 stddev
- Minimum floor of 0.15 (never accept pure noise)

**Better FTS Query Construction**:
- For multi-word queries: generate OR variant and phrase-proximity variant
- Use whichever returns more results (prefer phrase when both produce enough)

**Result Consolidation**:
- When 3+ chunks from same file match, keep top 2, add "N more in this file" count
- Prevents single file from dominating results

### CodeChunker Metadata Enrichment

Tag chunks during indexing with:
- `visibility`: public/private/internal (regex detection per language)
- `fileCategory`: source/test/generated (path-based: contains "test", "spec", "mock", "generated", "build")

Stored as part of chunk metadata. Used by importance scoring at search time.

## Files

| File | Change |
|------|--------|
| `QueryPreprocessor.swift` | **New** — classification, tokenization, expansion, synonym map, weight selection |
| `EmbeddingCache.swift` | **New** — LRU cache for query embedding vectors |
| `ChunkSearchEngine.swift` | Adaptive weighting, importance scoring, dynamic threshold, result consolidation, better FTS |
| `CodeChunker.swift` | Add visibility and fileCategory metadata to chunks |
| `ScopeMCP/main.swift` | Wire QueryPreprocessor into context_search, pass classification to search engine |

## Constraints

- Keep text-embedding-3-small via OpenRouter (no model changes)
- No database schema changes (metadata stored in existing chunk fields or computed at search time)
- No re-indexing required for existing projects (metadata enrichment happens on next index cycle)
- MCP tool interface unchanged (context_search params stay the same)
