import SwiftUI

struct FileTreeRowView: View {
    let node: FileTreeNode
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: ScopeTheme.Spacing.xxs) {
            // Chevron for directories
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(ScopeTheme.Font.tag)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: ScopeTheme.Spacing.md, height: ScopeTheme.Spacing.md)
            } else {
                Spacer().frame(width: ScopeTheme.Spacing.md)
            }

            // File/folder icon
            fileIcon
                .font(ScopeTheme.Font.footnote)
                .frame(width: ScopeTheme.Spacing.lg)

            // Filename
            Text(node.name)
                .font(node.isDirectory ? ScopeTheme.Font.footnoteMedium : ScopeTheme.Font.footnote)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.leading, CGFloat(node.depth) * ScopeTheme.Spacing.lg)
        .padding(.horizontal, ScopeTheme.Spacing.sm)
        .padding(.vertical, ScopeTheme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                .fill(isSelected
                      ? Color.accentColor.opacity(ScopeTheme.Opacity.selection)
                      : isHovering ? ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.selection) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - File Icon

    @ViewBuilder
    private var fileIcon: some View {
        if node.isDirectory {
            Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                .foregroundColor(.accentColor)
        } else {
            let ext = (node.name as NSString).pathExtension.lowercased()
            switch ext {
            case "swift":
                Image(systemName: "swift")
                    .foregroundColor(.orange)
            case "js", "jsx", "ts", "tsx":
                Image(systemName: "doc.text")
                    .foregroundColor(.yellow)
            case "py":
                Image(systemName: "doc.text")
                    .foregroundColor(.blue)
            case "json", "yaml", "yml", "toml":
                Image(systemName: "gearshape")
                    .foregroundColor(.gray)
            case "md", "markdown":
                Image(systemName: "doc.richtext")
                    .foregroundColor(.secondary)
            case "html", "htm", "css":
                Image(systemName: "globe")
                    .foregroundColor(.purple)
            default:
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
            }
        }
    }
}
