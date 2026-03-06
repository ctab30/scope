import SwiftUI
import AppKit

struct GitChangesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var githubService: GitHubService
    @StateObject private var gitService = GitChangesService()

    @State private var commitMessage: String = ""
    @State private var collapsedSections: Set<String> = []
    @State private var isCommitting = false

    var body: some View {
        Group {
            if !gitService.isGitRepo && !gitService.isLoading {
                emptyState
            } else {
                changesContent
            }
        }
        .onAppear { scanProject() }
        .onChange(of: appState.currentProject?.id) { scanProject() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: ScopeTheme.Spacing.md) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("Not a Git Repository")
                .font(ScopeTheme.Font.headline)
                .foregroundColor(.secondary)

            Text("This project is not tracked by Git. Initialize a repository to see changes here.")
                .font(ScopeTheme.Font.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Changes Content

    private var changesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                header
                    .padding(.horizontal, ScopeTheme.Spacing.xl)
                    .padding(.vertical, ScopeTheme.Spacing.md)

                Divider()

                // Commit Composer
                commitComposer
                    .padding(.horizontal, ScopeTheme.Spacing.xl)
                    .padding(.vertical, ScopeTheme.Spacing.md)

                Divider()

                // Staged Changes
                sectionHeader(
                    title: "Staged Changes",
                    icon: "checkmark.circle.fill",
                    count: gitService.stagedFiles.count,
                    key: "staged",
                    accentColor: .green
                )

                if !collapsedSections.contains("staged") {
                    if gitService.stagedFiles.isEmpty {
                        sectionEmpty("No staged changes")
                    } else {
                        LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                            ForEach(gitService.stagedFiles) { file in
                                fileRow(file, isStaged: true)
                            }
                        }
                        .padding(.horizontal, ScopeTheme.Spacing.xl)
                        .padding(.bottom, ScopeTheme.Spacing.sm)
                    }
                }

                Divider()

                // Unstaged Changes
                sectionHeader(
                    title: "Changes",
                    icon: "circle.dashed",
                    count: gitService.unstagedFiles.count,
                    key: "unstaged",
                    accentColor: .white
                )

                if !collapsedSections.contains("unstaged") {
                    if gitService.unstagedFiles.isEmpty {
                        sectionEmpty("No unstaged changes")
                    } else {
                        LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                            ForEach(gitService.unstagedFiles) { file in
                                fileRow(file, isStaged: false)
                            }
                        }
                        .padding(.horizontal, ScopeTheme.Spacing.xl)
                        .padding(.bottom, ScopeTheme.Spacing.sm)
                    }
                }

                Divider()

                // Untracked Files
                sectionHeader(
                    title: "Untracked",
                    icon: "questionmark.circle",
                    count: gitService.untrackedFiles.count,
                    key: "untracked",
                    accentColor: .secondary
                )

                if !collapsedSections.contains("untracked") {
                    if gitService.untrackedFiles.isEmpty {
                        sectionEmpty("No untracked files")
                    } else {
                        LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                            ForEach(gitService.untrackedFiles) { file in
                                fileRow(file, isStaged: false)
                            }
                        }
                        .padding(.horizontal, ScopeTheme.Spacing.xl)
                        .padding(.bottom, ScopeTheme.Spacing.sm)
                    }
                }

                Divider()

                // Recent Commits
                sectionHeader(
                    title: "Recent Commits",
                    icon: "clock",
                    count: gitService.recentCommits.count,
                    key: "commits",
                    accentColor: .secondary
                )

                if !collapsedSections.contains("commits") {
                    if gitService.recentCommits.isEmpty {
                        sectionEmpty("No commits yet")
                    } else {
                        LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                            ForEach(gitService.recentCommits) { entry in
                                commitRow(entry)
                            }
                        }
                        .padding(.horizontal, ScopeTheme.Spacing.xl)
                        .padding(.bottom, ScopeTheme.Spacing.sm)
                    }
                }

                // MARK: - GitHub Sections
                if githubService.isAvailable {
                    Divider()

                    // GitHub header
                    HStack(spacing: ScopeTheme.Spacing.xs) {
                        Image(systemName: "link")
                            .font(ScopeTheme.Font.caption)
                            .foregroundStyle(.tertiary)
                        if let repo = githubService.repo {
                            Text("\(repo.owner)/\(repo.name)")
                                .font(ScopeTheme.Font.footnoteMedium)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if githubService.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal, ScopeTheme.Spacing.xl)
                    .padding(.vertical, ScopeTheme.Spacing.sm)

                    Divider()

                    // Pull Requests
                    sectionHeader(
                        title: "Pull Requests",
                        icon: "arrow.triangle.pull",
                        count: githubService.pullRequests.count,
                        key: "prs",
                        accentColor: .purple
                    )

                    if !collapsedSections.contains("prs") {
                        if githubService.pullRequests.isEmpty {
                            sectionEmpty("No open pull requests")
                        } else {
                            LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                                ForEach(githubService.pullRequests) { pr in
                                    prRow(pr)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        }
                    }

                    Divider()

                    // CI / Workflows
                    sectionHeader(
                        title: "CI / Workflows",
                        icon: "gearshape.2",
                        count: githubService.workflows.count,
                        key: "ci",
                        accentColor: .cyan
                    )

                    if !collapsedSections.contains("ci") {
                        if githubService.workflows.isEmpty {
                            sectionEmpty("No recent workflow runs")
                        } else {
                            LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                                ForEach(githubService.workflows) { workflow in
                                    workflowRow(workflow)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        }
                    }

                    Divider()

                    // Issues
                    sectionHeader(
                        title: "Issues",
                        icon: "exclamationmark.circle",
                        count: githubService.issues.count,
                        key: "issues",
                        accentColor: .yellow
                    )

                    if !collapsedSections.contains("issues") {
                        if githubService.issues.isEmpty {
                            sectionEmpty("No issues assigned to you")
                        } else {
                            LazyVStack(spacing: ScopeTheme.Spacing.xxs) {
                                ForEach(githubService.issues) { issue in
                                    issueRow(issue)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .padding(.bottom, ScopeTheme.Spacing.xl)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ScopeTheme.Spacing.sm) {
            Image(systemName: "arrow.triangle.branch")
                .font(ScopeTheme.Font.footnoteMedium)
                .foregroundColor(.secondary)

            Menu {
                ForEach(gitService.branches, id: \.self) { branch in
                    Button {
                        Task { await gitService.checkout(branch: branch) }
                    } label: {
                        HStack {
                            Text(branch)
                            if branch == gitService.currentBranch {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(branch == gitService.currentBranch)
                }
            } label: {
                HStack(spacing: ScopeTheme.Spacing.xxs) {
                    Text(gitService.currentBranch)
                        .font(ScopeTheme.Font.mono)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            let totalChanges = gitService.stagedFiles.count + gitService.unstagedFiles.count + gitService.untrackedFiles.count
            if totalChanges > 0 {
                Text("\(totalChanges)")
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, ScopeTheme.Spacing.xs)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            }

            Spacer()

            if gitService.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }

            Button {
                Task { await gitService.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(ScopeTheme.Font.footnoteMedium)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    // MARK: - Commit Composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: ScopeTheme.Spacing.sm) {
            Text("Commit Message")
                .font(ScopeTheme.Font.footnoteSemibold)
                .foregroundColor(.secondary)

            TextEditor(text: $commitMessage)
                .font(ScopeTheme.Font.mono)
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .padding(ScopeTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .fill(ScopeTheme.Colors.controlBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .stroke(ScopeTheme.Colors.separator.opacity(0.5), lineWidth: 0.5)
                )

            HStack(spacing: ScopeTheme.Spacing.sm) {
                Button {
                    gitService.stageAll()
                } label: {
                    Text("Stage All")
                        .font(ScopeTheme.Font.footnoteMedium)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, ScopeTheme.Spacing.md)
                .padding(.vertical, ScopeTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .fill(Color.green.opacity(ScopeTheme.Opacity.selection))
                )
                .foregroundColor(.green)

                Button {
                    gitService.unstageAll()
                } label: {
                    Text("Unstage All")
                        .font(ScopeTheme.Font.footnoteMedium)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, ScopeTheme.Spacing.md)
                .padding(.vertical, ScopeTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .fill(Color.white.opacity(ScopeTheme.Opacity.selection))
                )
                .foregroundColor(.white)

                Spacer()

                Button {
                    performCommit()
                } label: {
                    HStack(spacing: ScopeTheme.Spacing.xxs) {
                        if isCommitting {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        }
                        Text("Commit")
                            .font(ScopeTheme.Font.footnoteSemibold)
                    }
                    .padding(.horizontal, ScopeTheme.Spacing.md)
                    .padding(.vertical, ScopeTheme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                            .fill(canCommit ? Color.accentColor : Color.secondary.opacity(ScopeTheme.Opacity.border))
                    )
                    .foregroundColor(canCommit ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canCommit || isCommitting)
            }
        }
    }

    private var canCommit: Bool {
        !gitService.stagedFiles.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(title: String, icon: String, count: Int, key: String, accentColor: Color) -> some View {
        let isCollapsed = collapsedSections.contains(key)

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isCollapsed {
                    collapsedSections.remove(key)
                } else {
                    collapsedSections.insert(key)
                }
            }
        } label: {
            HStack(spacing: ScopeTheme.Spacing.xs) {
                Image(systemName: icon)
                    .font(ScopeTheme.Font.footnoteMedium)
                    .foregroundColor(accentColor)
                    .frame(width: ScopeTheme.Spacing.lg)

                Text(title)
                    .font(ScopeTheme.Font.footnoteSemibold)
                    .foregroundColor(.primary)

                if count > 0 {
                    Text("\(count)")
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, ScopeTheme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(accentColor.opacity(0.7)))
                }

                Spacer()

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(ScopeTheme.Font.tag)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, ScopeTheme.Spacing.xl)
            .padding(.vertical, ScopeTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionEmpty(_ message: String) -> some View {
        Text(message)
            .font(ScopeTheme.Font.footnote)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, ScopeTheme.Spacing.xl)
            .padding(.vertical, ScopeTheme.Spacing.sm)
    }

    // MARK: - File Row

    private func fileRow(_ file: GitFileChange, isStaged: Bool) -> some View {
        VStack(spacing: 0) {
        fileRowContent(file, isStaged: isStaged)
            .onTapGesture {
                if gitService.selectedFileDiff?.file.id == file.id {
                    gitService.clearDiff()
                } else {
                    gitService.loadDiff(for: file)
                }
            }

        // Inline diff panel
        if gitService.selectedFileDiff?.file.id == file.id,
           let diffData = gitService.selectedFileDiff {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(diffData.file.path)
                        .font(ScopeTheme.Font.mono)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        gitService.clearDiff()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, ScopeTheme.Spacing.sm)
                .padding(.vertical, ScopeTheme.Spacing.xxs)
                .background(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.badge))

                if diffData.lines.isEmpty {
                    Text("No changes to display")
                        .font(ScopeTheme.Font.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(ScopeTheme.Spacing.sm)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diffData.lines.enumerated()), id: \.offset) { _, line in
                                diffLineView(line)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
            }
            .background(ScopeTheme.Colors.controlBg)
            .clipShape(RoundedRectangle(cornerRadius: ScopeTheme.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
            )
            .padding(.top, ScopeTheme.Spacing.xxs)
        }
        }
    }

    private func diffLineView(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // Old line number
            Text(line.oldLineNumber.map { "\($0)" } ?? "")
                .font(ScopeTheme.Font.tag)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, ScopeTheme.Spacing.xxxs)

            // New line number
            Text(line.newLineNumber.map { "\($0)" } ?? "")
                .font(ScopeTheme.Font.tag)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, ScopeTheme.Spacing.xxs)

            // Prefix
            Text(line.prefix)
                .font(ScopeTheme.Font.mono)
                .foregroundColor(line.prefixColor)
                .frame(width: 14, alignment: .center)

            // Content
            Text(line.text)
                .font(ScopeTheme.Font.mono)
                .foregroundColor(line.textColor)
                .textSelection(.enabled)
        }
        .padding(.horizontal, ScopeTheme.Spacing.xxs)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.backgroundColor)
    }

    private func fileRowContent(_ file: GitFileChange, isStaged: Bool) -> some View {
        HStack(spacing: ScopeTheme.Spacing.sm) {
            // Status icon
            Image(systemName: file.status.icon)
                .font(ScopeTheme.Font.bodyMedium)
                .foregroundColor(file.status.color)
                .frame(width: ScopeTheme.Spacing.xl)

            // File name and directory
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName(from: file.path))
                    .font(ScopeTheme.Font.footnoteSemibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                let dir = directoryPath(from: file.path)
                if !dir.isEmpty {
                    Text(dir)
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Status badge
            Text(file.status.label)
                .font(ScopeTheme.Font.tag)
                .foregroundColor(file.status.color)
                .padding(.horizontal, ScopeTheme.Spacing.xs)
                .padding(.vertical, ScopeTheme.Spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                        .fill(file.status.color.opacity(ScopeTheme.Opacity.selection))
                )

            // Stage/Unstage button
            if isStaged {
                Button {
                    gitService.unstageFile(file)
                } label: {
                    Image(systemName: "minus")
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.white)
                        .frame(width: ScopeTheme.Spacing.xl, height: ScopeTheme.Spacing.xl)
                        .background(
                            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                                .fill(Color.white.opacity(ScopeTheme.Opacity.selection))
                        )
                }
                .buttonStyle(.plain)
                .help("Unstage")
            } else {
                Button {
                    gitService.stageFile(file)
                } label: {
                    Image(systemName: "plus")
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.green)
                        .frame(width: ScopeTheme.Spacing.xl, height: ScopeTheme.Spacing.xl)
                        .background(
                            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                                .fill(Color.green.opacity(ScopeTheme.Opacity.selection))
                        )
                }
                .buttonStyle(.plain)
                .help("Stage")
            }
        }
        .padding(ScopeTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                .fill(ScopeTheme.Colors.controlBg.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
        )
    }

    // MARK: - Commit Row

    private func commitRow(_ entry: GitLogEntry) -> some View {
        HStack(spacing: ScopeTheme.Spacing.sm) {
            Text(entry.sha)
                .font(ScopeTheme.Font.mono)
                .foregroundColor(.accentColor)
                .frame(width: 60, alignment: .leading)

            Text(entry.message)
                .font(ScopeTheme.Font.footnote)
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            Text(entry.relativeDate)
                .font(ScopeTheme.Font.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, ScopeTheme.Spacing.md)
        .padding(.vertical, ScopeTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                .fill(ScopeTheme.Colors.controlBg.opacity(0.5))
        )
    }

    // MARK: - Helpers

    private func scanProject() {
        guard let project = appState.currentProject else { return }
        gitService.scan(projectPath: project.path)
    }

    private func performCommit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        isCommitting = true
        Task {
            let success = await gitService.commit(message: message)
            isCommitting = false
            if success {
                commitMessage = ""
            }
        }
    }

    private func fileName(from path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func directoryPath(from path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - GitHub: PR Row

    private func prRow(_ pr: GitHubPR) -> some View {
        Button {
            if let repo = githubService.repo {
                let urlString = "https://github.com/\(repo.owner)/\(repo.name)/pull/\(pr.number)"
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                HStack(spacing: ScopeTheme.Spacing.xs) {
                    Text("#\(pr.number)")
                        .font(ScopeTheme.Font.mono)
                        .foregroundColor(.accentColor)

                    Text(pr.title)
                        .font(ScopeTheme.Font.footnoteMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    checksIcon(pr.checksStatus)
                    reviewIcon(pr.reviewDecision)
                }

                HStack(spacing: ScopeTheme.Spacing.sm) {
                    Text(pr.author.login)
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(pr.headRefName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(.secondary)

                    if pr.isDraft {
                        Text("Draft")
                            .font(ScopeTheme.Font.tag)
                            .foregroundColor(.white)
                            .padding(.horizontal, ScopeTheme.Spacing.xxs)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.15)))
                    }

                    Spacer()

                    HStack(spacing: ScopeTheme.Spacing.xxs) {
                        Text("+\(pr.additions)")
                            .font(ScopeTheme.Font.caption)
                            .foregroundColor(.green)
                        Text("-\(pr.deletions)")
                            .font(ScopeTheme.Font.caption)
                            .foregroundColor(.red)
                    }

                    Text(relativeTime(pr.updatedAt))
                        .font(ScopeTheme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(ScopeTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .fill(ScopeTheme.Colors.controlBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - GitHub: Workflow Row

    private func workflowRow(_ workflow: GitHubWorkflow) -> some View {
        Button {
            if let url = URL(string: workflow.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: ScopeTheme.Spacing.sm) {
                workflowStatusIcon(status: workflow.status, conclusion: workflow.conclusion)

                VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxxs) {
                    Text(workflow.name)
                        .font(ScopeTheme.Font.footnoteMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: ScopeTheme.Spacing.xs) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(workflow.headBranch)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.secondary)

                        Text(workflow.event)
                            .font(ScopeTheme.Font.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(relativeTime(workflow.createdAt))
                    .font(ScopeTheme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(ScopeTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .fill(ScopeTheme.Colors.controlBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - GitHub: Issue Row

    private func issueRow(_ issue: GitHubIssue) -> some View {
        Button {
            if let repo = githubService.repo {
                let urlString = "https://github.com/\(repo.owner)/\(repo.name)/issues/\(issue.number)"
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                HStack(spacing: ScopeTheme.Spacing.xs) {
                    Text("#\(issue.number)")
                        .font(ScopeTheme.Font.mono)
                        .foregroundColor(.accentColor)

                    Text(issue.title)
                        .font(ScopeTheme.Font.footnoteMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Text(relativeTime(issue.updatedAt))
                        .font(ScopeTheme.Font.caption)
                        .foregroundStyle(.tertiary)
                }

                if !issue.labels.isEmpty {
                    HStack(spacing: ScopeTheme.Spacing.xxs) {
                        ForEach(issue.labels, id: \.name) { label in
                            Text(label.name)
                                .font(ScopeTheme.Font.tag)
                                .foregroundColor(.white)
                                .padding(.horizontal, ScopeTheme.Spacing.xs)
                                .padding(.vertical, ScopeTheme.Spacing.xxxs)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(hex: label.color) ?? Color.secondary)
                                )
                        }
                    }
                }
            }
            .padding(ScopeTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .fill(ScopeTheme.Colors.controlBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                    .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - GitHub: Status Icons

    @ViewBuilder
    private func checksIcon(_ status: GitHubPR.ChecksStatus) -> some View {
        switch status {
        case .passing:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
        case .failing:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        case .pending:
            Image(systemName: "clock.fill")
                .font(.system(size: 12))
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func reviewIcon(_ decision: String?) -> some View {
        switch decision {
        case "APPROVED":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
        case "CHANGES_REQUESTED":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        case "REVIEW_REQUIRED":
            Image(systemName: "clock.fill")
                .font(.system(size: 12))
                .foregroundColor(.white)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func workflowStatusIcon(status: String, conclusion: String?) -> some View {
        switch conclusion ?? status {
        case "success":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
        case "failure":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
        case "cancelled", "skipped":
            Image(systemName: "slash.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        case "in_progress", "queued", "requested", "waiting", "pending":
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14))
                .foregroundColor(.white)
        default:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }
}
