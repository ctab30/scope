import Foundation
import GRDB

struct CodebaseSnapshot: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var capturedAt: Date
    var fileTree: String? // JSON
    var schemaHash: String?
    var keySymbols: String? // JSON
    var profileText: String?

    static let databaseTableName = "codebaseSnapshots"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
