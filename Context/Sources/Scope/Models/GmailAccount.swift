import Foundation
import GRDB

struct GmailAccount: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var email: String
    var lastHistoryId: String?
    var isActive: Bool = true
    var createdAt: Date
    var lastSyncAt: Date?

    static let databaseTableName = "gmailAccounts"
}
