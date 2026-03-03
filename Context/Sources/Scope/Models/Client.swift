import Foundation
import GRDB

struct Client: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String // UUID string
    var name: String
    var color: String // hex color, e.g. "#3B82F6"
    var sortOrder: Int
    var createdAt: Date

    static let databaseTableName = "clients"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let color = Column(CodingKeys.color)
        static let sortOrder = Column(CodingKeys.sortOrder)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    static let defaultColors = [
        "#3B82F6", // blue
        "#10B981", // green
        "#F59E0B", // amber
        "#EF4444", // red
        "#8B5CF6", // purple
        "#EC4899", // pink
        "#06B6D4", // cyan
        "#F97316", // orange
    ]
}
