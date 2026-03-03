import SwiftUI

struct TaskCardView: View {
    let task: TaskItem
    var projectName: String? = nil
    var onProjectTap: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @EnvironmentObject var settings: AppSettings
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title + priority
            HStack(alignment: .top, spacing: 6) {
                if task.priority > 0 {
                    Image(systemName: task.priorityLevel.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(task.priorityLevel.color)
                        .frame(width: 12)
                        .padding(.top, 2)
                }
                Text(settings.demoMode ? DemoContent.shared.mask(task.title, as: .task) : task.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }

            if let description = task.description, !description.isEmpty {
                Text(settings.demoMode ? DemoContent.shared.mask(description, as: .snippet) : description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            // Labels
            let labels = task.labelsArray
            if !labels.isEmpty {
                HStack(spacing: 3) {
                    ForEach(labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 8, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(0.2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(TaskItem.labelColor(for: label).opacity(0.12))
                            )
                            .foregroundColor(TaskItem.labelColor(for: label))
                    }
                    if labels.count > 3 {
                        Text("+\(labels.count - 3)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                // Source badge
                Text(task.source)
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(sourceColor.opacity(0.12))
                    )
                    .foregroundColor(sourceColor)

                if let projectName = projectName {
                    Button {
                        onProjectTap?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 8))
                            Text(settings.demoMode ? DemoContent.shared.mask(projectName, as: .project) : projectName)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text(task.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.15 : 0.08), radius: isHovering ? 4 : 2, y: isHovering ? 2 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
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
        case "browser": return .orange
        case "chat": return .indigo
        default: return .secondary
        }
    }
}
