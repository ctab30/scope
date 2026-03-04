import SwiftUI

struct TaskCardView: View {
    let task: TaskItem
    var projectName: String? = nil
    var onProjectTap: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @EnvironmentObject var settings: AppSettings
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
            // Title + priority tag
            HStack(alignment: .top, spacing: ScopeTheme.Spacing.xs) {
                Text(settings.demoMode ? DemoContent.shared.mask(task.title, as: .task) : task.title)
                    .font(ScopeTheme.Font.footnoteMedium)
                    .lineLimit(2)

                Spacer()

                if task.priority > 0 {
                    Text(task.priorityLevel.label.uppercased())
                        .font(ScopeTheme.Font.tag)
                        .tracking(0.3)
                        .foregroundColor(task.priorityLevel.color)
                }
            }

            if let description = task.description, !description.isEmpty {
                Text(settings.demoMode ? DemoContent.shared.mask(description, as: .snippet) : description)
                    .font(ScopeTheme.Font.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            // Labels
            let labels = task.labelsArray
            if !labels.isEmpty {
                HStack(spacing: ScopeTheme.Spacing.xs) {
                    ForEach(labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(ScopeTheme.Font.tag)
                            .textCase(.uppercase)
                            .tracking(0.3)
                            .foregroundColor(TaskItem.labelColor(for: label))
                    }
                    if labels.count > 3 {
                        Text("+\(labels.count - 3)")
                            .font(ScopeTheme.Font.tag)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: ScopeTheme.Spacing.xs) {
                Text(task.source)
                    .font(ScopeTheme.Font.tag)
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .foregroundColor(sourceColor)

                if let projectName = projectName {
                    Button {
                        onProjectTap?()
                    } label: {
                        Text(settings.demoMode ? DemoContent.shared.mask(projectName, as: .project) : projectName)
                            .font(ScopeTheme.Font.tag)
                            .lineLimit(1)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text(task.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(ScopeTheme.Font.tag)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, ScopeTheme.Spacing.sm)
        .padding(.vertical, ScopeTheme.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var sourceColor: Color {
        switch task.source {
        case "claude": return .blue
        case "ai-extracted": return .purple
        case "email": return .green
        case "browser": return .white
        case "chat": return .indigo
        default: return .secondary
        }
    }
}
