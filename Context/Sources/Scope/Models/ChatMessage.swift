import Foundation
import GRDB

struct ChatMessage: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var conversationId: Int64
    var role: String  // "user" or "assistant"
    var content: String
    var createdAt: Date

    static let databaseTableName = "chatMessages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
