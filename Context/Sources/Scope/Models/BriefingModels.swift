import Foundation
import GRDB

struct BriefingDigest: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var generatedAt: Date
    var itemCount: Int
    var status: String // "generating", "ready", "failed"

    static let databaseTableName = "briefingDigests"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let items = hasMany(BriefingItem.self, using: BriefingItem.digestForeignKey)
}

struct BriefingItem: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var digestId: Int64
    var title: String
    var summary: String
    var category: String
    var sourceUrl: String
    var sourceName: String
    var publishedAt: Date?
    var relevanceScore: Int
    var isSaved: Bool
    var isRead: Bool

    static let databaseTableName = "briefingItems"
    static let digestForeignKey = ForeignKey(["digestId"])

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
