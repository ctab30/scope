import Foundation
import GRDB

struct CodeChunk: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var fileId: String
    var projectId: String
    var chunkType: String
    var symbolName: String?
    var content: String
    var startLine: Int?
    var endLine: Int?
    var embedding: Data?

    static let databaseTableName = "codeChunks"

    var embeddingVector: [Float]? {
        guard let data = embedding else { return nil }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    static func encodeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
