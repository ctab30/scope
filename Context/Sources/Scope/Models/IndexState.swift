import Foundation
import GRDB

struct IndexState: Codable, FetchableRecord, MutablePersistableRecord {
    var projectId: String
    var status: String
    var lastFullIndexAt: Date?
    var totalChunks: Int
    var lastError: String?

    static let databaseTableName = "indexState"
}
