import Foundation
import GRDB

struct WhitelistMatch {
    let rule: WhitelistRule
    let clientId: String?
    let priority: Int
}

enum WhitelistFilter {
    static func check(senderEmail: String) -> WhitelistMatch? {
        do {
            let rules = try DatabaseService.shared.dbQueue.read { db in
                try WhitelistRule
                    .filter(Column("isActive") == true)
                    .order(Column("priority").desc)
                    .fetchAll(db)
            }

            let email = extractEmail(from: senderEmail)

            for rule in rules {
                if rule.matches(email: email) {
                    return WhitelistMatch(
                        rule: rule,
                        clientId: rule.clientId,
                        priority: rule.priority
                    )
                }
            }
        } catch {
            print("WhitelistFilter: failed to check rules: \(error)")
        }
        return nil
    }

    static func extractEmail(from sender: String) -> String {
        if let start = sender.lastIndex(of: "<"),
           let end = sender.lastIndex(of: ">") {
            return String(sender[sender.index(after: start)..<end])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return sender.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func extractName(from sender: String) -> String? {
        if let start = sender.lastIndex(of: "<") {
            let name = String(sender[sender.startIndex..<start])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
