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
    private static func chunkImportance(_ candidate: ScoredChunk) -> Float {
        var multiplier: Float = 1.0

        // Type-based importance
        switch candidate.chunk.chunkType {
        case "function": multiplier *= 1.0
        case "class":    multiplier *= 1.0
        case "doc":      multiplier *= 0.9
        case "block":    multiplier *= 0.7
        case "header":   multiplier *= 0.5
        case "commit":   multiplier *= 0.6
        default:         multiplier *= 0.8
        }

        // File path heuristics
        let path = candidate.file.lowercased()
        if path.contains("test") || path.contains("spec") || path.contains("mock") {
            multiplier *= 0.6
        }
        if path.contains("generated") || path.contains(".build/") || path.contains("vendor/") {
            multiplier *= 0.3
        }

        // Visibility heuristic: check if content starts with public/export
        let contentStart = candidate.chunk.content.prefix(200).lowercased()
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
        let variance = top.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(top.count - 1)
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

        // Backfill moreInFile counts — only on the last-shown result per file
        var lastIndexForFile: [String: Int] = [:]
        for i in 0..<results.count {
            lastIndexForFile[results[i].file] = i
        }
        for i in 0..<results.count {
            let file = results[i].file
            if let extras = fileExtras[file], lastIndexForFile[file] == i {
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
