import Foundation
import GRDB

struct ProcessedEmail: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var gmailMessageId: String
    var gmailThreadId: String
    var gmailAccountId: String
    var fromAddress: String
    var fromName: String?
    var subject: String
    var snippet: String?
    var body: String?
    var receivedAt: Date
    var taskId: Int64?
    var triageType: String?
    var isRead: Bool = false
    var repliedAt: Date?
    var importedAt: Date

    static let databaseTableName = "processedEmails"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
