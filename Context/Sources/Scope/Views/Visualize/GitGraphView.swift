import SwiftUI

struct GitGraphView: View {
    @EnvironmentObject var analyzer: ProjectAnalyzer

    @State private var hoveredCommit: String?
    @State private var selectedCommit: String?

    var body: some View {
        if analyzer.gitCommits.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Stats header
                    HStack(spacing: 16) {
                        Label("\(analyzer.gitCommits.count) commits", systemImage: "circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        let uniqueAuthors = Set(analyzer.gitCommits.map(\.author)).count
                        Label("\(uniqueAuthors) authors", systemImage: "person.2")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        let mergeCount = analyzer.gitCommits.filter(\.isMerge).count
                        if mergeCount > 0 {
                            Label("\(mergeCount) merges", systemImage: "arrow.triangle.merge")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    // Commit timeline
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(analyzer.gitCommits.enumerated()), id: \.element.id) { index, commit in
                            commitRow(commit, isLast: index == analyzer.gitCommits.count - 1)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Commit Row

    private func commitRow(_ commit: GitCommit, isLast: Bool) -> some View {
        let isHovered = hoveredCommit == commit.id
        let isSelected = selectedCommit == commit.id

        return HStack(alignment: .top, spacing: 0) {
            // Timeline spine
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 1.5)
                    .frame(height: 12)

                // Commit dot
                ZStack {
                    if commit.isMerge {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.purple)
                            .frame(width: 16, height: 16)
                    } else {
                        Circle()
                            .fill(isSelected ? Color.accentColor : commitColor(for: commit))
                            .frame(width: isHovered ? 10 : 8, height: isHovered ? 10 : 8)
                    }
                }
                .frame(width: 16, height: 16)

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 32)

            // Commit content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    // SHA badge
                    Text(commit.shortSHA)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.1))
                        )

                    // Branch tags
                    ForEach(commit.branches, id: \.self) { branch in
                        Text(branch)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.purple.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.purple.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }

                // Message
                Text(commit.message)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(isSelected ? nil : 2)
                    .textSelection(.enabled)

                // Author + date
                HStack(spacing: 8) {
                    Text(commit.author)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(commit.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 16)
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered
                      ? Color(nsColor: .controlBackgroundColor).opacity(0.6)
                      : isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        )
        .onHover { hover in
            hoveredCommit = hover ? commit.id : nil
        }
        .onTapGesture {
            selectedCommit = selectedCommit == commit.id ? nil : commit.id
        }
    }

    // MARK: - Helpers

    private func commitColor(for commit: GitCommit) -> Color {
        // Color by author (deterministic hash)
        let hash = abs(commit.author.hashValue)
        let colors: [Color] = [.blue, .green, .orange, .purple, .teal, .cyan, .pink, .mint]
        return colors[hash % colors.count]
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No git history found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Make sure the project is a git repository")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
