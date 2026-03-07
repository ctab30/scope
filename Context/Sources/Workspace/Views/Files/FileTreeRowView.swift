import SwiftUI

struct FileTreeRowView: View {
    let node: FileTreeNode
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: WorkspaceTheme.Spacing.xxs) {
            // Chevron for directories
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(WorkspaceTheme.Font.tag)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: WorkspaceTheme.Spacing.md, height: WorkspaceTheme.Spacing.md)
            } else {
                Spacer().frame(width: WorkspaceTheme.Spacing.md)
            }

            // File/folder icon
            fileIcon
                .font(WorkspaceTheme.Font.footnote)
                .frame(width: WorkspaceTheme.Spacing.lg)

            // Filename
            Text(node.name)
                .font(node.isDirectory ? WorkspaceTheme.Font.footnoteMedium : WorkspaceTheme.Font.footnote)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.leading, CGFloat(node.depth) * WorkspaceTheme.Spacing.lg)
        .padding(.horizontal, WorkspaceTheme.Spacing.sm)
        .padding(.vertical, WorkspaceTheme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                .fill(isSelected
                      ? Color.accentColor.opacity(WorkspaceTheme.Opacity.selection)
                      : isHovering ? WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.selection) : Color.clear)
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
                    .foregroundColor(.white)
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
