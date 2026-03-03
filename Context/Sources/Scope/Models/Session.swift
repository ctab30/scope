import Foundation
import GRDB

struct Session: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String // Claude's session UUID
    var projectId: String
    var slug: String?
    var startedAt: Date?
    var endedAt: Date?
    var model: String?
    var gitBranch: String?
    var summary: String?
    var messageCount: Int
    var toolUseCount: Int
    var filesChanged: String? // JSON array
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int

    static let databaseTableName = "sessions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let projectId = Column(CodingKeys.projectId)
        static let slug = Column(CodingKeys.slug)
        static let startedAt = Column(CodingKeys.startedAt)
        static let endedAt = Column(CodingKeys.endedAt)
        static let model = Column(CodingKeys.model)
        static let gitBranch = Column(CodingKeys.gitBranch)
        static let summary = Column(CodingKeys.summary)
        static let messageCount = Column(CodingKeys.messageCount)
        static let toolUseCount = Column(CodingKeys.toolUseCount)
        static let filesChanged = Column(CodingKeys.filesChanged)
        static let inputTokens = Column(CodingKeys.inputTokens)
        static let outputTokens = Column(CodingKeys.outputTokens)
        static let cacheCreationTokens = Column(CodingKeys.cacheCreationTokens)
        static let cacheReadTokens = Column(CodingKeys.cacheReadTokens)
    }

    // Convenience: decode files changed as array
    var filesChangedArray: [String] {
        guard let json = filesChanged,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }

    /// Estimated session cost in USD based on model pricing.
    var estimatedCost: Double {
        SessionCost.calculate(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}

// MARK: - Shared Cost Calculation

/// Shared pricing logic used by both Session (historical) and LiveSessionMonitor (real-time).
enum SessionCost {
    /// Per-million-token pricing by model family: (input, output, cacheWrite, cacheRead)
    static func pricing(for model: String?) -> (input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        guard let m = model else { return (15.0, 75.0, 18.75, 1.50) }
        if m.contains("opus")   { return (15.0, 75.0, 18.75, 1.50) }
        if m.contains("sonnet") { return (3.0, 15.0, 3.75, 0.30) }
        if m.contains("haiku")  { return (0.80, 4.0, 1.0, 0.08) }
        return (15.0, 75.0, 18.75, 1.50) // default to Opus pricing
    }

    static func calculate(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) -> Double {
        let p = pricing(for: model)
        return Double(inputTokens)          / 1_000_000 * p.input
             + Double(outputTokens)         / 1_000_000 * p.output
             + Double(cacheCreationTokens)  / 1_000_000 * p.cacheWrite
             + Double(cacheReadTokens)      / 1_000_000 * p.cacheRead
    }
}
