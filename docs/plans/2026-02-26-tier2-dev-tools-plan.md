# Tier 2 Dev Tools Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add three Tier 2 features — Git Changes Overview, Network Inspector, and Environment Builder — to the Context app.

**Architecture:** Git Changes Overview is a new GUITab with a full working-tree status UI driven by `git` CLI commands (same pattern as `DiffViewerView.swift`). Network Inspector extends the existing DevTools panel with a new tab that intercepts `fetch()`/`XMLHttpRequest` via JS injection (same pattern as console log capture). Environment Builder extends the existing Services tab with .env template editing and environment switching.

**Tech Stack:** SwiftUI, AppKit bridging, `Process()` for git CLI, `WKUserScript`/`WKScriptMessageHandler` for JS injection, `FileManager` for .env file I/O.

---

## Feature 1: Git Changes Overview

### Task 1: Create GitChangesService

**Files:**
- Create: `Context/Sources/Context/Services/GitChangesService.swift`

**Context:** This service runs `git status --porcelain`, `git diff --stat`, and `git log --oneline -10` via `Process()`. Follow the same pattern as `DiffViewerView.swift:85-108` (Process with `/usr/bin/git`, pipe for stdout, `FileHandle.nullDevice` for stderr). Must be `@MainActor class: ObservableObject` like `GitHubService.swift`.

**Step 1: Create the service with data models**

```swift
import Foundation
import SwiftUI

// MARK: - Models

struct GitFileChange: Identifiable {
    let id = UUID()
    let path: String
    let status: GitFileStatus
    let isStaged: Bool
}

enum GitFileStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case copied = "C"

    var icon: String {
        switch self {
        case .modified: return "pencil.circle.fill"
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        case .copied: return "doc.on.doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .secondary
        case .copied: return .purple
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .copied: return "Copied"
        }
    }
}

struct GitLogEntry: Identifiable {
    let id = UUID()
    let sha: String
    let message: String
    let author: String
    let relativeDate: String
}

// MARK: - Service

@MainActor
class GitChangesService: ObservableObject {
    @Published var stagedFiles: [GitFileChange] = []
    @Published var unstagedFiles: [GitFileChange] = []
    @Published var untrackedFiles: [GitFileChange] = []
    @Published var recentCommits: [GitLogEntry] = []
    @Published var currentBranch: String = ""
    @Published var isLoading = false
    @Published var isGitRepo = false

    private var projectPath: String?

    func scan(projectPath: String) {
        self.projectPath = projectPath
        Task { await refresh() }
    }

    func refresh() async {
        guard let path = projectPath else { return }
        isLoading = true

        let (staged, unstaged, untracked) = await Task.detached {
            Self.parseGitStatus(at: path)
        }.value

        let commits = await Task.detached {
            Self.parseGitLog(at: path)
        }.value

        let branch = await Task.detached {
            Self.getCurrentBranch(at: path)
        }.value

        self.stagedFiles = staged
        self.unstagedFiles = unstaged
        self.untrackedFiles = untracked
        self.recentCommits = commits
        self.currentBranch = branch
        self.isGitRepo = !branch.isEmpty
        self.isLoading = false
    }

    // MARK: - Stage / Unstage

    func stageFile(_ path: String) {
        guard let projectPath else { return }
        Task.detached {
            Self.runGit(["add", "--", path], at: projectPath)
        }
        Task { await refresh() }
    }

    func unstageFile(_ path: String) {
        guard let projectPath else { return }
        Task.detached {
            Self.runGit(["restore", "--staged", "--", path], at: projectPath)
        }
        Task { await refresh() }
    }

    func stageAll() {
        guard let projectPath else { return }
        Task.detached {
            Self.runGit(["add", "-A"], at: projectPath)
        }
        Task { await refresh() }
    }

    func unstageAll() {
        guard let projectPath else { return }
        Task.detached {
            Self.runGit(["reset", "HEAD"], at: projectPath)
        }
        Task { await refresh() }
    }

    // MARK: - Commit

    func commit(message: String) async -> Bool {
        guard let projectPath, !message.isEmpty else { return false }
        let result = await Task.detached {
            Self.runGit(["commit", "-m", message], at: projectPath)
        }.value
        await refresh()
        return result != nil
    }

    // MARK: - Git Commands

    nonisolated static func parseGitStatus(at path: String) -> (staged: [GitFileChange], unstaged: [GitFileChange], untracked: [GitFileChange]) {
        guard let output = runGit(["status", "--porcelain"], at: path) else {
            return ([], [], [])
        }

        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []
        var untracked: [GitFileChange] = []

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }
            let indexStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            let filePath = String(line.dropFirst(3))

            if indexStatus == "?" {
                untracked.append(GitFileChange(path: filePath, status: .untracked, isStaged: false))
            } else {
                if indexStatus != " " {
                    let status = GitFileStatus(rawValue: String(indexStatus)) ?? .modified
                    staged.append(GitFileChange(path: filePath, status: status, isStaged: true))
                }
                if workTreeStatus != " " {
                    let status = GitFileStatus(rawValue: String(workTreeStatus)) ?? .modified
                    unstaged.append(GitFileChange(path: filePath, status: status, isStaged: false))
                }
            }
        }

        return (staged, unstaged, untracked)
    }

    nonisolated static func parseGitLog(at path: String) -> [GitLogEntry] {
        guard let output = runGit(["log", "--oneline", "--format=%h|%s|%an|%ar", "-15"], at: path) else {
            return []
        }

        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4 else { return nil }
            return GitLogEntry(sha: parts[0], message: parts[1], author: parts[2], relativeDate: parts[3])
        }
    }

    nonisolated static func getCurrentBranch(at path: String) -> String {
        guard let output = runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: path) else {
            return ""
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    nonisolated static func runGit(_ arguments: [String], at path: String) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/GitChangesService.swift
git commit -m "feat: add GitChangesService with status parsing, stage/unstage, and commit"
```

---

### Task 2: Create GitChangesView

**Files:**
- Create: `Context/Sources/Context/Views/Git/GitChangesView.swift`

**Context:** This is the main view for the Git tab. It has three collapsible sections (Staged, Unstaged, Untracked), a commit message composer at the top, a recent commits list at the bottom, and a branch indicator in the header. Follow the collapsible section pattern from `ProjectServicesView.swift` (lines 105-147: `sectionHeader()` with `collapsedSections: Set<String>`). Each file row shows status icon, file path, and a stage/unstage button.

**Step 1: Create the view**

```swift
import SwiftUI

struct GitChangesView: View {
    @EnvironmentObject var appState: AppState

    @StateObject private var gitService = GitChangesService()
    @State private var commitMessage = ""
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
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("Not a Git Repository")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Text("Initialize a git repository to track changes.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Changes Content

    private var changesContent: some View {
        VStack(spacing: 0) {
            // Header with branch name and refresh
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Commit composer
                    commitComposer

                    Divider()

                    // Staged files
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
                            fileList(gitService.stagedFiles, staged: true)
                        }
                    }

                    Divider()

                    // Unstaged files
                    sectionHeader(
                        title: "Changes",
                        icon: "pencil.circle.fill",
                        count: gitService.unstagedFiles.count,
                        key: "unstaged",
                        accentColor: .orange
                    )

                    if !collapsedSections.contains("unstaged") {
                        if gitService.unstagedFiles.isEmpty {
                            sectionEmpty("No unstaged changes")
                        } else {
                            fileList(gitService.unstagedFiles, staged: false)
                        }
                    }

                    Divider()

                    // Untracked files
                    sectionHeader(
                        title: "Untracked",
                        icon: "questionmark.circle.fill",
                        count: gitService.untrackedFiles.count,
                        key: "untracked",
                        accentColor: .secondary
                    )

                    if !collapsedSections.contains("untracked") {
                        if gitService.untrackedFiles.isEmpty {
                            sectionEmpty("No untracked files")
                        } else {
                            fileList(gitService.untrackedFiles, staged: false)
                        }
                    }

                    Divider()

                    // Recent commits
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
                            commitList
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)

            Text(gitService.currentBranch)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)

            Spacer()

            let totalChanges = gitService.stagedFiles.count + gitService.unstagedFiles.count + gitService.untrackedFiles.count
            if totalChanges > 0 {
                Text("\(totalChanges) changes")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if gitService.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            } else {
                Button {
                    Task { await gitService.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Commit Composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit Message")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            TextEditor(text: $commitMessage)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )

            HStack {
                if !gitService.unstagedFiles.isEmpty || !gitService.untrackedFiles.isEmpty {
                    Button("Stage All") {
                        gitService.stageAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                }

                if !gitService.stagedFiles.isEmpty {
                    Button("Unstage All") {
                        gitService.unstageAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    isCommitting = true
                    Task {
                        let _ = await gitService.commit(message: commitMessage)
                        commitMessage = ""
                        isCommitting = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isCommitting {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        }
                        Text("Commit")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(gitService.stagedFiles.isEmpty || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? Color.accentColor.opacity(0.3)
                                  : Color.accentColor)
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(gitService.stagedFiles.isEmpty || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || isCommitting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentColor)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accentColor.opacity(0.7)))
                }

                Spacer()

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionEmpty(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }

    // MARK: - File List

    @ViewBuilder
    private func fileList(_ files: [GitFileChange], staged: Bool) -> some View {
        LazyVStack(spacing: 1) {
            ForEach(files) { file in
                fileRow(file, staged: staged)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func fileRow(_ file: GitFileChange, staged: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: file.status.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(file.status.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(fileName(file.path))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(fileDirectory(file.path))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Text(file.status.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(file.status.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(file.status.color.opacity(0.12))
                )

            // Stage/Unstage button
            Button {
                if staged {
                    gitService.unstageFile(file.path)
                } else {
                    gitService.stageFile(file.path)
                }
            } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(staged ? .orange : .green)
            }
            .buttonStyle(.plain)
            .help(staged ? "Unstage" : "Stage")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Commit List

    private var commitList: some View {
        LazyVStack(spacing: 1) {
            ForEach(gitService.recentCommits) { commit in
                HStack(spacing: 8) {
                    Text(commit.sha)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .frame(width: 60, alignment: .leading)

                    Text(commit.message)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(commit.relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private func scanProject() {
        guard let project = appState.currentProject else { return }
        gitService.scan(projectPath: project.path)
    }

    private func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func fileDirectory(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "." : dir
    }
}
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Git/GitChangesView.swift
git commit -m "feat: add GitChangesView with staged/unstaged files, commit composer, and log"
```

---

### Task 3: Wire Git Tab into GUIPanelView

**Files:**
- Modify: `Context/Sources/Context/ViewModels/AppState.swift` — Add `case git` to `GUITab` enum
- Modify: `Context/Sources/Context/Views/GUIPanelView.swift` — Add `case .git: GitChangesView()` to tab content switch

**Context:** The `GUITab` enum (AppState.swift:15-43) is `CaseIterable` so the new tab auto-appears in the tab bar. The tab content routing is in `GUIPanelView.swift:152-175`.

**Step 1: Add the git tab to GUITab enum**

In `AppState.swift`, add `case git = "Git"` to the `GUITab` enum after `services`, and add `case .git: return "arrow.triangle.pull"` to the `icon` computed property.

**Step 2: Add Git tab routing in GUIPanelView**

In `GUIPanelView.swift`, add `case .git: GitChangesView()` to the switch statement (line ~170, after the `.services` case).

**Step 3: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 4: Commit**

```bash
git add Context/Sources/Context/ViewModels/AppState.swift Context/Sources/Context/Views/GUIPanelView.swift
git commit -m "feat: wire Git Changes tab into GUIPanelView tab bar"
```

---

## Feature 2: Network Inspector

### Task 4: Create NetworkRequestEntry Model

**Files:**
- Create: `Context/Sources/Context/Views/Browser/NetworkModels.swift`

**Context:** Follow the same pattern as `ConsoleLogEntry` in `BrowserTab.swift:8-31` — a simple `Identifiable` struct with computed properties for display.

**Step 1: Create the models file**

```swift
import Foundation
import SwiftUI

struct NetworkRequestEntry: Identifiable {
    let id = UUID()
    let method: String
    let url: String
    let status: Int?
    let statusText: String?
    let type: RequestType
    let startTime: Date
    var duration: TimeInterval?
    var responseSize: Int?
    var requestHeaders: [String: String]?
    var responseHeaders: [String: String]?
    var responseBody: String?
    var isComplete: Bool = false
    var isError: Bool = false

    enum RequestType: String {
        case fetch = "fetch"
        case xhr = "xhr"

        var icon: String {
            switch self {
            case .fetch: return "arrow.up.arrow.down"
            case .xhr: return "network"
            }
        }
    }

    var statusColor: Color {
        guard let status else { return .secondary }
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }

    var statusLabel: String {
        guard let status else { return isError ? "ERR" : "..." }
        if let text = statusText, !text.isEmpty {
            return "\(status) \(text)"
        }
        return "\(status)"
    }

    var formattedDuration: String {
        guard let duration else { return "..." }
        if duration < 1 {
            return "\(Int(duration * 1000))ms"
        }
        return String(format: "%.1fs", duration)
    }

    var formattedSize: String {
        guard let size = responseSize else { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    var shortURL: String {
        guard let urlObj = URL(string: url) else { return url }
        let path = urlObj.path
        if path.isEmpty || path == "/" {
            return urlObj.host ?? url
        }
        return path
    }
}
```

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Browser/NetworkModels.swift
git commit -m "feat: add NetworkRequestEntry model for network inspector"
```

---

### Task 5: Add Network Interception to BrowserTab

**Files:**
- Modify: `Context/Sources/Context/Views/Browser/BrowserTab.swift`

**Context:** BrowserTab already injects JS for console log capture and element picking. The network interceptor follows the same pattern: inject a `WKUserScript` at document start that monkey-patches `fetch()` and `XMLHttpRequest.prototype.open`/`send`. Captured requests are posted back via `window.webkit.messageHandlers.networkMonitor.postMessage()`. The message handler in `userContentController(_:didReceive:)` already branches on `message.name` (consoleLog vs devtools) — add a `networkMonitor` branch.

**Step 1: Add published properties and message handler registration**

Add to BrowserTab's published properties (after `isElementPickerActive`):
- `@Published var networkRequests: [NetworkRequestEntry] = []`
- `@Published var isNetworkMonitorActive = false`
- `private static let maxNetworkEntries = 200`

In `init()`, register a `networkMonitor` message handler (same pattern as `consoleLog` and `devtools` handlers).

**Step 2: Add the network monitoring JS injection**

Create `startNetworkMonitor()` and `stopNetworkMonitor()` methods. The JS script should:
- Store original `fetch` and `XMLHttpRequest.prototype.open`/`send`
- Wrap `fetch()` to capture method, url, status, duration, response size
- Wrap `XMLHttpRequest` open/send to capture method, url, status, duration, response size
- Generate a unique requestId per request
- Post messages to `window.webkit.messageHandlers.networkMonitor` with types: `requestStart`, `requestComplete`, `requestError`

**Step 3: Handle messages in userContentController**

In the `userContentController(_:didReceive:)` method, add a `case "networkMonitor"` branch that:
- Parses the JSON body to get type, requestId, method, url, status, duration, size, etc.
- For `requestStart`: creates a new `NetworkRequestEntry` and appends to `networkRequests`
- For `requestComplete`: finds the matching entry by requestId and updates it
- For `requestError`: finds the matching entry and marks `isError = true`
- Caps at `maxNetworkEntries` (remove oldest)

Add `deinit` cleanup for the `networkMonitor` handler, alongside the existing `devtools` cleanup.

**Step 4: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 5: Commit**

```bash
git add Context/Sources/Context/Views/Browser/BrowserTab.swift
git commit -m "feat: add network request interception via JS injection in BrowserTab"
```

---

### Task 6: Add Network Tab to DevToolsPanel

**Files:**
- Modify: `Context/Sources/Context/Views/Browser/DevToolsPanel.swift`

**Context:** `DevToolsPanel.swift` has a `DevToolsTab` enum (lines 7-19) that is `CaseIterable` with an `icon` property. The tab content is routed via a switch statement (lines 32-39). Add a `.network` case to the enum and a corresponding tab view.

**Step 1: Add network tab to DevToolsTab enum**

Add `case network = "Network"` with icon `"antenna.radiowaves.left.and.right"`.

**Step 2: Create the network tab view**

Add a `networkTab` computed property to DevToolsPanel that shows:
- A toolbar row: network monitor toggle button, clear button, filter dropdown (All/Fetch/XHR), request count badge
- A scrollable list of `NetworkRequestEntry` rows showing: status badge, method, short URL, duration, size, type icon
- Click a row to expand showing full URL, request/response headers, response body preview (truncated at 2000 chars)

**Step 3: Add the tab routing**

Add `case .network: networkTab` to the switch statement.

**Step 4: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 5: Commit**

```bash
git add Context/Sources/Context/Views/Browser/DevToolsPanel.swift
git commit -m "feat: add Network tab to DevTools panel with request list and detail view"
```

---

## Feature 3: Environment Builder

### Task 7: Add Environment Template Model

**Files:**
- Modify: `Context/Sources/Context/Services/ProjectServicesDetector.swift`

**Context:** `ProjectServicesDetector.swift` already has `EnvironmentFile` (lines 37-42) with `name`, `path`, `entries` tuple array. Add an `EnvironmentTemplate` model and template detection logic. Templates are `.env.example` or `.env.template` files.

**Step 1: Add template model and detection**

Add to `ProjectServicesDetector`:

```swift
struct EnvironmentTemplate: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let variables: [TemplateVariable]
}

struct TemplateVariable: Identifiable {
    let id = UUID()
    let key: String
    let defaultValue: String
    let comment: String?
    let isRequired: Bool
}
```

Add `static func scanTemplates(projectPath: String) -> [EnvironmentTemplate]` that:
- Looks for `.env.example`, `.env.template`, `.env.sample` files
- Parses each line: comments above a key become the variable's description
- Empty values indicate required variables
- Lines with values are defaults

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/ProjectServicesDetector.swift
git commit -m "feat: add environment template model and detection to ProjectServicesDetector"
```

---

### Task 8: Add Environment Builder UI to ProjectServicesView

**Files:**
- Modify: `Context/Sources/Context/Views/Services/ProjectServicesView.swift`

**Context:** `ProjectServicesView.swift` already has Services and Environment Variables sections. Add a third section: "Environment Builder" that shows detected templates and lets users generate `.env` files from them.

**Step 1: Add state variables**

Add to ProjectServicesView:
- `@State private var templates: [EnvironmentTemplate] = []`
- `@State private var editingTemplate: EnvironmentTemplate?`
- `@State private var editValues: [String: String] = [:]`
- `@State private var targetFileName: String = ".env"`
- `@State private var showGenerateSheet = false`

**Step 2: Add Environment Builder section**

After the Environment Variables section in `servicesContent`, add a new section with:
- Section header: "Environment Builder" with icon "hammer" and count of templates
- For each template: a card showing template name, variable count, and "Generate" button
- "Generate" button opens a sheet with:
  - Target filename picker (dropdown: `.env`, `.env.local`, `.env.development`, `.env.staging`, `.env.production`)
  - A form showing each template variable: key (label), comment (description), text field for value (pre-filled with default)
  - Required variables marked with a red asterisk
  - "Generate" button that writes the file to disk
  - Warning if target file already exists ("Will overwrite existing file")

**Step 3: Add the file generation logic**

Add a `generateEnvFile()` method that:
- Builds the `.env` file content from `editValues`
- Adds comments from the template
- Writes to `{projectPath}/{targetFileName}` via `FileManager`
- Re-scans environment files to update the viewer
- Closes the sheet

**Step 4: Add environment switching**

Add quick-switch buttons at the top of the Environment Variables section:
- Show a horizontal row of buttons for each env file (.env, .env.local, .env.development, etc.)
- Active file is highlighted
- Clicking a button copies that file's content to `.env` (with confirmation)

**Step 5: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 6: Commit**

```bash
git add Context/Sources/Context/Views/Services/ProjectServicesView.swift
git commit -m "feat: add Environment Builder with template generation and env switching"
```

---

### Task 9: Update scanProject() to load templates

**Files:**
- Modify: `Context/Sources/Context/Views/Services/ProjectServicesView.swift`

**Context:** The existing `scanProject()` method (line 303-313) calls `ProjectServicesDetector.scan()` and `ProjectServicesDetector.scanEnvironmentFiles()`. Add `ProjectServicesDetector.scanTemplates()`.

**Step 1: Update scanProject**

Add `templates = ProjectServicesDetector.scanTemplates(projectPath: project.path)` after the existing scan calls.

**Step 2: Verify it compiles**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Services/ProjectServicesView.swift
git commit -m "feat: wire template scanning into ProjectServicesView lifecycle"
```

---

## Final Verification

After all tasks are complete:

1. **Git Changes:** Build succeeds. Open a project → switch to Git tab → verify branch name shows → make a change → refresh → verify file appears in "Changes" section → click stage → verify it moves to "Staged" → type commit message → verify "Commit" button enables → commit.

2. **Network Inspector:** Build succeeds. Open browser → navigate to any page → open DevTools → switch to Network tab → toggle monitoring → refresh page → verify network requests appear with method, URL, status, duration.

3. **Environment Builder:** Build succeeds. Open a project with `.env.example` → switch to Services tab → verify "Environment Builder" section shows → click "Generate" → fill in values → generate → verify new `.env` file appears in Environment Variables section.
