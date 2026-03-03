# Gmail Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an email-to-task pipeline that polls multiple Gmail accounts, filters by whitelist rules, uses AI to extract actionable tasks, and supports replying from within the app.

**Architecture:** OAuth2 via ASWebAuthenticationSession for browser-based login. Gmail REST API via URLSession (no Google SDK dependency). Tokens stored in macOS Keychain. Background poller (5-minute interval) fetches new emails per account, filters against a global whitelist/routing table (domain + individual rules mapped to clients), sends matches through Claude CLI for triage, and creates global tasks with email metadata. Reply sends via Gmail API from the receiving account.

**Tech Stack:** SwiftUI, GRDB (existing), Security.framework (Keychain), AuthenticationServices (OAuth), URLSession (Gmail API), Claude CLI (AI triage)

**No new package dependencies required** — everything uses Apple frameworks + existing Claude CLI integration.

---

## Database Schema

The Gmail feature adds 3 new tables and 2 new columns on `taskItems`. All in migration `v9_addGmailIntegration`.

```
gmailAccounts
├── id: TEXT PK (UUID)
├── email: TEXT UNIQUE NOT NULL
├── lastHistoryId: TEXT            -- Gmail incremental sync cursor
├── isActive: BOOLEAN DEFAULT true
├── createdAt: DATETIME NOT NULL
└── lastSyncAt: DATETIME

whitelistRules
├── id: TEXT PK (UUID)
├── pattern: TEXT NOT NULL          -- "@domain.com" or "user@email.com"
├── clientId: TEXT → clients(id)    -- auto-assign to this client
├── priority: INTEGER DEFAULT 0     -- 0=normal, 1=high
├── isActive: BOOLEAN DEFAULT true
├── createdAt: DATETIME NOT NULL
└── note: TEXT                      -- user memo

processedEmails
├── id: INTEGER PK AUTOINCREMENT
├── gmailMessageId: TEXT UNIQUE NOT NULL
├── gmailThreadId: TEXT NOT NULL
├── gmailAccountId: TEXT → gmailAccounts(id) CASCADE
├── fromAddress: TEXT NOT NULL
├── fromName: TEXT
├── subject: TEXT NOT NULL
├── snippet: TEXT
├── body: TEXT                      -- plain text body for AI and reply context
├── receivedAt: DATETIME NOT NULL
├── taskId: INTEGER → taskItems(id) SET NULL
├── triageType: TEXT                -- "task", "question", "calendar", "fyi"
├── isRead: BOOLEAN DEFAULT false
├── repliedAt: DATETIME
└── importedAt: DATETIME NOT NULL

taskItems (ALTER — 2 new columns)
├── gmailThreadId: TEXT             -- links task back to email thread
└── gmailMessageId: TEXT            -- specific message that created this task
```

---

## Task 1: Database Migration v9

**Files:**
- Modify: `Context/Sources/Context/Services/DatabaseService.swift`

Add migration `v9_addGmailIntegration` after the existing `v8_addGlobalFlags` migration:

```swift
migrator.registerMigration("v9_addGmailIntegration") { db in
    try db.create(table: "gmailAccounts") { t in
        t.primaryKey("id", .text)
        t.column("email", .text).notNull().unique()
        t.column("lastHistoryId", .text)
        t.column("isActive", .boolean).notNull().defaults(to: true)
        t.column("createdAt", .datetime).notNull()
        t.column("lastSyncAt", .datetime)
    }

    try db.create(table: "whitelistRules") { t in
        t.primaryKey("id", .text)
        t.column("pattern", .text).notNull()
        t.column("clientId", .text).references("clients", onDelete: .setNull)
        t.column("priority", .integer).notNull().defaults(to: 0)
        t.column("isActive", .boolean).notNull().defaults(to: true)
        t.column("createdAt", .datetime).notNull()
        t.column("note", .text)
    }

    try db.create(table: "processedEmails") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("gmailMessageId", .text).notNull().unique()
        t.column("gmailThreadId", .text).notNull()
        t.column("gmailAccountId", .text).notNull()
            .references("gmailAccounts", onDelete: .cascade)
        t.column("fromAddress", .text).notNull()
        t.column("fromName", .text)
        t.column("subject", .text).notNull()
        t.column("snippet", .text)
        t.column("body", .text)
        t.column("receivedAt", .datetime).notNull()
        t.column("taskId", .integer)
            .references("taskItems", onDelete: .setNull)
        t.column("triageType", .text)
        t.column("isRead", .boolean).notNull().defaults(to: false)
        t.column("repliedAt", .datetime)
        t.column("importedAt", .datetime).notNull()
    }

    try db.alter(table: "taskItems") { t in
        t.add(column: "gmailThreadId", .text)
        t.add(column: "gmailMessageId", .text)
    }
}
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add database migration v9 for gmail integration tables"`

---

## Task 2: GRDB Models

**Files:**
- Create: `Context/Sources/Context/Models/GmailAccount.swift`
- Create: `Context/Sources/Context/Models/WhitelistRule.swift`
- Create: `Context/Sources/Context/Models/ProcessedEmail.swift`
- Modify: `Context/Sources/Context/Models/TaskItem.swift` (add 2 optional fields)

### GmailAccount.swift

```swift
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
```

### WhitelistRule.swift

```swift
import Foundation
import GRDB

struct WhitelistRule: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var pattern: String        // "@domain.com" or "user@example.com"
    var clientId: String?
    var priority: Int = 0      // 0=normal, 1=high
    var isActive: Bool = true
    var createdAt: Date
    var note: String?

    static let databaseTableName = "whitelistRules"

    /// Check if a sender email address matches this rule.
    func matches(email: String) -> Bool {
        let lower = email.lowercased()
        let pat = pattern.lowercased()
        if pat.hasPrefix("@") {
            return lower.hasSuffix(pat)
        }
        return lower == pat
    }
}
```

### ProcessedEmail.swift

```swift
import Foundation
import GRDB

struct ProcessedEmail: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var gmailMessageId: String
    var gmailThreadId: String
    var gmailAccountId: String
    var fromAddress: String
    var fromName: String?
    var subject: String
    var snippet: String?
    var body: String?
    var receivedAt: Date
    var taskId: Int64?
    var triageType: String?     // "task", "question", "calendar", "fyi"
    var isRead: Bool = false
    var repliedAt: Date?
    var importedAt: Date

    static let databaseTableName = "processedEmails"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

### TaskItem.swift changes

Add two optional fields after `isGlobal`:

```swift
var gmailThreadId: String?
var gmailMessageId: String?
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add GmailAccount, WhitelistRule, ProcessedEmail models"`

---

## Task 3: Keychain Helper

Tokens must NOT be stored in the database or UserDefaults. Use macOS Keychain via Security.framework.

**Files:**
- Create: `Context/Sources/Context/Services/KeychainHelper.swift`

```swift
import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.scope.gmail"

    /// Save a string value to the Keychain for a given account key.
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Read a string value from the Keychain for a given account key.
    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain.
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }
}
```

Token keys follow the pattern: `"accessToken-{accountId}"`, `"refreshToken-{accountId}"`, `"tokenExpiry-{accountId}"`.

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add KeychainHelper for secure token storage"`

---

## Task 4: Google OAuth2 Manager

Handles the browser-based OAuth flow using ASWebAuthenticationSession (built-in macOS framework). No Google SDK needed.

**Files:**
- Create: `Context/Sources/Context/Services/Gmail/GoogleOAuthManager.swift`

**OAuth2 Flow:**
1. User clicks "Add Gmail Account" in settings
2. App opens browser via ASWebAuthenticationSession
3. User signs in to Google, grants read+send permissions
4. Browser redirects to custom URI scheme `context-app://oauth/callback`
5. App exchanges authorization code for access+refresh tokens
6. Tokens stored in Keychain, account record saved to DB

**Key Constants:**
- Auth URL: `https://accounts.google.com/o/oauth2/v2/auth`
- Token URL: `https://oauth2.googleapis.com/token`
- Scopes: `https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send`
- Redirect URI: `context-app://oauth/callback` (register as URL scheme in Info.plist)

**Implementation:**

```swift
import Foundation
import AuthenticationServices

@MainActor
class GoogleOAuthManager: NSObject, ObservableObject {
    @Published var isAuthenticating = false

    // These come from Google Cloud Console — stored in AppSettings
    var clientId: String { UserDefaults.standard.string(forKey: "gmailClientId") ?? "" }
    var clientSecret: String {
        KeychainHelper.read(key: "gmailClientSecret") ?? ""
    }

    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let scopes = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send"
    private let redirectURI = "context-app://oauth/callback"

    func startOAuthFlow() async -> GmailTokens? {
        isAuthenticating = true
        defer { isAuthenticating = false }

        // Build the authorization URL
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authorizationURL = components.url else { return nil }

        // Use ASWebAuthenticationSession for the browser flow
        let code: String? = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "context-app"
            ) { callbackURL, error in
                guard error == nil,
                      let callbackURL,
                      let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        guard let authCode = code else { return nil }

        // Exchange code for tokens
        return await exchangeCodeForTokens(code: authCode)
    }

    private func exchangeCodeForTokens(code: String) async -> GmailTokens? {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code=\(code)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else { return nil }

        return GmailTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    /// Refresh an expired access token using the refresh token.
    func refreshAccessToken(accountId: String) async -> String? {
        guard let refreshToken = KeychainHelper.read(key: "refreshToken-\(accountId)") else {
            return nil
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token=\(refreshToken)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else { return nil }

        // Save new access token + expiry
        try? KeychainHelper.save(key: "accessToken-\(accountId)", value: accessToken)
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        try? KeychainHelper.save(
            key: "tokenExpiry-\(accountId)",
            value: String(expiry.timeIntervalSince1970)
        )

        return accessToken
    }

    /// Get a valid access token, refreshing if expired.
    func getValidToken(for accountId: String) async -> String? {
        if let expiryStr = KeychainHelper.read(key: "tokenExpiry-\(accountId)"),
           let expiry = Double(expiryStr),
           Date().timeIntervalSince1970 < expiry - 60,
           let token = KeychainHelper.read(key: "accessToken-\(accountId)") {
            return token
        }
        return await refreshAccessToken(accountId: accountId)
    }

    /// Save tokens for a newly authenticated account.
    func saveTokens(_ tokens: GmailTokens, accountId: String) {
        try? KeychainHelper.save(key: "accessToken-\(accountId)", value: tokens.accessToken)
        try? KeychainHelper.save(key: "refreshToken-\(accountId)", value: tokens.refreshToken)
        try? KeychainHelper.save(
            key: "tokenExpiry-\(accountId)",
            value: String(tokens.expiresAt.timeIntervalSince1970)
        )
    }

    /// Remove all tokens for an account.
    func deleteTokens(accountId: String) {
        KeychainHelper.delete(key: "accessToken-\(accountId)")
        KeychainHelper.delete(key: "refreshToken-\(accountId)")
        KeychainHelper.delete(key: "tokenExpiry-\(accountId)")
    }
}

extension GoogleOAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}

struct GmailTokens {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}
```

**Also needed:** Register the URL scheme `context-app` in the app's Info.plist (handled in `scripts/package-app.sh`). Add to the Info.plist generation:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>context-app</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.scope.oauth</string>
    </dict>
</array>
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add GoogleOAuthManager with ASWebAuthenticationSession"`

---

## Task 5: Gmail API Service

Handles all Gmail REST API calls — fetching messages, getting details, sending replies.

**Files:**
- Create: `Context/Sources/Context/Services/Gmail/GmailAPIService.swift`

**Key API endpoints:**
- `GET /gmail/v1/users/me/messages?q=...` — list messages
- `GET /gmail/v1/users/me/messages/{id}?format=full` — get full message
- `GET /gmail/v1/users/me/profile` — get user's email address
- `POST /gmail/v1/users/me/messages/send` — send reply

**Implementation:**

```swift
import Foundation

class GmailAPIService {
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let oauthManager: GoogleOAuthManager

    init(oauthManager: GoogleOAuthManager) {
        self.oauthManager = oauthManager
    }

    // MARK: - Fetch User Profile (to get email address after OAuth)

    func fetchProfile(accountId: String) async -> String? {
        guard let data = try? await request(path: "/profile", accountId: accountId) else {
            return nil
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["emailAddress"] as? String
    }

    // MARK: - List Messages (new since last sync)

    struct MessageListResponse {
        let messageIds: [(id: String, threadId: String)]
        let nextPageToken: String?
    }

    func listMessages(
        accountId: String,
        query: String = "",
        after: Date? = nil,
        pageToken: String? = nil,
        maxResults: Int = 50
    ) async -> MessageListResponse? {
        var q = query
        if let after {
            let epoch = Int(after.timeIntervalSince1970)
            q += (q.isEmpty ? "" : " ") + "after:\(epoch)"
        }

        var params = "maxResults=\(maxResults)"
        if !q.isEmpty { params += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)" }
        if let pageToken { params += "&pageToken=\(pageToken)" }

        guard let data = try? await request(path: "/messages?\(params)", accountId: accountId),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let messages = (json["messages"] as? [[String: Any]])?.compactMap { msg -> (String, String)? in
            guard let id = msg["id"] as? String, let threadId = msg["threadId"] as? String else { return nil }
            return (id, threadId)
        } ?? []

        return MessageListResponse(
            messageIds: messages,
            nextPageToken: json["nextPageToken"] as? String
        )
    }

    // MARK: - Get Full Message

    struct GmailMessage {
        let id: String
        let threadId: String
        let from: String        // "Name <email>" or just "email"
        let subject: String
        let snippet: String
        let body: String        // Plain text body
        let date: Date
        let isCalendarInvite: Bool
    }

    func getMessage(id: String, accountId: String) async -> GmailMessage? {
        guard let data = try? await request(path: "/messages/\(id)?format=full", accountId: accountId),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = (payload["headers"] as? [[String: String]]) ?? []

        let from = headers.first { $0["name"]?.lowercased() == "from" }?["value"] ?? ""
        let subject = headers.first { $0["name"]?.lowercased() == "subject" }?["value"] ?? "(no subject)"
        let dateStr = headers.first { $0["name"]?.lowercased() == "date" }?["value"] ?? ""
        let contentType = headers.first { $0["name"]?.lowercased() == "content-type" }?["value"] ?? ""
        let snippet = json["snippet"] as? String ?? ""

        let isCalendar = contentType.contains("calendar") ||
            (payload["parts"] as? [[String: Any]])?.contains { ($0["mimeType"] as? String)?.contains("calendar") == true } == true

        let body = extractPlainTextBody(from: payload)

        let date = parseGmailDate(dateStr) ?? Date()

        return GmailMessage(
            id: json["id"] as? String ?? id,
            threadId: json["threadId"] as? String ?? "",
            from: from,
            subject: subject,
            snippet: snippet,
            body: body,
            date: date,
            isCalendarInvite: isCalendar
        )
    }

    // MARK: - Send Reply

    func sendReply(
        accountId: String,
        threadId: String,
        inReplyTo: String,
        to: String,
        subject: String,
        body: String
    ) async -> Bool {
        // Build RFC 2822 message
        let profile = await fetchProfile(accountId: accountId) ?? ""
        let message = [
            "From: \(profile)",
            "To: \(to)",
            "Subject: Re: \(subject)",
            "In-Reply-To: \(inReplyTo)",
            "References: \(inReplyTo)",
            "",
            body
        ].joined(separator: "\r\n")

        guard let messageData = message.data(using: .utf8) else { return false }
        let encoded = messageData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let payload: [String: Any] = [
            "raw": encoded,
            "threadId": threadId,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return false }

        guard let _ = try? await request(
            path: "/messages/send",
            accountId: accountId,
            method: "POST",
            body: jsonData,
            contentType: "application/json"
        ) else { return false }

        return true
    }

    // MARK: - HTTP Helper

    private func request(
        path: String,
        accountId: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        guard let token = await oauthManager.getValidToken(for: accountId) else {
            throw GmailAPIError.noToken
        }

        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body }
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await URLSession.shared.data(for: req)
        let httpResponse = response as? HTTPURLResponse
        guard let statusCode = httpResponse?.statusCode, 200..<300 ~= statusCode else {
            throw GmailAPIError.httpError(httpResponse?.statusCode ?? 0)
        }
        return data
    }

    // MARK: - Body Extraction

    /// Recursively extract plain text body from Gmail message payload.
    private func extractPlainTextBody(from payload: [String: Any]) -> String {
        // Check if this part itself is text/plain
        if let mimeType = payload["mimeType"] as? String, mimeType == "text/plain" {
            if let body = payload["body"] as? [String: Any],
               let data = body["data"] as? String {
                return decodeBase64URL(data)
            }
        }

        // Check nested parts
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts {
                let result = extractPlainTextBody(from: part)
                if !result.isEmpty { return result }
            }
        }

        return ""
    }

    private func decodeBase64URL(_ str: String) -> String {
        var base64 = str
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseGmailDate(_ dateStr: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Gmail uses RFC 2822 dates
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateStr) { return date }
        }
        return nil
    }

    enum GmailAPIError: Error {
        case noToken
        case httpError(Int)
    }
}
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add GmailAPIService for fetching and sending emails"`

---

## Task 6: Whitelist Filter Service

Standalone filtering logic that checks sender addresses against the whitelist rules.

**Files:**
- Create: `Context/Sources/Context/Services/Gmail/WhitelistFilter.swift`

```swift
import Foundation
import GRDB

struct WhitelistMatch {
    let rule: WhitelistRule
    let clientId: String?
    let priority: Int
}

enum WhitelistFilter {
    /// Check if a sender email matches any active whitelist rule.
    /// Returns the matching rule with highest priority, or nil if no match.
    static func check(senderEmail: String) -> WhitelistMatch? {
        do {
            let rules = try DatabaseService.shared.dbQueue.read { db in
                try WhitelistRule
                    .filter(Column("isActive") == true)
                    .order(Column("priority").desc)
                    .fetchAll(db)
            }

            // Extract just the email from "Name <email>" format
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

    /// Extract email address from "Display Name <email@domain.com>" format.
    static func extractEmail(from sender: String) -> String {
        if let start = sender.lastIndex(of: "<"),
           let end = sender.lastIndex(of: ">") {
            return String(sender[sender.index(after: start)..<end])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return sender.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Extract display name from "Display Name <email>" format.
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
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add WhitelistFilter for email routing"`

---

## Task 7: AI Email Triage

Uses the existing Claude CLI pattern (from ClaudeService) to classify emails and extract action items.

**Files:**
- Create: `Context/Sources/Context/Services/Gmail/EmailTriageService.swift`

```swift
import Foundation

struct EmailTriageResult {
    let title: String           // Extracted action item
    let description: String?    // Context
    let priority: Int           // 0-4
    let type: String            // "task", "question", "calendar", "fyi"
}

enum EmailTriageService {
    /// Triage a batch of emails using Claude CLI.
    /// Returns one result per email that warrants a task.
    nonisolated static func triageEmails(
        _ emails: [(subject: String, from: String, body: String, isCalendar: Bool)]
    ) -> [EmailTriageResult?] {
        if emails.isEmpty { return [] }

        var emailDescriptions = ""
        for (i, email) in emails.enumerated() {
            emailDescriptions += """
            --- EMAIL \(i + 1) ---
            From: \(email.from)
            Subject: \(email.subject)
            Calendar invite: \(email.isCalendar ? "yes" : "no")
            Body (truncated):
            \(String(email.body.prefix(1500)))

            """
        }

        let prompt = """
        You are triaging incoming emails for a freelance developer/agency owner.
        Analyze each email and determine if it requires action.

        For each email, return a JSON object with:
        - "index": the email number (1-based)
        - "actionable": true if this needs a task, false if it's just FYI/spam/noise
        - "title": short action item title (under 80 chars). Be specific.
        - "description": 1-2 sentence context about what needs to be done
        - "priority": 0 (none), 1 (low), 2 (medium), 3 (high), 4 (urgent)
        - "type": "task", "question", "calendar", or "fyi"

        Rules:
        - Bug reports and specific requests are actionable (type: "task")
        - Questions that need answers are actionable (type: "question")
        - Calendar invites are actionable (type: "calendar")
        - Newsletters, automated notifications, and FYI emails are NOT actionable
        - Extract the actual action item as the title, not just the email subject

        Return ONLY a JSON array. No other text.

        \(emailDescriptions)
        """

        guard let raw = callClaude(prompt: prompt) else {
            return emails.map { _ in nil }
        }

        // Parse response
        var jsonStr = raw
        if jsonStr.hasPrefix("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonStr = filtered.joined(separator: "\n")
        }

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return emails.map { _ in nil }
        }

        // Map results back to email indices
        var results: [EmailTriageResult?] = emails.map { _ in nil }
        for item in array {
            guard let index = item["index"] as? Int,
                  let actionable = item["actionable"] as? Bool,
                  actionable,
                  let title = item["title"] as? String,
                  index >= 1, index <= emails.count
            else { continue }

            results[index - 1] = EmailTriageResult(
                title: title,
                description: item["description"] as? String,
                priority: min(max(item["priority"] as? Int ?? 0, 0), 4),
                type: item["type"] as? String ?? "task"
            )
        }

        return results
    }

    // MARK: - Claude CLI (same pattern as ClaudeService)

    private nonisolated static func callClaude(prompt: String) -> String? {
        guard let claudePath = findClaudeBinary() else { return nil }

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["-p", "--output-format", "text"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = inputPipe
        process.environment = ProcessInfo.processInfo.environment

        guard let promptData = prompt.data(using: .utf8) else { return nil }
        inputPipe.fileHandleForWriting.write(promptData)
        inputPipe.fileHandleForWriting.closeFile()

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func findClaudeBinary() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.nvm/current/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Fallback: `which claude`
        let which = Process()
        let pipe = Pipe()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["claude"]
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        which.environment = ProcessInfo.processInfo.environment
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty { return path }
        } catch {}
        return nil
    }
}
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add EmailTriageService for AI-powered email classification"`

---

## Task 8: Email Poller Service

Background service that ties everything together — polls Gmail accounts on a timer, filters, triages, and creates tasks.

**Files:**
- Create: `Context/Sources/Context/Services/Gmail/GmailPoller.swift`
- Modify: `Context/Sources/Context/Services/SessionWatcher.swift` (add notification name)

**Implementation:**

```swift
import Foundation
import GRDB
import Combine

@MainActor
class GmailPoller: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var newTaskCount: Int = 0

    private var timer: Timer?
    private let oauthManager: GoogleOAuthManager
    private let apiService: GmailAPIService
    private var syncInterval: TimeInterval = 300 // 5 minutes

    init(oauthManager: GoogleOAuthManager) {
        self.oauthManager = oauthManager
        self.apiService = GmailAPIService(oauthManager: oauthManager)
    }

    func startPolling(interval: TimeInterval = 300) {
        syncInterval = interval
        timer?.invalidate()
        // Run immediately, then on interval
        Task { await syncAllAccounts() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncAllAccounts()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual sync trigger
    func syncNow() async {
        await syncAllAccounts()
    }

    // MARK: - Core Sync Loop

    private func syncAllAccounts() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        var totalNew = 0

        do {
            let accounts = try DatabaseService.shared.dbQueue.read { db in
                try GmailAccount.filter(Column("isActive") == true).fetchAll(db)
            }

            for account in accounts {
                let count = await syncAccount(account)
                totalNew += count
            }

            newTaskCount = totalNew
            lastSyncDate = Date()

            if totalNew > 0 {
                NotificationCenter.default.post(name: .tasksDidChange, object: nil)
                NotificationCenter.default.post(name: .gmailDidSync, object: nil)
            }
        } catch {
            lastError = "Sync failed: \(error.localizedDescription)"
            print("GmailPoller: sync error: \(error)")
        }

        isSyncing = false
    }

    private func syncAccount(_ account: GmailAccount) async -> Int {
        // Fetch messages newer than last sync (or last 24 hours on first sync)
        let after = account.lastSyncAt ?? Date().addingTimeInterval(-86400)

        guard let listResponse = await apiService.listMessages(
            accountId: account.id,
            query: "in:inbox",
            after: after
        ) else { return 0 }

        // Filter out already-processed messages
        let existingIds = getExistingMessageIds(for: account.id)
        let newMessageIds = listResponse.messageIds.filter { !existingIds.contains($0.id) }

        guard !newMessageIds.isEmpty else {
            updateLastSync(accountId: account.id)
            return 0
        }

        // Fetch full message details
        var messages: [GmailAPIService.GmailMessage] = []
        for (msgId, _) in newMessageIds.prefix(20) {  // Cap at 20 per sync
            if let msg = await apiService.getMessage(id: msgId, accountId: account.id) {
                messages.append(msg)
            }
        }

        // Filter through whitelist
        var whitelistedMessages: [(GmailAPIService.GmailMessage, WhitelistMatch)] = []
        for msg in messages {
            let senderEmail = WhitelistFilter.extractEmail(from: msg.from)
            if let match = WhitelistFilter.check(senderEmail: senderEmail) {
                whitelistedMessages.append((msg, match))
            }
        }

        guard !whitelistedMessages.isEmpty else {
            // Still save processed IDs to avoid re-checking
            saveProcessedEmails(messages: messages, account: account, matches: [:])
            updateLastSync(accountId: account.id)
            return 0
        }

        // AI triage
        let triageInput = whitelistedMessages.map {
            (subject: $0.0.subject, from: $0.0.from, body: $0.0.body, isCalendar: $0.0.isCalendarInvite)
        }

        let triageResults = await Task.detached {
            EmailTriageService.triageEmails(triageInput)
        }.value

        // Create tasks for actionable emails
        var newTasks = 0
        for (i, (msg, match)) in whitelistedMessages.enumerated() {
            guard i < triageResults.count, let triage = triageResults[i] else { continue }

            let taskId = createTaskFromEmail(
                message: msg,
                triage: triage,
                match: match,
                accountId: account.id
            )

            saveProcessedEmail(
                message: msg,
                accountId: account.id,
                taskId: taskId,
                triageType: triage.type
            )

            newTasks += 1
        }

        updateLastSync(accountId: account.id)
        return newTasks
    }

    // MARK: - Database Helpers

    private func getExistingMessageIds(for accountId: String) -> Set<String> {
        do {
            let ids = try DatabaseService.shared.dbQueue.read { db in
                try String.fetchAll(db, sql:
                    "SELECT gmailMessageId FROM processedEmails WHERE gmailAccountId = ?",
                    arguments: [accountId]
                )
            }
            return Set(ids)
        } catch { return [] }
    }

    private func createTaskFromEmail(
        message: GmailAPIService.GmailMessage,
        triage: EmailTriageResult,
        match: WhitelistMatch,
        accountId: String
    ) -> Int64? {
        let senderName = WhitelistFilter.extractName(from: message.from)
            ?? WhitelistFilter.extractEmail(from: message.from)

        var description = "From: \(senderName)\n"
        description += "Subject: \(message.subject)\n\n"
        if let triageDesc = triage.description {
            description += triageDesc
        }

        var task = TaskItem(
            id: nil,
            projectId: "__global__",
            title: triage.title,
            description: description,
            status: "todo",
            priority: max(triage.priority, match.priority),
            sourceSession: nil,
            source: "email",
            createdAt: Date(),
            completedAt: nil,
            labels: nil,
            attachments: nil,
            isGlobal: true,
            gmailThreadId: message.threadId,
            gmailMessageId: message.id
        )

        // Set labels based on triage type
        var labels = [triage.type]
        if message.isCalendarInvite { labels.append("calendar") }
        task.setLabels(labels)

        do {
            try DatabaseService.shared.dbQueue.write { db in
                try task.insert(db)
            }
            return task.id
        } catch {
            print("GmailPoller: failed to create task: \(error)")
            return nil
        }
    }

    private func saveProcessedEmail(
        message: GmailAPIService.GmailMessage,
        accountId: String,
        taskId: Int64?,
        triageType: String
    ) {
        var email = ProcessedEmail(
            id: nil,
            gmailMessageId: message.id,
            gmailThreadId: message.threadId,
            gmailAccountId: accountId,
            fromAddress: WhitelistFilter.extractEmail(from: message.from),
            fromName: WhitelistFilter.extractName(from: message.from),
            subject: message.subject,
            snippet: message.snippet,
            body: message.body,
            receivedAt: message.date,
            taskId: taskId,
            triageType: triageType,
            isRead: false,
            repliedAt: nil,
            importedAt: Date()
        )
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try email.insert(db)
            }
        } catch {
            print("GmailPoller: failed to save processed email: \(error)")
        }
    }

    private func saveProcessedEmails(
        messages: [GmailAPIService.GmailMessage],
        account: GmailAccount,
        matches: [String: WhitelistMatch]
    ) {
        // Save non-whitelisted messages as processed (without tasks) to avoid re-fetching
        for msg in messages {
            var email = ProcessedEmail(
                id: nil,
                gmailMessageId: msg.id,
                gmailThreadId: msg.threadId,
                gmailAccountId: account.id,
                fromAddress: WhitelistFilter.extractEmail(from: msg.from),
                fromName: WhitelistFilter.extractName(from: msg.from),
                subject: msg.subject,
                snippet: msg.snippet,
                body: nil,
                receivedAt: msg.date,
                taskId: nil,
                triageType: "skipped",
                isRead: false,
                repliedAt: nil,
                importedAt: Date()
            )
            try? DatabaseService.shared.dbQueue.write { db in
                try email.insert(db)
            }
        }
    }

    private func updateLastSync(accountId: String) {
        try? DatabaseService.shared.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE gmailAccounts SET lastSyncAt = ? WHERE id = ?",
                arguments: [Date(), accountId]
            )
        }
    }
}
```

Add notification name in `SessionWatcher.swift`:

```swift
static let gmailDidSync = Notification.Name("gmailDidSync")
```

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add GmailPoller background sync service"`

---

## Task 9: AppSettings + Settings UI for Gmail

**Files:**
- Modify: `Context/Sources/Context/Services/AppSettings.swift` (add gmail settings)
- Modify: `Context/Sources/Context/Views/SettingsView.swift` (add Gmail tab)

### AppSettings additions:

```swift
@Published var gmailSyncEnabled: Bool {
    didSet { UserDefaults.standard.set(gmailSyncEnabled, forKey: "gmailSyncEnabled") }
}
@Published var gmailSyncInterval: Double {
    didSet { UserDefaults.standard.set(gmailSyncInterval, forKey: "gmailSyncInterval") }
}
```

Init additions:
```swift
self.gmailSyncEnabled = defaults.object(forKey: "gmailSyncEnabled") as? Bool ?? false
self.gmailSyncInterval = defaults.object(forKey: "gmailSyncInterval") as? Double ?? 300
```

### SettingsView — add Gmail tab with:

1. **Google API Credentials** section — Client ID text field, Client Secret secure field
2. **Gmail Accounts** section — list of connected accounts with Add/Remove buttons
3. **Sync Settings** — Enable/disable toggle, interval slider (1-30 min)
4. **Whitelist Rules** section — table with pattern, client dropdown, priority, add/edit/delete

The Gmail tab is the largest settings section. It should have sub-sections organized vertically in a scrollable Form.

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add Gmail settings tab with account management and whitelist UI"`

---

## Task 10: Wire Up GmailPoller in ContextApp

**Files:**
- Modify: `Context/Sources/Context/ContextApp.swift` (add GmailPoller as @StateObject, start polling)

Add to ContextApp:

```swift
@StateObject private var oauthManager = GoogleOAuthManager()
@StateObject private var gmailPoller: GmailPoller

init() {
    // ... existing init ...
    let oauth = GoogleOAuthManager()
    _oauthManager = StateObject(wrappedValue: oauth)
    _gmailPoller = StateObject(wrappedValue: GmailPoller(oauthManager: oauth))
}
```

In `.onAppear`:
```swift
if appSettings.gmailSyncEnabled {
    gmailPoller.startPolling(interval: appSettings.gmailSyncInterval)
}
```

Pass as environment objects to MainSplitView.

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): wire GmailPoller into app lifecycle"`

---

## Task 11: Email-Enhanced Task Cards + Reply Composer

**Files:**
- Modify: `Context/Sources/Context/Views/Tasks/TaskCard.swift` (show email badge)
- Modify: `Context/Sources/Context/Views/Tasks/TaskDetailView.swift` (add reply UI)

### TaskCard changes:
- When `task.source == "email"`, show an email icon badge and "email" source capsule
- Add "email" to the predefined labels in TaskItem

### TaskDetailView changes:
- When task has `gmailThreadId`, show:
  - Original email snippet (read from processedEmails table)
  - "Open in Gmail" button (opens `https://mail.google.com/mail/u/0/#inbox/{threadId}`)
  - Reply text editor + Send button
  - Reply sends via GmailAPIService using the account that received the original email

**Build:** `cd Context && swift build`

**Commit:** `git commit -m "feat(gmail): add email badge on task cards and reply composer"`

---

## Task 12: URL Scheme Registration + package-app.sh Update

**Files:**
- Modify: `scripts/package-app.sh` (add CFBundleURLTypes to Info.plist)

Add the `context-app://` URL scheme to the generated Info.plist so OAuth callbacks work:

```bash
# In the Info.plist generation section, add:
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>context-app</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.scope.oauth</string>
    </dict>
</array>
```

**Build, package, install:** `cd Context && swift build && cd .. && bash scripts/package-app.sh && cp -R build/Scope.app /Applications/Scope.app`

**Commit:** `git commit -m "feat(gmail): register context-app URL scheme for OAuth callbacks"`

---

## Google Cloud Console Setup (for the user)

After all code is in place, the user needs to:

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use existing one) named "Context App"
3. Enable the **Gmail API**:
   - APIs & Services → Library → Search "Gmail API" → Enable
4. Create OAuth 2.0 credentials:
   - APIs & Services → Credentials → Create Credentials → OAuth client ID
   - Application type: **Desktop app**
   - Name: "Context App"
   - Download the credentials (Client ID + Client Secret)
5. Configure OAuth consent screen:
   - APIs & Services → OAuth consent screen
   - User type: External (or Internal if Workspace)
   - App name: "Context"
   - Scopes: Add `gmail.readonly` and `gmail.send`
   - Test users: Add all 4 Gmail addresses
6. Enter the Client ID and Client Secret in Scope.app → Settings → Gmail tab
7. Click "Add Account" for each of the 4 Gmail accounts

---

## Summary of All Files

**New files (8):**
- `Context/Sources/Context/Models/GmailAccount.swift`
- `Context/Sources/Context/Models/WhitelistRule.swift`
- `Context/Sources/Context/Models/ProcessedEmail.swift`
- `Context/Sources/Context/Services/KeychainHelper.swift`
- `Context/Sources/Context/Services/Gmail/GoogleOAuthManager.swift`
- `Context/Sources/Context/Services/Gmail/GmailAPIService.swift`
- `Context/Sources/Context/Services/Gmail/WhitelistFilter.swift`
- `Context/Sources/Context/Services/Gmail/GmailPoller.swift`
- `Context/Sources/Context/Services/Gmail/EmailTriageService.swift`

**Modified files (7):**
- `Context/Sources/Context/Services/DatabaseService.swift` (migration v9)
- `Context/Sources/Context/Models/TaskItem.swift` (2 new fields)
- `Context/Sources/Context/Services/AppSettings.swift` (gmail settings)
- `Context/Sources/Context/Views/SettingsView.swift` (Gmail tab)
- `Context/Sources/Context/ContextApp.swift` (wire poller)
- `Context/Sources/Context/Views/Tasks/TaskDetailView.swift` (reply UI)
- `scripts/package-app.sh` (URL scheme)
- `Context/Sources/Context/Services/SessionWatcher.swift` (notification name)
