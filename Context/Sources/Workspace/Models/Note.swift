import Foundation
import GRDB

struct Note: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var title: String
    var content: String
    var pinned: Bool
    var sessionId: String?
    var createdAt: Date
    var updatedAt: Date
    var isGlobal: Bool = false

    static let databaseTableName = "notes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
