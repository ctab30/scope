import Foundation
import GRDB

struct BrowserScreenshot: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var filePath: String
    var pageURL: String?
    var pageTitle: String?
    var createdAt: Date

    static let databaseTableName = "browserScreenshots"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
