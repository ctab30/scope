import Foundation
import GRDB

struct GeneratedImage: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var prompt: String
    var responseText: String?
    var filePath: String
    var model: String = "google/gemini-3.1-flash-image-preview"
    var aspectRatio: String = "1:1"
    var imageSize: String = "1K"
    var parentImageId: Int64?
    var createdAt: Date

    static let databaseTableName = "generatedImages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
