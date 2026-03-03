import Foundation
import GRDB

struct ContextAssembler {
    /// Assemble context for a specific project. Returns a text preamble.
    /// If `projectProfile` is provided, it's prepended as codebase context.
    static func projectContext(projectId: String, projectName: String, projectPath: String, projectProfile: String? = nil) -> String {
        var parts: [String] = []
        var totalChars = 0
        let maxChars = projectProfile != nil ? 12_000 : 8_000

        parts.append("""
        You are a helpful assistant with deep context about the "\(projectName)" project.
        Project path: \(projectPath)

        Answer questions about this project's tasks, sessions, notes, architecture, and codebase.
        When referencing tasks, include their status and priority. Be concise and specific.
        """)
        totalChars += parts.last!.count

        // Project profile (codebase structure, tech stack, architecture)
        if let profile = projectProfile, !profile.isEmpty {
            parts.append(profile)
            totalChars += profile.count
        }

        // Active tasks
        if let tasks = try? DatabaseService.shared.dbQueue.read({ db in
            try TaskItem
                .filter(Column("projectId") == projectId)
                .filter(Column("status") != "done")
                .order(Column("priority").desc, Column("createdAt").desc)
                .limit(20)
                .fetchAll(db)
        }), !tasks.isEmpty {
            var section = "\nACTIVE TASKS (\(tasks.count)):\n"
            for task in tasks {
                let priority = TaskItem.Priority(rawValue: task.priority)?.label ?? "None"
                let labels = task.labelsArray.joined(separator: ", ")
                section += "- [\(priority.uppercased())] \(task.title) (status: \(task.status)"
                if !labels.isEmpty { section += ", labels: \(labels)" }
                section += ")\n"
                if let desc = task.description, !desc.isEmpty {
                    section += "  \(String(desc.prefix(120)))\n"
                }
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Pinned notes (full content, highest priority)
        if let notes = try? DatabaseService.shared.dbQueue.read({ db in
            try Note
                .filter(Column("projectId") == projectId)
                .filter(Column("pinned") == true)
                .order(Column("updatedAt").desc)
                .limit(5)
                .fetchAll(db)
        }), !notes.isEmpty {
            var section = "\nPINNED NOTES:\n"
            for note in notes {
                let content = String(note.content.prefix(500))
                section += "## \(note.title)\n\(content)\n\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Recent sessions
        if let sessions = try? DatabaseService.shared.dbQueue.read({ db in
            try Session
                .filter(Column("projectId") == projectId)
                .order(Column("startedAt").desc)
                .limit(5)
                .fetchAll(db)
        }), !sessions.isEmpty {
            var section = "\nRECENT SESSIONS:\n"
            for session in sessions {
                let date = session.startedAt?.formatted(.dateTime.month(.abbreviated).day()) ?? "?"
                let summary = session.summary ?? "No summary"
                let model = session.model ?? "unknown"
                section += "- \(date): \"\(String(summary.prefix(150)))\" (\(model))\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Recent notes (titles only)
        if let notes = try? DatabaseService.shared.dbQueue.read({ db in
            try Note
                .filter(Column("projectId") == projectId)
                .filter(Column("pinned") == false)
                .order(Column("updatedAt").desc)
                .limit(10)
                .fetchAll(db)
        }), !notes.isEmpty {
            var section = "\nRECENT NOTES:\n"
            for note in notes {
                section += "- \(note.title)\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - RAG-Enhanced Context

    /// Assemble project context with RAG: embeds the user's query, searches
    /// the codebase index for relevant chunks, and injects them into the prompt.
    /// Falls back to standard context if embedding or search fails.
    static func projectContextWithRAG(
        projectId: String,
        projectName: String,
        projectPath: String,
        projectProfile: String? = nil,
        query: String
    ) async -> String {
        // Get the base context (tasks, notes, sessions, profile)
        let baseContext = projectContext(
            projectId: projectId,
            projectName: projectName,
            projectPath: projectPath,
            projectProfile: projectProfile
        )

        // Try to fetch relevant code chunks via embedding search
        let codeSection = await searchCodeChunks(projectId: projectId, query: query)

        if codeSection.isEmpty {
            return baseContext
        }

        // Insert code section after the profile, before tasks
        // Find where ACTIVE TASKS starts and inject before it
        if let taskRange = baseContext.range(of: "\nACTIVE TASKS") {
            var enriched = baseContext
            enriched.insert(contentsOf: "\n" + codeSection + "\n", at: taskRange.lowerBound)
            return enriched
        }

        // No tasks section — append at end
        return baseContext + "\n" + codeSection
    }

    /// Embed the query and search codeChunks for the top 5 matches by cosine similarity.
    private static func searchCodeChunks(projectId: String, query: String) async -> String {
        let embeddingClient = EmbeddingClient()
        let result = await embeddingClient.embed(query)

        guard let queryVector = result.vector else {
            return "" // Silently fall back — no code context
        }

        // Load all chunks with embeddings for this project (sync read to avoid GRDB async overload)
        let chunks: [(CodeChunk, String)]
        do {
            chunks = try await DatabaseService.shared.dbQueue.read { db in
                let sql = """
                    SELECT c.*, f.relativePath
                    FROM codeChunks c
                    JOIN indexedFiles f ON c.fileId = f.id
                    WHERE c.projectId = ? AND c.embedding IS NOT NULL
                """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [projectId])
                return try rows.map { row in
                    let chunk = try CodeChunk(row: row)
                    let path: String = row["relativePath"]
                    return (chunk, path)
                }
            }
        } catch {
            return ""
        }

        if chunks.isEmpty { return "" }

        // Score by cosine similarity
        var scored: [(path: String, chunk: CodeChunk, score: Float)] = []
        for (chunk, path) in chunks {
            guard let vector = chunk.embeddingVector else { continue }
            let sim = cosineSimilarity(queryVector, vector)
            if sim > 0.3 {
                scored.append((path, chunk, sim))
            }
        }

        scored.sort { $0.score > $1.score }
        let top = scored.prefix(5)

        if top.isEmpty { return "" }

        var section = "RELEVANT CODE (matching your question):\n"
        for item in top {
            let lines = [item.chunk.startLine, item.chunk.endLine]
                .compactMap { $0 }
                .map(String.init)
                .joined(separator: "-")
            let location = lines.isEmpty ? item.path : "\(item.path):\(lines)"
            let symbol = item.chunk.symbolName.map { " (\($0))" } ?? ""
            let content = String(item.chunk.content.prefix(500))
            section += "--- \(location)\(symbol) ---\n\(content)\n\n"
        }

        return section
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
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

    /// Assemble context for the global/home view.
    static func globalContext() -> String {
        var parts: [String] = []
        var totalChars = 0
        let maxChars = 8_000

        parts.append("""
        You are a helpful assistant with context about all projects in this workspace.
        Answer questions about projects, tasks, sessions, and notes across the entire workspace.
        Be concise and specific.
        """)
        totalChars += parts.last!.count

        // All projects with task counts
        if let projects = try? DatabaseService.shared.dbQueue.read({ db in
            try Project.order(Column("lastOpened").desc).fetchAll(db)
        }), !projects.isEmpty {
            var section = "\nPROJECTS (\(projects.count)):\n"
            for project in projects.prefix(20) {
                let taskCount = (try? DatabaseService.shared.dbQueue.read { db in
                    try TaskItem.filter(Column("projectId") == project.id).filter(Column("status") != "done").fetchCount(db)
                }) ?? 0
                let lastActive = project.lastOpened?.formatted(.dateTime.month(.abbreviated).day()) ?? "never"
                section += "- \(project.name): \(taskCount) active tasks, last active \(lastActive)\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Global tasks
        if let tasks = try? DatabaseService.shared.dbQueue.read({ db in
            try TaskItem
                .filter(Column("isGlobal") == true)
                .filter(Column("status") != "done")
                .order(Column("priority").desc)
                .limit(15)
                .fetchAll(db)
        }), !tasks.isEmpty {
            var section = "\nGLOBAL TASKS (\(tasks.count)):\n"
            for task in tasks {
                let priority = TaskItem.Priority(rawValue: task.priority)?.label ?? "None"
                section += "- [\(priority.uppercased())] \(task.title) (status: \(task.status))\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Global pinned notes
        if let notes = try? DatabaseService.shared.dbQueue.read({ db in
            try Note
                .filter(Column("isGlobal") == true)
                .filter(Column("pinned") == true)
                .order(Column("updatedAt").desc)
                .limit(5)
                .fetchAll(db)
        }), !notes.isEmpty {
            var section = "\nGLOBAL PINNED NOTES:\n"
            for note in notes {
                section += "## \(note.title)\n\(String(note.content.prefix(400)))\n\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        return parts.joined(separator: "\n")
    }
}
