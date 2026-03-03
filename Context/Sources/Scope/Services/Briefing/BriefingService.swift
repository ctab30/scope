import Foundation
import GRDB

@MainActor
class BriefingService: ObservableObject {
    @Published var isGenerating = false
    @Published var latestDigest: BriefingDigest?
    @Published var latestItems: [BriefingItem] = []
    @Published var unreadCount: Int = 0

    // MARK: - Public API

    func checkAndGenerate(settings: AppSettings) async {
        loadLatestDigest()

        if let digest = latestDigest {
            let age = Date().timeIntervalSince(digest.generatedAt)
            let staleSeconds = settings.briefingStalenessHours * 3600
            if age < staleSeconds {
                return // Still fresh
            }
        }

        await generateNow(settings: settings)
    }

    func generateNow(settings: AppSettings) async {
        guard !isGenerating else { return }
        isGenerating = true

        do {
            // Create digest placeholder
            var digest = BriefingDigest(
                id: nil,
                generatedAt: Date(),
                itemCount: 0,
                status: "generating"
            )
            try await DatabaseService.shared.dbQueue.write { db in
                try digest.insert(db)
            }

            guard let digestId = digest.id else {
                isGenerating = false
                return
            }

            // Fetch raw items from all sources
            let rawItems = await Task.detached {
                await NewsFetcher.fetchAll(
                    rssFeeds: settings.briefingRSSFeeds,
                    subreddits: settings.briefingSubreddits
                )
            }.value

            print("BriefingService: fetched \(rawItems.count) raw items")

            guard !rawItems.isEmpty else {
                try? updateDigestStatus(id: digestId, status: "failed", itemCount: 0)
                isGenerating = false
                return
            }

            // Synthesize with Claude
            let synthesized = await Task.detached {
                Self.synthesizeWithClaude(rawItems)
            }.value

            print("BriefingService: Claude returned \(synthesized.count) items")

            if synthesized.isEmpty {
                try? updateDigestStatus(id: digestId, status: "failed", itemCount: 0)
                isGenerating = false
                loadLatestDigest()
                return
            }

            // Save items to database
            try await DatabaseService.shared.dbQueue.write { db in
                for item in synthesized {
                    var briefingItem = BriefingItem(
                        id: nil,
                        digestId: digestId,
                        title: item.title,
                        summary: item.summary,
                        category: item.category,
                        sourceUrl: item.sourceUrl,
                        sourceName: item.sourceName,
                        publishedAt: nil,
                        relevanceScore: item.relevanceScore,
                        isSaved: false,
                        isRead: false
                    )
                    try briefingItem.insert(db)
                }
            }

            try? updateDigestStatus(id: digestId, status: "ready", itemCount: synthesized.count)
            loadLatestDigest()

        } catch {
            print("BriefingService: generation failed: \(error)")
        }

        isGenerating = false
    }

    func markAsRead(itemId: Int64) {
        try? DatabaseService.shared.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefingItems SET isRead = 1 WHERE id = ?",
                arguments: [itemId]
            )
        }
        if unreadCount > 0 { unreadCount -= 1 }
    }

    func toggleSaved(itemId: Int64) {
        try? DatabaseService.shared.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefingItems SET isSaved = NOT isSaved WHERE id = ?",
                arguments: [itemId]
            )
        }
        loadItems(for: latestDigest?.id)
    }

    // MARK: - Database

    func loadLatestDigest() {
        do {
            let digest = try DatabaseService.shared.dbQueue.read { db in
                try BriefingDigest
                    .filter(Column("status") == "ready")
                    .order(Column("generatedAt").desc)
                    .fetchOne(db)
            }
            latestDigest = digest
            if let id = digest?.id {
                loadItems(for: id)
            } else {
                latestItems = []
                unreadCount = 0
            }
        } catch {
            print("BriefingService: failed to load digest: \(error)")
        }
    }

    private func loadItems(for digestId: Int64?) {
        guard let digestId else {
            latestItems = []
            unreadCount = 0
            return
        }
        do {
            let items = try DatabaseService.shared.dbQueue.read { db in
                try BriefingItem
                    .filter(Column("digestId") == digestId)
                    .order(Column("relevanceScore").desc)
                    .fetchAll(db)
            }
            latestItems = items
            unreadCount = items.filter { !$0.isRead }.count
        } catch {
            print("BriefingService: failed to load items: \(error)")
        }
    }

    func loadPastDigests() -> [BriefingDigest] {
        (try? DatabaseService.shared.dbQueue.read { db in
            try BriefingDigest
                .filter(Column("status") == "ready")
                .order(Column("generatedAt").desc)
                .limit(10)
                .fetchAll(db)
        }) ?? []
    }

    func loadItems(forDigest digestId: Int64) -> [BriefingItem] {
        (try? DatabaseService.shared.dbQueue.read { db in
            try BriefingItem
                .filter(Column("digestId") == digestId)
                .order(Column("relevanceScore").desc)
                .fetchAll(db)
        }) ?? []
    }

    private func updateDigestStatus(id: Int64, status: String, itemCount: Int) throws {
        try DatabaseService.shared.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefingDigests SET status = ?, itemCount = ? WHERE id = ?",
                arguments: [status, itemCount, id]
            )
        }
    }

    // MARK: - Claude Synthesis

    private nonisolated static func synthesizeWithClaude(_ items: [RawNewsItem]) -> [SynthesizedItem] {
        var itemDescriptions = ""
        for (i, item) in items.enumerated() {
            itemDescriptions += """
            --- ITEM \(i + 1) ---
            Title: \(item.title)
            Source: \(item.sourceName)
            URL: \(item.url)
            \(item.snippet.map { "Snippet: \($0)" } ?? "")

            """
        }

        let prompt = """
        You are curating a daily tech briefing for a developer/agency owner.

        Here are today's raw news items:

        \(itemDescriptions)

        Instructions:
        1. Select the top 15 most relevant items for someone who runs a dev agency and cares about AI, dev tools, and programming innovation.
        2. For each selected item, write a 2-sentence summary.
        3. Categorize each into one of: "AI Tools", "Agentic", "Dev Tools", "Programming", "Industry", "Open Source"
        4. Rank by relevance (10 = must-read, 1 = nice-to-know)

        Return ONLY a JSON array. Each object:
        {
          "title": "string",
          "summary": "string",
          "category": "string",
          "sourceUrl": "string",
          "sourceName": "string",
          "relevanceScore": number
        }
        """

        guard let raw = callClaude(prompt: prompt) else {
            print("BriefingService: Claude synthesis failed — CLI not reachable")
            return []
        }

        // Strip markdown code fences if present
        var jsonStr = raw
        if jsonStr.hasPrefix("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonStr = filtered.joined(separator: "\n")
        }

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            print("BriefingService: failed to parse Claude response as JSON")
            return []
        }

        return array.compactMap { item -> SynthesizedItem? in
            guard let title = item["title"] as? String,
                  let summary = item["summary"] as? String,
                  let category = item["category"] as? String,
                  let sourceUrl = item["sourceUrl"] as? String,
                  let sourceName = item["sourceName"] as? String
            else { return nil }

            let score = item["relevanceScore"] as? Int ?? 5

            return SynthesizedItem(
                title: title,
                summary: summary,
                category: category,
                sourceUrl: sourceUrl,
                sourceName: sourceName,
                relevanceScore: min(max(score, 1), 10)
            )
        }
    }

    // MARK: - Claude CLI

    private nonisolated static func callClaude(prompt: String) -> String? {
        guard let claudePath = findClaudeBinary() else { return nil }

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["-p", "--output-format", "text"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = inputPipe
        process.environment = ProcessInfo.processInfo.environment

        guard let promptData = prompt.data(using: .utf8) else { return nil }
        inputPipe.fileHandleForWriting.write(promptData)
        inputPipe.fileHandleForWriting.closeFile()

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func findClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.npm/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.nvm/current/bin/claude",
            "\(home)/.volta/bin/claude",
        ]

        let nvmVersions = "\(home)/.nvm/versions/node"
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            for dir in dirs.sorted().reversed() {
                candidates.append("\(nvmVersions)/\(dir)/bin/claude")
            }
        }

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback: login shell resolution
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellWhich = Process()
        let pipe = Pipe()
        shellWhich.executableURL = URL(fileURLWithPath: shell)
        shellWhich.arguments = ["-lc", "which claude"]
        shellWhich.standardOutput = pipe
        shellWhich.standardError = FileHandle.nullDevice
        do {
            try shellWhich.run()
            shellWhich.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, shellWhich.terminationStatus == 0 {
                return path
            }
        } catch {}

        print("BriefingService: claude binary not found")
        return nil
    }
}

// MARK: - Intermediate Type

private struct SynthesizedItem {
    let title: String
    let summary: String
    let category: String
    let sourceUrl: String
    let sourceName: String
    let relevanceScore: Int
}
