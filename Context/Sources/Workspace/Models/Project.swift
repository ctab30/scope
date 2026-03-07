import Foundation
import GRDB

struct Project: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String // UUID string
    var name: String
    var path: String
    var claudeProject: String? // ~/.claude/projects/<key> path
    var lastOpened: Date?
    var createdAt: Date
    var clientId: String?
    var tags: String? // JSON array
    var sortOrder: Int = 0

    static let databaseTableName = "projects"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let path = Column(CodingKeys.path)
        static let claudeProject = Column(CodingKeys.claudeProject)
        static let lastOpened = Column(CodingKeys.lastOpened)
        static let createdAt = Column(CodingKeys.createdAt)
        static let clientId = Column(CodingKeys.clientId)
        static let tags = Column(CodingKeys.tags)
        static let sortOrder = Column(CodingKeys.sortOrder)
    }

    var tagsArray: [String] {
        guard let json = tags,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }

    mutating func setTags(_ newTags: [String]) {
        if newTags.isEmpty {
            tags = nil
        } else if let data = try? JSONEncoder().encode(newTags),
                  let str = String(data: data, encoding: .utf8) {
            tags = str
        }
    }
}
