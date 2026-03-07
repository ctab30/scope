import Foundation
import GRDB

struct IndexedFile: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var relativePath: String
    var contentHash: String
    var language: String?
    var lastIndexedAt: Date

    static let databaseTableName = "indexedFiles"
}
