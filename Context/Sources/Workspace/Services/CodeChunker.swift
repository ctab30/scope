import Foundation

/// Splits source code files into semantic chunks (functions, classes, blocks)
/// using regex heuristics. Also handles markdown docs and git commits.
struct CodeChunker {

    struct Chunk {
        let chunkType: String       // "function", "class", "block", "doc", "commit", "header"
        let symbolName: String?     // e.g. "BrowserTab.uploadFile"
        let content: String
        let startLine: Int?
        let endLine: Int?
    }

    // MARK: - Public API

    /// Chunk a source code file based on its language.
    static func chunkFile(content: String, language: String, filePath: String) -> [Chunk] {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        switch language {
        case "swift":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: swiftPatterns)
        case "typescript", "javascript", "tsx", "jsx":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: tsPatterns)
        case "python":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: pythonPatterns)
        case "rust":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: rustPatterns)
        case "go":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: goPatterns)
        case "dart":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: dartPatterns)
        case "java":
            return chunkByBoundaries(lines: lines, filePath: filePath, patterns: javaPatterns)
        default:
            return chunkByFixedSize(lines: lines, filePath: filePath)
        }
    }

    /// Chunk a markdown file by headings.
    static func chunkMarkdown(content: String, filePath: String) -> [Chunk] {
        let lines = content.components(separatedBy: "\n")
        var chunks: [Chunk] = []
        var currentSection: [String] = []
        var currentHeading: String? = nil
        var sectionStart = 1

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                if !currentSection.isEmpty {
                    let text = currentSection.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.count >= 20 {
                        chunks.append(Chunk(
                            chunkType: "doc",
                            symbolName: currentHeading,
                            content: text,
                            startLine: sectionStart,
                            endLine: i
                        ))
                    }
                }
                currentHeading = line.trimmingCharacters(in: .init(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
                currentSection = [line]
                sectionStart = i + 1
            } else {
                currentSection.append(line)
            }
        }

        if !currentSection.isEmpty {
            let text = currentSection.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 20 {
                chunks.append(Chunk(
                    chunkType: "doc",
                    symbolName: currentHeading,
                    content: text,
                    startLine: sectionStart,
                    endLine: lines.count
                ))
            }
        }

        return chunks
    }

    /// Create chunks from git commit history.
    static func chunkGitHistory(_ gitLog: String) -> [Chunk] {
        let lines = gitLog.components(separatedBy: "\n")
        var chunks: [Chunk] = []
        var current: [String] = []

        for line in lines {
            if line.range(of: #"^[0-9a-f]{7,} "#, options: .regularExpression) != nil {
                if !current.isEmpty {
                    let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        chunks.append(Chunk(chunkType: "commit", symbolName: nil, content: text, startLine: nil, endLine: nil))
                    }
                }
                current = [line]
            } else {
                current.append(line)
            }
        }

        if !current.isEmpty {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunks.append(Chunk(chunkType: "commit", symbolName: nil, content: text, startLine: nil, endLine: nil))
            }
        }

        return chunks
    }

    // MARK: - Language Patterns

    struct BoundaryPattern {
        let regex: String
        let type: String
        let nameExtractor: (String) -> String?
    }

    static let swiftPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(public |private |internal |open |fileprivate )?(static |class )?(func |init\(|deinit\b)"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:func\s+(\w+)|init\(|deinit)"#) }),
        BoundaryPattern(regex: #"^\s*(public |private |internal |open |fileprivate )?(final )?(class |struct |enum |protocol |extension )"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|struct|enum|protocol|extension)\s+(\w+)"#) }),
    ]

    static let tsPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(export\s+)?(async\s+)?function\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"function\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*(export\s+)?(const|let|var)\s+\w+\s*=\s*(async\s+)?\("#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:const|let|var)\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*(export\s+)?(abstract\s+)?(class|interface|type)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|interface|type)\s+(\w+)"#) }),
    ]

    static let pythonPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(async\s+)?def\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"def\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*class\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"class\s+(\w+)"#) }),
    ]

    static let rustPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(pub\s+)?(async\s+)?fn\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"fn\s+(\w+)"#) }),
        BoundaryPattern(regex: #"^\s*(pub\s+)?(struct|enum|impl|trait)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:struct|enum|impl|trait)\s+(\w+)"#) }),
    ]

    static let goPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^func\s+"#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"func\s+(?:\(\w+\s+\*?\w+\)\s+)?(\w+)"#) }),
        BoundaryPattern(regex: #"^type\s+\w+\s+(struct|interface)"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"type\s+(\w+)"#) }),
    ]

    static let dartPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(static\s+)?\w+[\w<>,\s]*\s+\w+\s*\("#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(\w+)\s*\("#) }),
        BoundaryPattern(regex: #"^\s*(abstract\s+)?(class|mixin)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|mixin)\s+(\w+)"#) }),
    ]

    static let javaPatterns: [BoundaryPattern] = [
        BoundaryPattern(regex: #"^\s*(public |private |protected )?(static )?\w+[\w<>,\s]*\s+\w+\s*\("#, type: "function",
                        nameExtractor: { line in extractName(from: line, pattern: #"(\w+)\s*\("#) }),
        BoundaryPattern(regex: #"^\s*(public |private |protected )?(abstract )?(class|interface|enum)\s+"#, type: "class",
                        nameExtractor: { line in extractName(from: line, pattern: #"(?:class|interface|enum)\s+(\w+)"#) }),
    ]

    // MARK: - Chunking Logic

    private static let maxChunkLines = 100
    private static let minChunkLines = 5

    private static func chunkByBoundaries(lines: [String], filePath: String, patterns: [BoundaryPattern]) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentLines: [String] = []
        var currentType = "block"
        var currentSymbol: String? = nil
        var currentParent: String? = nil
        var chunkStartLine = 1

        var headerEnd = 0
        for (i, line) in lines.enumerated() {
            if matchesBoundary(line, patterns: patterns) != nil {
                headerEnd = i
                break
            }
            if i > 30 { headerEnd = i; break }
        }

        if headerEnd > 0 {
            let headerContent = lines[0..<headerEnd].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !headerContent.isEmpty {
                chunks.append(Chunk(chunkType: "header", symbolName: nil, content: headerContent, startLine: 1, endLine: headerEnd))
            }
        }

        for i in headerEnd..<lines.count {
            let line = lines[i]

            if let match = matchesBoundary(line, patterns: patterns) {
                if !currentLines.isEmpty {
                    emitChunk(lines: currentLines, type: currentType, symbol: currentSymbol, parent: currentParent, startLine: chunkStartLine, into: &chunks)
                }

                if match.type == "class" {
                    currentParent = match.name
                }

                currentLines = [line]
                currentType = match.type
                if match.type == "function", let parent = currentParent {
                    currentSymbol = "\(parent).\(match.name ?? "unknown")"
                } else {
                    currentSymbol = match.name
                }
                chunkStartLine = i + 1
            } else {
                currentLines.append(line)

                if currentLines.count >= maxChunkLines {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        emitChunk(lines: currentLines, type: currentType, symbol: currentSymbol, parent: currentParent, startLine: chunkStartLine, into: &chunks)
                        currentLines = []
                        currentType = "block"
                        currentSymbol = nil
                        chunkStartLine = i + 2
                    }
                }
            }
        }

        if !currentLines.isEmpty {
            emitChunk(lines: currentLines, type: currentType, symbol: currentSymbol, parent: currentParent, startLine: chunkStartLine, into: &chunks)
        }

        return chunks
    }

    private static func chunkByFixedSize(lines: [String], filePath: String) -> [Chunk] {
        var chunks: [Chunk] = []
        let windowSize = 50
        let overlap = 10

        var i = 0
        while i < lines.count {
            let end = min(i + windowSize, lines.count)
            let content = lines[i..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                chunks.append(Chunk(chunkType: "block", symbolName: nil, content: content, startLine: i + 1, endLine: end))
            }
            i += windowSize - overlap
        }

        return chunks
    }

    // MARK: - Helpers

    private struct BoundaryMatch {
        let type: String
        let name: String?
    }

    private static func matchesBoundary(_ line: String, patterns: [BoundaryPattern]) -> BoundaryMatch? {
        for pattern in patterns {
            if line.range(of: pattern.regex, options: .regularExpression) != nil {
                let name = pattern.nameExtractor(line)
                return BoundaryMatch(type: pattern.type, name: name)
            }
        }
        return nil
    }

    private static func extractName(from line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) {
            return String(line[range])
        }
        return nil
    }

    private static func emitChunk(
        lines: [String],
        type: String,
        symbol: String?,
        parent: String?,
        startLine: Int,
        into chunks: inout [Chunk]
    ) {
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 20 else { return }
        if lines.count < minChunkLines && type == "block" { return }

        chunks.append(Chunk(
            chunkType: type,
            symbolName: symbol,
            content: content,
            startLine: startLine,
            endLine: startLine + lines.count - 1
        ))
    }

    // MARK: - Language Detection

    static func detectLanguage(from path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "js": return "javascript"
        case "jsx": return "jsx"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "dart": return "dart"
        case "java": return "java"
        case "md", "markdown": return "markdown"
        default: return nil
        }
    }

    static func isIndexable(_ path: String) -> Bool {
        return detectLanguage(from: path) != nil
    }
}
