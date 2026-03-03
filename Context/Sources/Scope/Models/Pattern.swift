import Foundation
import GRDB

struct Pattern: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var category: String // "architecture", "naming", "schema", "workflow"
    var title: String
    var description: String
    var sourceSession: String?
    var autoDetected: Bool
    var createdAt: Date

    static let databaseTableName = "patterns"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
