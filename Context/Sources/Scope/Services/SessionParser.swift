import Foundation

/// Structured data extracted from a Claude Code session JSONL file.
struct ParsedSession {
    let sessionId: String
    let slug: String?
    let model: String?
    let gitBranch: String?
    let startedAt: Date?
    let endedAt: Date?
    let messageCount: Int
    let toolUseCount: Int
    let filesChanged: [String]
    let userMessages: [String]
    let toolNames: [String]
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
}

/// Parses Claude Code `.jsonl` session files into structured data.
///
/// Claude Code stores session history as JSONL files where each line is a JSON object
/// with a `type` field. Supported types: `user`, `assistant`. Types like `progress`
/// and `file-history-snapshot` are ignored.
class SessionParser {

    // MARK: - Date Formatter

    /// ISO 8601 formatter that handles fractional seconds (e.g. "2026-02-10T19:26:42.314Z").
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Parsing

    /// Parse a Claude Code session JSONL file into structured data.
    ///
    /// Reads the file line-by-line, extracting session metadata, messages,
    /// tool usage, and file paths from tool inputs.
    ///
    /// - Parameter fileURL: URL to the `.jsonl` session file.
    /// - Returns: A `ParsedSession` if the file contains a valid session, or `nil`
    ///   if the file is empty or contains no session ID.
    /// - Throws: File reading errors from `Data(contentsOf:)`.
    static func parse(fileURL: URL) throws -> ParsedSession? {
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var sessionId: String?
        var slug: String?
        var model: String?
        var gitBranch: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var messageCount = 0
        var toolUseCount = 0
        var filesChanged = Set<String>()
        var userMessages: [String] = []
        var toolNames: [String] = []
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Extract session metadata (can appear on any line type)
            if let sid = json["sessionId"] as? String {
                sessionId = sid
            }
            if let s = json["slug"] as? String {
                slug = s
            }
            if let branch = json["gitBranch"] as? String {
                gitBranch = branch
            }

            // Extract and track timestamps
            if let ts = json["timestamp"] as? String,
               let date = isoFormatter.date(from: ts) {
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }

            let type = json["type"] as? String

            // Skip non-message types (progress, file-history-snapshot, etc.)
            guard type == "user" || type == "assistant" else { continue }

            // Count messages
            messageCount += 1

            if type == "user" {
                extractUserMessages(from: json, into: &userMessages)
            }

            if type == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }

                // Extract model
                if let m = message["model"] as? String {
                    model = m
                }

                // Extract token usage
                if let usage = message["usage"] as? [String: Any] {
                    inputTokens         += usage["input_tokens"]                as? Int ?? 0
                    outputTokens        += usage["output_tokens"]               as? Int ?? 0
                    cacheCreationTokens += usage["cache_creation_input_tokens"]  as? Int ?? 0
                    cacheReadTokens     += usage["cache_read_input_tokens"]      as? Int ?? 0
                }

                // Extract tool use blocks from assistant messages
                extractToolUse(
                    from: json,
                    toolUseCount: &toolUseCount,
                    toolNames: &toolNames,
                    filesChanged: &filesChanged
                )
            }
        }

        guard let sid = sessionId else { return nil }

        return ParsedSession(
            sessionId: sid,
            slug: slug,
            model: model,
            gitBranch: gitBranch,
            startedAt: firstTimestamp,
            endedAt: lastTimestamp,
            messageCount: messageCount,
            toolUseCount: toolUseCount,
            filesChanged: Array(filesChanged).sorted(),
            userMessages: userMessages,
            toolNames: toolNames,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    // MARK: - Summary Generation

    /// Generate a brief summary from parsed session data.
    ///
    /// Uses the first user message (truncated to 200 characters) as the topic,
    /// and appends a list of files changed if any.
    ///
    /// - Parameter parsed: The parsed session to summarize.
    /// - Returns: A human-readable summary string.
    static func generateSummary(from parsed: ParsedSession) -> String {
        var parts: [String] = []

        // Use first user message as topic (truncated)
        if let firstMessage = parsed.userMessages.first {
            let topic = String(firstMessage.prefix(200))
            parts.append(topic)
        }

        if !parsed.filesChanged.isEmpty {
            let fileList = parsed.filesChanged.prefix(10).joined(separator: ", ")
            let suffix = parsed.filesChanged.count > 10
                ? " (+\(parsed.filesChanged.count - 10) more)"
                : ""
            parts.append("Files: \(fileList)\(suffix)")
        }

        return parts.joined(separator: " | ")
    }

    // MARK: - Private Helpers

    /// Extract user message text from a user-type JSON line.
    ///
    /// Handles both formats:
    /// - `message.content` as an array of `{type, text}` blocks
    /// - `message.content` as a plain string
    private static func extractUserMessages(
        from json: [String: Any],
        into userMessages: inout [String]
    ) {
        guard let message = json["message"] as? [String: Any] else { return }

        // Handle content as array of blocks
        if let contentArray = message["content"] as? [[String: Any]] {
            for block in contentArray {
                if block["type"] as? String == "text",
                   let text = block["text"] as? String {
                    userMessages.append(text)
                }
            }
        }

        // Handle content as plain string
        if let contentString = message["content"] as? String {
            userMessages.append(contentString)
        }
    }

    /// Extract tool use information from an assistant-type JSON line.
    ///
    /// Looks for `tool_use` blocks in `message.content`, counting them,
    /// recording tool names, and extracting `file_path` from tool inputs.
    private static func extractToolUse(
        from json: [String: Any],
        toolUseCount: inout Int,
        toolNames: inout [String],
        filesChanged: inout Set<String>
    ) {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }

        for block in content {
            guard block["type"] as? String == "tool_use" else { continue }

            toolUseCount += 1

            if let toolName = block["name"] as? String {
                toolNames.append(toolName)
            }

            // Extract file paths from tool inputs
            if let input = block["input"] as? [String: Any],
               let filePath = input["file_path"] as? String {
                filesChanged.insert(filePath)
            }
        }
    }
}
