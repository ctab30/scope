import Foundation
import GRDB

struct ChatConversation: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String?  // nil = global/home scope
    var title: String
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "chatConversations"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
