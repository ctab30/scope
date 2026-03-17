import SwiftUI
import AppKit
import GRDB

struct GitChangesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var githubService: GitHubService
    @StateObject private var gitService = GitChangesService()

    @State private var commitMessage: String = ""
    @State private var collapsedSections: Set<String> = []
    @State private var isCommitting = false
    @State private var isPushing = false
    @State private var isPulling = false
    @State private var pushError: String?
    @State private var pullError: String?
    @State private var commitsAhead: Int = 0
    @State private var commitsBehind: Int = 0
    @State private var hasUpstream: Bool = true
    @State private var showPushConfirm = false
    @State private var showPullConfirm = false
    @State private var showNewBranch = false
    @State private var newBranchName = ""
    @State private var isCreatingBranch = false
    @State private var branchError: String?
    @State private var uiCommandTimer: Timer?
    @State private var isGeneratingMessage = false

    var body: some View {
        Group {
            if !gitService.isGitRepo && !gitService.isLoading {
                emptyState
            } else {
                changesContent
            }
        }
        .onAppear {
            scanProject()
            startUICommandPolling()
        }
        .onDisappear {
            stopUICommandPolling()
        }
        .onChange(of: appState.currentProject?.id) { scanProject() }
        .alert("Push to Remote", isPresented: $showPushConfirm) {
            Button("Push") { performPush() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hasUpstream
                ? "Push \(commitsAhead) commit\(commitsAhead == 1 ? "" : "s") to \(gitService.currentBranch)?"
                : "Push and set upstream for \(gitService.currentBranch)?")
        }
        .alert("Pull from Remote", isPresented: $showPullConfirm) {
            Button("Pull") { performPull() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(commitsBehind > 0
                ? "Pull \(commitsBehind) commit\(commitsBehind == 1 ? "" : "s") from \(gitService.currentBranch)?"
                : "Pull latest changes from \(gitService.currentBranch)?")
        }
        .alert("New Branch", isPresented: $showNewBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Create") { performCreateBranch() }
                .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingBranch)
            Button("Cancel", role: .cancel) { newBranchName = "" }
        } message: {
            Text("Create a new branch from \(gitService.currentBranch)")
        }
        .alert("Branch Error", isPresented: .init(
            get: { branchError != nil },
            set: { if !$0 { branchError = nil } }
        )) {
            Button("OK") { branchError = nil }
        } message: {
            Text(branchError ?? "")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: WorkspaceTheme.Spacing.md) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("Not a Git Repository")
                .font(WorkspaceTheme.Font.headline)
                .foregroundColor(.secondary)

            Text("This project is not tracked by Git. Initialize a repository to see changes here.")
                .font(WorkspaceTheme.Font.footnote)
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
                    .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                    .padding(.vertical, WorkspaceTheme.Spacing.md)

                Divider()

                // Commit Composer
                commitComposer
                    .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                    .padding(.vertical, WorkspaceTheme.Spacing.md)

                if let error = pushError {
                    HStack(spacing: WorkspaceTheme.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(WorkspaceTheme.Font.caption)
                            .foregroundColor(.yellow)
                        Text(error)
                            .font(WorkspaceTheme.Font.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            pushError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                    .padding(.bottom, WorkspaceTheme.Spacing.sm)
                }

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
                        LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
                            ForEach(gitService.stagedFiles) { file in
                                fileRow(file, isStaged: true)
                            }
                        }
                        .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                        .padding(.bottom, WorkspaceTheme.Spacing.sm)
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
                        LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
                            ForEach(gitService.unstagedFiles) { file in
                                fileRow(file, isStaged: false)
                            }
                        }
                        .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                        .padding(.bottom, WorkspaceTheme.Spacing.sm)
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
                        LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
                            ForEach(gitService.untrackedFiles) { file in
                                fileRow(file, isStaged: false)
                            }
                        }
                        .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                        .padding(.bottom, WorkspaceTheme.Spacing.sm)
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
                        LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
                            ForEach(gitService.recentCommits) { entry in
                                commitRow(entry)
                            }
                        }
                        .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                        .padding(.bottom, WorkspaceTheme.Spacing.sm)
                    }
                }

                // MARK: - GitHub Sections
                if githubService.isAvailable {
                    Divider()

                    // GitHub header
                    HStack(spacing: WorkspaceTheme.Spacing.xs) {
                        Image(systemName: "link")
                            .font(WorkspaceTheme.Font.caption)
                            .foregroundStyle(.tertiary)
                        if let repo = githubService.repo {
                            Text("\(repo.owner)/\(repo.name)")
                                .font(WorkspaceTheme.Font.footnoteMedium)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if githubService.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal, WorkspaceTheme.Spacing.xl)
                    .padding(.vertical, WorkspaceTheme.Spacing.sm)

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
                            LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
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
                            LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
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
                            LazyVStack(spacing: WorkspaceTheme.Spacing.xxs) {
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
            .padding(.bottom, WorkspaceTheme.Spacing.xl)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: WorkspaceTheme.Spacing.sm) {
            Image(systemName: "arrow.triangle.branch")
                .font(WorkspaceTheme.Font.footnoteMedium)
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

                Divider()

                Button {
                    newBranchName = ""
                    showNewBranch = true
                } label: {
                    Label("New Branch...", systemImage: "plus")
                }
            } label: {
                HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                    Text(gitService.currentBranch)
                        .font(WorkspaceTheme.Font.mono)
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

            Spacer()

            if gitService.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }

            Button {
                Task { await refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(WorkspaceTheme.Font.footnoteMedium)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    // MARK: - Commit Composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.sm) {
            HStack {
                Text("Commit Message")
                    .font(WorkspaceTheme.Font.footnoteSemibold)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    generateCommitMessage()
                } label: {
                    HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                        if isGeneratingMessage {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10))
                        }
                        Text("Generate")
                            .font(WorkspaceTheme.Font.caption)
                    }
                    .foregroundColor(gitService.stagedFiles.isEmpty ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(gitService.stagedFiles.isEmpty || isGeneratingMessage)
                .help("Generate commit message with AI")
            }

            TextEditor(text: $commitMessage)
                .font(WorkspaceTheme.Font.mono)
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .padding(WorkspaceTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                        .fill(WorkspaceTheme.Colors.controlBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                        .stroke(WorkspaceTheme.Colors.separator.opacity(0.5), lineWidth: 0.5)
                )

            HStack(spacing: WorkspaceTheme.Spacing.sm) {
                Button {
                    gitService.stageAll()
                } label: {
                    Text("Stage All")
                        .font(WorkspaceTheme.Font.footnoteMedium)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, WorkspaceTheme.Spacing.md)
                .padding(.vertical, WorkspaceTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                        .fill(Color.green.opacity(WorkspaceTheme.Opacity.selection))
                )
                .foregroundColor(.green)

                Button {
                    gitService.unstageAll()
                } label: {
                    Text("Unstage All")
                        .font(WorkspaceTheme.Font.footnoteMedium)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, WorkspaceTheme.Spacing.md)
                .padding(.vertical, WorkspaceTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                        .fill(Color.white.opacity(WorkspaceTheme.Opacity.selection))
                )
                .foregroundColor(.white)

                Spacer()

                commitButton

                pullButton

                pushButton
            }
        }
    }

    private var canCommit: Bool {
        !gitService.stagedFiles.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Commit & Push Buttons

    private var commitButton: some View {
        Button {
            performCommit()
        } label: {
            HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                if isCommitting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                }
                Text("Commit")
                    .font(WorkspaceTheme.Font.footnoteSemibold)
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.md)
            .padding(.vertical, WorkspaceTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(canCommit ? Color.accentColor : Color.secondary.opacity(WorkspaceTheme.Opacity.border))
            )
            .foregroundColor(canCommit ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canCommit || isCommitting)
    }

    private var pushButton: some View {
        Button {
            confirmAndPush()
        } label: {
            HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                if isPushing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.up")
                        .font(WorkspaceTheme.Font.footnoteMedium)
                }
                Text("Push")
                    .font(WorkspaceTheme.Font.footnoteSemibold)
                if commitsAhead > 0 {
                    Text("\(commitsAhead)")
                        .font(WorkspaceTheme.Font.caption)
                }
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.md)
            .padding(.vertical, WorkspaceTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(commitsAhead > 0 ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.2))
            )
            .foregroundColor(commitsAhead > 0 ? .white : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .disabled(isPushing)
        .help(hasUpstream ? "Push to remote" : "Push and set upstream")
    }

    private var pullButton: some View {
        Button {
            showPullConfirm = true
        } label: {
            HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                if isPulling {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.down")
                        .font(WorkspaceTheme.Font.footnoteMedium)
                }
                Text("Pull")
                    .font(WorkspaceTheme.Font.footnoteSemibold)
                if commitsBehind > 0 {
                    Text("\(commitsBehind)")
                        .font(WorkspaceTheme.Font.caption)
                }
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.md)
            .padding(.vertical, WorkspaceTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(commitsBehind > 0 ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.2))
            )
            .foregroundColor(commitsBehind > 0 ? .white : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .disabled(isPulling || !hasUpstream)
        .help("Pull from remote")
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
            HStack(spacing: WorkspaceTheme.Spacing.xs) {
                Image(systemName: icon)
                    .font(WorkspaceTheme.Font.footnoteMedium)
                    .foregroundColor(accentColor)
                    .frame(width: WorkspaceTheme.Spacing.lg)

                Text(title)
                    .font(WorkspaceTheme.Font.footnoteSemibold)
                    .foregroundColor(.primary)

                if count > 0 {
                    Text("\(count)")
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, WorkspaceTheme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(accentColor.opacity(0.7)))
                }

                Spacer()

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(WorkspaceTheme.Font.tag)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.xl)
            .padding(.vertical, WorkspaceTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionEmpty(_ message: String) -> some View {
        Text(message)
            .font(WorkspaceTheme.Font.footnote)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, WorkspaceTheme.Spacing.xl)
            .padding(.vertical, WorkspaceTheme.Spacing.sm)
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
                        .font(WorkspaceTheme.Font.mono)
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
                .padding(.horizontal, WorkspaceTheme.Spacing.sm)
                .padding(.vertical, WorkspaceTheme.Spacing.xxs)
                .background(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.badge))

                if diffData.lines.isEmpty {
                    Text("No changes to display")
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(WorkspaceTheme.Spacing.sm)
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
            .background(WorkspaceTheme.Colors.controlBg)
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.subtleBorder), lineWidth: 0.5)
            )
            .padding(.top, WorkspaceTheme.Spacing.xxs)
        }
        }
    }

    private func diffLineView(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // Old line number
            Text(line.oldLineNumber.map { "\($0)" } ?? "")
                .font(WorkspaceTheme.Font.tag)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, WorkspaceTheme.Spacing.xxxs)

            // New line number
            Text(line.newLineNumber.map { "\($0)" } ?? "")
                .font(WorkspaceTheme.Font.tag)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, WorkspaceTheme.Spacing.xxs)

            // Prefix
            Text(line.prefix)
                .font(WorkspaceTheme.Font.mono)
                .foregroundColor(line.prefixColor)
                .frame(width: 14, alignment: .center)

            // Content
            Text(line.text)
                .font(WorkspaceTheme.Font.mono)
                .foregroundColor(line.textColor)
                .textSelection(.enabled)
        }
        .padding(.horizontal, WorkspaceTheme.Spacing.xxs)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.backgroundColor)
    }

    private func fileRowContent(_ file: GitFileChange, isStaged: Bool) -> some View {
        HStack(spacing: WorkspaceTheme.Spacing.sm) {
            // Status icon
            Image(systemName: file.status.icon)
                .font(WorkspaceTheme.Font.bodyMedium)
                .foregroundColor(file.status.color)
                .frame(width: WorkspaceTheme.Spacing.xl)

            // File name and directory
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName(from: file.path))
                    .font(WorkspaceTheme.Font.footnoteSemibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                let dir = directoryPath(from: file.path)
                if !dir.isEmpty {
                    Text(dir)
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Status badge
            Text(file.status.label)
                .font(WorkspaceTheme.Font.tag)
                .foregroundColor(file.status.color)
                .padding(.horizontal, WorkspaceTheme.Spacing.xs)
                .padding(.vertical, WorkspaceTheme.Spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                        .fill(file.status.color.opacity(WorkspaceTheme.Opacity.selection))
                )

            // Stage/Unstage button
            if isStaged {
                Button {
                    gitService.unstageFile(file)
                } label: {
                    Image(systemName: "minus")
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.white)
                        .frame(width: WorkspaceTheme.Spacing.xl, height: WorkspaceTheme.Spacing.xl)
                        .background(
                            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                                .fill(Color.white.opacity(WorkspaceTheme.Opacity.selection))
                        )
                }
                .buttonStyle(.plain)
                .help("Unstage")
            } else {
                Button {
                    gitService.stageFile(file)
                } label: {
                    Image(systemName: "plus")
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.green)
                        .frame(width: WorkspaceTheme.Spacing.xl, height: WorkspaceTheme.Spacing.xl)
                        .background(
                            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                                .fill(Color.green.opacity(WorkspaceTheme.Opacity.selection))
                        )
                }
                .buttonStyle(.plain)
                .help("Stage")
            }
        }
        .padding(WorkspaceTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                .fill(WorkspaceTheme.Colors.controlBg.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.subtleBorder), lineWidth: 0.5)
        )
    }

    // MARK: - Commit Row

    private func commitRow(_ entry: GitLogEntry) -> some View {
        HStack(spacing: WorkspaceTheme.Spacing.sm) {
            Text(entry.sha)
                .font(WorkspaceTheme.Font.mono)
                .foregroundColor(.accentColor)
                .frame(width: 60, alignment: .leading)

            Text(entry.message)
                .font(WorkspaceTheme.Font.footnote)
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            Text(entry.relativeDate)
                .font(WorkspaceTheme.Font.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, WorkspaceTheme.Spacing.md)
        .padding(.vertical, WorkspaceTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                .fill(WorkspaceTheme.Colors.controlBg.opacity(0.5))
        )
    }

    // MARK: - Helpers

    private func scanProject() {
        guard let project = appState.currentProject else { return }
        gitService.scan(projectPath: project.path)
        refreshAheadCount()
    }

    private func refreshAll() async {
        await gitService.refresh()
        refreshAheadCount()
    }

    private func refreshAheadCount() {
        guard let path = appState.currentProject?.path else { return }
        let branch = gitService.currentBranch
        Task.detached {
            let upstream = GitChangesService.hasUpstream(at: path, branch: branch)
            let ahead = upstream ? GitChangesService.commitsAhead(at: path) : 0
            let behind = upstream ? GitChangesService.commitsBehind(at: path) : 0
            await MainActor.run {
                self.hasUpstream = upstream
                self.commitsAhead = ahead
                self.commitsBehind = behind
            }
        }
    }

    private func confirmAndPush() {
        showPushConfirm = true
    }

    private func performPush() {
        isPushing = true
        pushError = nil
        Task {
            let result = await gitService.push(setUpstream: !hasUpstream)
            isPushing = false
            if result.success {
                refreshAheadCount()
            } else {
                pushError = result.message
            }
        }
    }

    private func performPull() {
        isPulling = true
        pullError = nil
        Task {
            let result = await gitService.pull()
            isPulling = false
            if result.success {
                refreshAheadCount()
            } else {
                pullError = result.message
            }
        }
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
                refreshAheadCount()
            }
        }
    }

    private func performCreateBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreatingBranch = true
        Task {
            let success = await gitService.createBranch(name: name)
            isCreatingBranch = false
            if success {
                newBranchName = ""
                refreshAheadCount()
            } else {
                branchError = "Failed to create branch '\(name)'. Check the name is valid and doesn't already exist."
            }
        }
    }

    // MARK: - UI Command Polling (MCP → GUI IPC)

    private func startUICommandPolling() {
        uiCommandTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] _ in
            Task { @MainActor in
                self.pollUICommands()
            }
        }
    }

    private func stopUICommandPolling() {
        uiCommandTimer?.invalidate()
        uiCommandTimer = nil
    }

    private func pollUICommands() {
        guard let dbQueue = DatabaseService.shared.dbQueue,
              let projectId = appState.currentProject?.id else { return }

        struct UICommand: Codable, FetchableRecord, MutablePersistableRecord {
            var id: Int64?
            var command: String
            var args: String?
            var projectId: String?
            var status: String
            static let databaseTableName = "uiCommands"
        }

        do {
            let commands: [UICommand] = try dbQueue.read { db in
                try UICommand
                    .filter(Column("status") == "pending")
                    .filter(Column("projectId") == projectId)
                    .filter(Column("command") == "set_commit_message")
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }

            for cmd in commands {
                if let argsStr = cmd.args,
                   let argsData = argsStr.data(using: .utf8),
                   let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
                   let message = argsDict["message"] as? String {
                    commitMessage = message
                    isGeneratingMessage = false
                }

                // Mark as completed
                try dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE uiCommands SET status = 'completed', completedAt = ? WHERE id = ?",
                        arguments: [Date(), cmd.id]
                    )
                }
            }
        } catch {
            // Silently ignore — table may not exist yet
        }
    }

    // MARK: - AI Commit Message Generation

    private func generateCommitMessage() {
        guard let path = appState.currentProject?.path else { return }
        isGeneratingMessage = true

        let prompt = "Use the workspace MCP: call git_diff with staged=true and path=\\\"\(path)\\\", then call set_commit_message with a concise commit message (under 72 chars first line, body only if needed). You MUST use set_commit_message, do not just print the message."

        let command = "claude --dangerously-skip-permissions \"\(prompt)\""

        NotificationCenter.default.post(
            name: .launchTask,
            object: nil,
            userInfo: [
                LaunchTaskKey.title: "Commit Message",
                LaunchTaskKey.command: command,
                LaunchTaskKey.projectId: appState.currentProject?.id ?? "",
            ]
        )
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
            VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                HStack(spacing: WorkspaceTheme.Spacing.xs) {
                    Text("#\(pr.number)")
                        .font(WorkspaceTheme.Font.mono)
                        .foregroundColor(.accentColor)

                    Text(pr.title)
                        .font(WorkspaceTheme.Font.footnoteMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    checksIcon(pr.checksStatus)
                    reviewIcon(pr.reviewDecision)
                }

                HStack(spacing: WorkspaceTheme.Spacing.sm) {
                    Text(pr.author.login)
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(pr.headRefName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundColor(.secondary)

                    if pr.isDraft {
                        Text("Draft")
                            .font(WorkspaceTheme.Font.tag)
                            .foregroundColor(.white)
                            .padding(.horizontal, WorkspaceTheme.Spacing.xxs)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.15)))
                    }

                    Spacer()

                    HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                        Text("+\(pr.additions)")
                            .font(WorkspaceTheme.Font.caption)
                            .foregroundColor(.green)
                        Text("-\(pr.deletions)")
                            .font(WorkspaceTheme.Font.caption)
                            .foregroundColor(.red)
                    }

                    Text(relativeTime(pr.updatedAt))
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(WorkspaceTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(WorkspaceTheme.Colors.controlBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.subtleBorder), lineWidth: 0.5)
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
            HStack(spacing: WorkspaceTheme.Spacing.sm) {
                workflowStatusIcon(status: workflow.status, conclusion: workflow.conclusion)

                VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xxxs) {
                    Text(workflow.name)
                        .font(WorkspaceTheme.Font.footnoteMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: WorkspaceTheme.Spacing.xs) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(workflow.headBranch)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.secondary)

                        Text(workflow.event)
                            .font(WorkspaceTheme.Font.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(relativeTime(workflow.createdAt))
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(WorkspaceTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(WorkspaceTheme.Colors.controlBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.subtleBorder), lineWidth: 0.5)
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
            VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                HStack(spacing: WorkspaceTheme.Spacing.xs) {
                    Text("#\(issue.number)")
                        .font(WorkspaceTheme.Font.mono)
                        .foregroundColor(.accentColor)

                    Text(issue.title)
                        .font(WorkspaceTheme.Font.footnoteMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Text(relativeTime(issue.updatedAt))
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundStyle(.tertiary)
                }

                if !issue.labels.isEmpty {
                    HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                        ForEach(issue.labels, id: \.name) { label in
                            Text(label.name)
                                .font(WorkspaceTheme.Font.tag)
                                .foregroundColor(.white)
                                .padding(.horizontal, WorkspaceTheme.Spacing.xs)
                                .padding(.vertical, WorkspaceTheme.Spacing.xxxs)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(hex: label.color) ?? Color.secondary)
                                )
                        }
                    }
                }
            }
            .padding(WorkspaceTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .fill(WorkspaceTheme.Colors.controlBg.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small)
                    .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.subtleBorder), lineWidth: 0.5)
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
