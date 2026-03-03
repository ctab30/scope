import Foundation
import GRDB

struct WhitelistRule: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var pattern: String
    var clientId: String?
    var priority: Int = 0
    var isActive: Bool = true
    var createdAt: Date
    var note: String?

    static let databaseTableName = "whitelistRules"

    func matches(email: String) -> Bool {
        let lower = email.lowercased()
        let pat = pattern.lowercased()
        if pat.hasPrefix("@") {
            return lower.hasSuffix(pat)
        }
        return lower == pat
    }
}
