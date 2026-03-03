import SwiftUI

// MARK: - Rule File Model

/// Represents one CLAUDE.md file at a specific scope level.
struct RuleFile: Identifiable, Hashable {
    let id: String          // scope key (global, project, local)
    let scope: RuleScope
    let url: URL
    let exists: Bool

    var displayName: String { scope.displayName }
}

enum RuleScope: String, CaseIterable {
    case global   = "global"
    case project  = "project"
    case local    = "local"

    var displayName: String {
        switch self {
        case .global:  return "Global"
        case .project: return "Project"
        case .local:   return "Local"
        }
    }

    var icon: String {
        switch self {
        case .global:  return "globe"
        case .project: return "folder.fill"
        case .local:   return "person.fill"
        }
    }

    var color: Color {
        switch self {
        case .global:  return .blue
        case .project: return .purple
        case .local:   return .orange
        }
    }

    var description: String {
        switch self {
        case .global:  return "~/.claude/CLAUDE.md — Applied to all projects"
        case .project: return "CLAUDE.md — Committed to repo, shared with team"
        case .local:   return ".claude/CLAUDE.md — Local only, gitignored"
        }
    }
}

// MARK: - Main View

/// Editor for Claude Code instruction files (CLAUDE.md) at three scope levels:
///
/// 1. **Global** — `~/.claude/CLAUDE.md` (all projects)
/// 2. **Project** — `<project>/CLAUDE.md` (committed to repo)
/// 3. **Local** — `<project>/.claude/CLAUDE.md` (gitignored, personal)
///
/// These files shape Claude Code's behavior, coding style, and project conventions.
struct ClaudeMdEditorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var claudeService: ClaudeService
    @EnvironmentObject var analyzer: ProjectAnalyzer
    @EnvironmentObject var devEnvironment: DevEnvironment
    @State private var ruleFiles: [RuleFile] = []
    @State private var selectedFile: RuleFile?
    @State private var editorContent: String = ""
    @State private var savedContent: String = ""
    @State private var generateError: String?

    private var hasUnsavedChanges: Bool {
        editorContent != savedContent
    }

    var body: some View {
        Group {
            if appState.currentProject == nil {
                noProjectState
            } else {
                editorLayout
            }
        }
        .onAppear { loadRuleFiles() }
        .onChange(of: appState.currentProject) { _, _ in loadRuleFiles() }
    }

    // MARK: - Layout

    private var editorLayout: some View {
        HSplitView {
            scopeListPanel
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 250)

            editorPanel
                .frame(minWidth: 300)
        }
    }

    // MARK: - Scope List (Left Panel)

    private var scopeListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Rule Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Scope list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ruleFiles) { file in
                        RuleFileRow(
                            file: file,
                            isSelected: selectedFile?.id == file.id,
                            onSelect: { selectFile(file) },
                            onCreate: { createFile(file) }
                        )
                    }
                }
                .padding(6)
            }

            Divider()

            // Precedence explanation
            VStack(alignment: .leading, spacing: 4) {
                Label("Load Order", systemImage: "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("Global \u{2192} Project \u{2192} Local")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text("Later files override earlier ones")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Editor (Right Panel)

    private var editorPanel: some View {
        VStack(spacing: 0) {
            if let file = selectedFile {
                if file.exists {
                    editorToolbar(for: file)
                    Divider()
                    TextEditor(text: $editorContent)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                } else {
                    createPrompt(for: file)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Select a rule file to edit")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func editorToolbar(for file: RuleFile) -> some View {
        HStack(spacing: 8) {
            // Scope badge
            HStack(spacing: 5) {
                Image(systemName: file.scope.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(file.scope.color)
                Text("CLAUDE.md")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))

                Text(file.scope.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(file.scope.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(file.scope.color.opacity(0.12))
                    )
            }

            Spacer()

            if hasUnsavedChanges {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.1))
                    )
            }

            // AI Generate button
            if claudeService.isGenerating {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.55)
                    Text("Generating...")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Button {
                    generateWithAI(scope: file.scope)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Generate with AI")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.purple.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }

            Button("Revert") {
                editorContent = savedContent
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(!hasUnsavedChanges)

            Button(action: saveCurrentFile) {
                HStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hasUnsavedChanges
                              ? Color.accentColor.opacity(0.15)
                              : Color(nsColor: .controlBackgroundColor))
                )
                .foregroundColor(hasUnsavedChanges ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasUnsavedChanges)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Create Prompt (for missing files)

    private func createPrompt(for file: RuleFile) -> some View {
        VStack(spacing: 16) {
            Image(systemName: file.scope.icon)
                .font(.system(size: 32))
                .foregroundColor(file.scope.color.opacity(0.5))

            Text("\(file.scope.displayName) CLAUDE.md")
                .font(.system(size: 15, weight: .semibold))

            Text(file.scope.description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(scopeExplanation(file.scope))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button(action: { createFile(file) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text("Create with Template")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(file.scope.color.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(file.scope.color.opacity(0.25), lineWidth: 0.5)
                    )
                    .foregroundColor(file.scope.color)
                }
                .buttonStyle(.plain)

                if claudeService.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Generating...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        createAndGenerate(file)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                            Text("Generate with AI")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.purple.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.purple.opacity(0.25), lineWidth: 0.5)
                        )
                        .foregroundColor(.purple)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = generateError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 10))
                }
                .foregroundColor(.orange)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scopeExplanation(_ scope: RuleScope) -> String {
        switch scope {
        case .global:
            return "Global rules apply to every project. Use this for personal preferences like coding style, communication style, or tools you always want Claude to use."
        case .project:
            return "Project rules are committed to your repository and shared with your team. Use this for project-specific conventions, architecture decisions, and coding standards."
        case .local:
            return "Local rules are gitignored and only apply to you. Use this for personal overrides, local environment details, or experimental instructions you don't want to share."
        }
    }

    // MARK: - No Project State

    private var noProjectState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No project selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Select a project to manage its Claude Code rules")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Operations

    private func loadRuleFiles() {
        guard let project = appState.currentProject else {
            ruleFiles = []
            selectedFile = nil
            return
        }

        let fm = FileManager.default

        // Global
        let globalURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/CLAUDE.md")

        // Project (in repo root)
        let projectURL = URL(fileURLWithPath: project.path)
            .appendingPathComponent("CLAUDE.md")

        // Local (in .claude/ dir within project)
        let localURL = URL(fileURLWithPath: project.path)
            .appendingPathComponent(".claude/CLAUDE.md")

        ruleFiles = [
            RuleFile(id: "global", scope: .global, url: globalURL, exists: fm.fileExists(atPath: globalURL.path)),
            RuleFile(id: "project", scope: .project, url: projectURL, exists: fm.fileExists(atPath: projectURL.path)),
            RuleFile(id: "local", scope: .local, url: localURL, exists: fm.fileExists(atPath: localURL.path)),
        ]

        // Preserve selection, or auto-select first existing file
        if let current = selectedFile, ruleFiles.contains(where: { $0.id == current.id }) {
            // Refresh the exists flag
            if let updated = ruleFiles.first(where: { $0.id == current.id }) {
                selectedFile = updated
                if updated.exists {
                    loadFileContent(updated)
                }
            }
        } else {
            if let first = ruleFiles.first(where: { $0.exists }) {
                selectFile(first)
            } else {
                selectedFile = ruleFiles.first
                editorContent = ""
                savedContent = ""
            }
        }
    }

    private func selectFile(_ file: RuleFile) {
        selectedFile = file
        if file.exists {
            loadFileContent(file)
        } else {
            editorContent = ""
            savedContent = ""
        }
    }

    private func loadFileContent(_ file: RuleFile) {
        do {
            let content = try String(contentsOf: file.url, encoding: .utf8)
            editorContent = content
            savedContent = content
        } catch {
            editorContent = ""
            savedContent = ""
            print("ClaudeMdEditor: failed to read \(file.scope.rawValue): \(error)")
        }
    }

    private func saveCurrentFile() {
        guard let file = selectedFile else { return }
        do {
            // Ensure parent directory exists
            let parentDir = file.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            try editorContent.write(to: file.url, atomically: true, encoding: .utf8)
            savedContent = editorContent
        } catch {
            print("ClaudeMdEditor: failed to save \(file.scope.rawValue): \(error)")
        }
    }

    private func createFile(_ file: RuleFile) {
        let starter = starterContent(for: file.scope)
        do {
            let parentDir = file.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try starter.write(to: file.url, atomically: true, encoding: .utf8)
            loadRuleFiles()
            if let updated = ruleFiles.first(where: { $0.id == file.id }) {
                selectFile(updated)
            }
        } catch {
            print("ClaudeMdEditor: failed to create \(file.scope.rawValue): \(error)")
        }
    }

    /// Create the file (empty) and immediately generate AI content for it.
    private func createAndGenerate(_ file: RuleFile) {
        do {
            let parentDir = file.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try "".write(to: file.url, atomically: true, encoding: .utf8)
            loadRuleFiles()
            if let updated = ruleFiles.first(where: { $0.id == file.id }) {
                selectFile(updated)
                generateWithAI(scope: file.scope)
            }
        } catch {
            print("ClaudeMdEditor: failed to create \(file.scope.rawValue): \(error)")
        }
    }

    // MARK: - AI Generation

    private func generateWithAI(scope: RuleScope) {
        guard let project = appState.currentProject else { return }
        generateError = nil

        // Build context from analyzer data
        let fileTree = analyzer.fileNodes.prefix(60).map { $0.id }

        var archSummary = ""
        let byDir = Dictionary(grouping: analyzer.archNodes, by: { $0.directory })
        for (dir, files) in byDir.sorted(by: { $0.key < $1.key }).prefix(15) {
            archSummary += "  \(dir)/: \(files.map(\.name).joined(separator: ", "))\n"
        }

        var schemaSummary = ""
        for table in analyzer.schemaTables {
            let cols = table.columns.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
            schemaSummary += "  \(table.name)(\(cols))\n"
        }

        Task {
            if let result = await claudeService.generateClaudeMd(
                projectPath: project.path,
                projectType: devEnvironment.projectType.rawValue,
                fileTree: fileTree,
                archSummary: archSummary,
                schemaSummary: schemaSummary,
                scope: scope.rawValue
            ) {
                editorContent = result
            } else {
                generateError = claudeService.lastError
            }
        }
    }

    private func starterContent(for scope: RuleScope) -> String {
        switch scope {
        case .global:
            return """
            # Global Claude Code Instructions

            ## Coding Style
            <!-- Your preferred coding conventions across all projects -->

            ## Communication
            <!-- How you want Claude to communicate (concise, detailed, etc.) -->

            ## Tool Preferences
            <!-- Tools or approaches you always want Claude to use or avoid -->
            """
        case .project:
            return """
            # Project Instructions

            ## Architecture
            <!-- Key architectural decisions and patterns -->

            ## Conventions
            <!-- Coding standards, naming conventions, file organization -->

            ## Dependencies
            <!-- Important libraries, frameworks, and how to use them -->
            """
        case .local:
            return """
            # Local Instructions

            ## Environment
            <!-- Local dev environment details, paths, API keys references -->

            ## Personal Overrides
            <!-- Your personal preferences that differ from team standards -->
            """
        }
    }
}

// MARK: - Rule File Row

struct RuleFileRow: View {
    let file: RuleFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onCreate: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Scope icon
            Image(systemName: file.scope.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(file.scope.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.scope.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Text(file.exists ? "CLAUDE.md" : "Not created")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(file.exists ? .secondary : .secondary.opacity(0.5))
            }

            Spacer()

            if file.exists {
                Circle()
                    .fill(.green.opacity(0.6))
                    .frame(width: 6, height: 6)
            } else if isHovering {
                Button(action: onCreate) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(file.scope.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : isHovering ? Color(nsColor: .separatorColor).opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in isHovering = hovering }
    }
}
