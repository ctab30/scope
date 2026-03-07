import Foundation
import GRDB

struct TaskNote: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var taskId: Int64
    var content: String
    var source: String // "manual", "claude", "system"
    var sessionId: String?
    var createdAt: Date

    static let databaseTableName = "taskNotes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
