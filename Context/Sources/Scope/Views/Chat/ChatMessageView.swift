import SwiftUI

struct ChatMessageView: View {
    let message: ChatMessage
    let projectId: String?
    let onCreateTask: (String) -> Void
    let onAddToNotes: (String) -> Void
    let onSendToTerminal: (String) -> Void

    @State private var isHovering = false
    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == "user" {
                Spacer(minLength: 60)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: ScopeTheme.Spacing.xxxs) {
            Text(message.content)
                .font(ScopeTheme.Font.body)
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, ScopeTheme.Spacing.md)
                .padding(.vertical, ScopeTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.medium, style: .continuous)
                        .fill(Color.accentColor)
                )

            Text(message.createdAt.formatted(.dateTime.hour().minute()))
                .font(ScopeTheme.Font.tag)
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxs) {
            MarkdownContentView(content: message.content)
                .padding(.horizontal, ScopeTheme.Spacing.md)
                .padding(.vertical, ScopeTheme.Spacing.sm)
                .background(
                    ScopeTheme.Colors.controlBg,
                    in: RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                        .strokeBorder(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
                )

            // Action buttons — show on hover
            if isHovering {
                HStack(spacing: 2) {
                    actionButton("Create Task", icon: "checklist") {
                        onCreateTask(message.content)
                    }
                    actionButton("Add to Notes", icon: "note.text.badge.plus") {
                        onAddToNotes(message.content)
                    }
                    actionButton(showCopied ? "Copied!" : "Copy", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            showCopied = false
                        }
                    }
                    actionButton("To Terminal", icon: "terminal") {
                        onSendToTerminal(message.content)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text(message.createdAt.formatted(.dateTime.hour().minute()))
                .font(ScopeTheme.Font.tag)
                .foregroundStyle(.quaternary)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Action Button

    private func actionButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Markdown Content View

/// Parses markdown into block-level elements and renders each with proper styling.
private struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block Types

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case listItem(text: String)
        case numberedItem(number: String, text: String)
        case blockquote(text: String)
        case codeBlock(code: String, language: String?)
        case divider
    }

    // MARK: - Parser

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block (fenced)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(
                    code: codeLines.joined(separator: "\n"),
                    language: language.isEmpty ? nil : language
                ))
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, text: text))
                    i += 1
                    continue
                }
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("> ") {
                        quoteLines.append(String(l.dropFirst(2)))
                    } else if l == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append(.listItem(text: text))
                i += 1
                continue
            }

            // Numbered list item
            if let match = trimmed.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) {
                let prefix = String(trimmed[match])
                let number = prefix.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
                let text = String(trimmed[match.upperBound...])
                blocks.append(.numberedItem(number: number, text: text))
                i += 1
                continue
            }

            // Empty line — skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("```") || l.hasPrefix("> ")
                    || l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ")
                    || l == "---" || l == "***" || l == "___" {
                    break
                }
                if let _ = l.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) {
                    break
                }
                paraLines.append(lines[i])
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            inlineText(text)
                .font(ScopeTheme.Font.body)

        case .listItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: ScopeTheme.Spacing.xs) {
                Text("\u{2022}")
                    .font(ScopeTheme.Font.body)
                    .foregroundColor(.secondary)
                inlineText(text)
                    .font(ScopeTheme.Font.body)
            }
            .padding(.leading, ScopeTheme.Spacing.xxs)

        case .numberedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: ScopeTheme.Spacing.xs) {
                Text("\(number).")
                    .font(ScopeTheme.Font.body)
                    .foregroundColor(.secondary)
                    .frame(minWidth: ScopeTheme.Spacing.lg, alignment: .trailing)
                inlineText(text)
                    .font(ScopeTheme.Font.body)
            }
            .padding(.leading, ScopeTheme.Spacing.xxs)

        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                inlineText(text)
                    .font(ScopeTheme.Font.body)
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, ScopeTheme.Spacing.sm)
            }
            .padding(.vertical, ScopeTheme.Spacing.xxxs)

        case .codeBlock(let code, _):
            Text(code)
                .font(ScopeTheme.Font.mono)
                .padding(ScopeTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .fill(ScopeTheme.Colors.textBg.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
                )
                .textSelection(.enabled)

        case .divider:
            Divider()
                .padding(.vertical, ScopeTheme.Spacing.xxxs)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14
        case 3: return 13
        default: return 12
        }
    }

    // MARK: - Inline Markdown Rendering

    /// Renders inline markdown: **bold**, *italic*, `code`, [links](url)
    private func inlineText(_ text: String) -> Text {
        var result = Text("")
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Bold: **text**
            if remaining.hasPrefix("**"),
               let endRange = remaining[remaining.index(remaining.startIndex, offsetBy: 2)...]
                .range(of: "**") {
                let inner = remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<endRange.lowerBound]
                result = result + Text(inner).bold()
                remaining = remaining[endRange.upperBound...]
                continue
            }

            // Inline code: `code`
            if remaining.hasPrefix("`"),
               let endIdx = remaining[remaining.index(after: remaining.startIndex)...]
                .firstIndex(of: "`") {
                let inner = remaining[remaining.index(after: remaining.startIndex)..<endIdx]
                result = result + Text(inner)
                    .font(ScopeTheme.Font.mono)
                    .foregroundColor(Color(nsColor: .systemOrange))
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }

            // Italic: *text* (but not **)
            if remaining.hasPrefix("*") && !remaining.hasPrefix("**"),
               let endIdx = remaining[remaining.index(after: remaining.startIndex)...]
                .firstIndex(of: "*") {
                let inner = remaining[remaining.index(after: remaining.startIndex)..<endIdx]
                result = result + Text(inner).italic()
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }

            // Plain character
            let nextSpecial = remaining.dropFirst().firstIndex(where: { $0 == "*" || $0 == "`" })
                ?? remaining.endIndex
            result = result + Text(remaining[remaining.startIndex..<nextSpecial])
            remaining = remaining[nextSpecial...]
        }

        return result
    }
}
