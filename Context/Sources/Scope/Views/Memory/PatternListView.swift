import SwiftUI

// MARK: - Memory File Model

struct MemoryFile: Identifiable, Hashable {
    let id: String          // filename (e.g. "MEMORY.md")
    let url: URL
    var isPrimary: Bool     // true for MEMORY.md

    var displayName: String {
        isPrimary ? "MEMORY" : url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Main View

/// Editor for Claude Code's native memory files at `~/.claude/projects/<key>/memory/`.
///
/// Files edited here are read by Claude Code automatically at session start,
/// making this a direct context engine for shaping Claude's project knowledge.
struct MemoryEditorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var contextEngine: ContextEngine
    @State private var files: [MemoryFile] = []
    @State private var selectedFile: MemoryFile?
    @State private var editorContent: String = ""
    @State private var savedContent: String = ""
    @State private var showingNewFile = false
    @State private var showingDeleteConfirm = false
    @State private var fileToDelete: MemoryFile?

    private var hasUnsavedChanges: Bool {
        editorContent != savedContent
    }

    private var memoryDir: URL? {
        guard let claudeProject = appState.currentProject?.claudeProject else { return nil }
        return URL(fileURLWithPath: claudeProject)
            .appendingPathComponent("memory", isDirectory: true)
    }

    var body: some View {
        Group {
            if appState.currentProject == nil {
                noProjectState
            } else if files.isEmpty && selectedFile == nil {
                emptyState
            } else {
                editorLayout
            }
        }
        .onAppear { loadFiles() }
        .onChange(of: appState.currentProject) { _, _ in loadFiles() }
        .sheet(isPresented: $showingNewFile) {
            NewMemoryFileSheet(isPresented: $showingNewFile, onCreate: createFile)
        }
        .alert("Delete File", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let file = fileToDelete { deleteFile(file) }
            }
        } message: {
            if let file = fileToDelete {
                Text("Delete \"\(file.displayName).md\"? Claude Code will no longer have access to this context.")
            }
        }
    }

    // MARK: - Layouts

    private var editorLayout: some View {
        VStack(spacing: 0) {
            indexStatusCard
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            HSplitView {
                fileListPanel
                    .frame(minWidth: 140, idealWidth: 170, maxWidth: 220)

                editorPanel
                    .frame(minWidth: 300)
            }
        }
    }

    // MARK: - Index Status Card

    private var indexStatusCard: some View {
        HStack(spacing: 12) {
            // Status pill
            HStack(spacing: 5) {
                Circle()
                    .fill(indexCardStatusColor)
                    .frame(width: 8, height: 8)
                Text(indexCardStatusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(indexCardStatusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(indexCardStatusColor.opacity(0.12))
            )

            // Stats
            if contextEngine.totalChunks > 0 {
                Label("\(contextEngine.totalChunks) chunks", systemImage: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if contextEngine.totalFileCount > 0 || contextEngine.indexedFileCount > 0 {
                Label("\(contextEngine.indexedFileCount)/\(contextEngine.totalFileCount) files", systemImage: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let lastIndexed = contextEngine.lastIndexedAt {
                Label(lastIndexed.formatted(.relative(presentation: .named)), systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let error = contextEngine.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if contextEngine.isIndexing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("\(Int(contextEngine.indexProgress * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
    }

    private var indexCardStatusColor: Color {
        switch contextEngine.indexStatus {
        case "ready": return .green
        case "indexing": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    private var indexCardStatusLabel: String {
        switch contextEngine.indexStatus {
        case "ready": return "Ready"
        case "indexing": return "Indexing"
        case "error": return "Error"
        default: return "Idle"
        }
    }

    // MARK: - File List

    private var fileListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Memory Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Button(action: { showingNewFile = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("New memory file")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // File list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(files) { file in
                        MemoryFileRow(
                            file: file,
                            isSelected: selectedFile?.id == file.id,
                            onSelect: { selectFile(file) },
                            onDelete: {
                                fileToDelete = file
                                showingDeleteConfirm = true
                            }
                        )
                    }
                }
                .padding(6)
            }

            Divider()

            // Footer: context hint
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text("Auto-loaded by Claude Code")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Editor

    private var editorPanel: some View {
        VStack(spacing: 0) {
            if let file = selectedFile {
                // Toolbar
                HStack(spacing: 8) {
                    // File badge
                    HStack(spacing: 5) {
                        Image(systemName: file.isPrimary ? "star.fill" : "doc.text")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(file.isPrimary ? .orange : .secondary)
                        Text(file.id)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }

                    if file.isPrimary {
                        Text("loaded every session")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("loaded when referenced")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
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

                Divider()

                // Text editor
                TextEditor(text: $editorContent)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Select a file to edit")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Empty / No-project States

    private var noProjectState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No project selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Select a project to manage its Claude Code memory")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No memory files yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Text("Memory files give Claude Code persistent context about\nyour project — patterns, conventions, gotchas, and decisions.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button(action: createStarterMemory) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("Create MEMORY.md")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                )
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Operations

    private func loadFiles() {
        guard let dir = memoryDir else {
            files = []
            selectedFile = nil
            editorContent = ""
            savedContent = ""
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            files = []
            selectedFile = nil
            editorContent = ""
            savedContent = ""
            return
        }

        let contents = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let mdFiles = contents
            .filter { $0.pathExtension == "md" }
            .map { url -> MemoryFile in
                MemoryFile(
                    id: url.lastPathComponent,
                    url: url,
                    isPrimary: url.deletingPathExtension().lastPathComponent == "MEMORY"
                )
            }
            .sorted { lhs, rhs in
                if lhs.isPrimary { return true }
                if rhs.isPrimary { return false }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        files = mdFiles

        // Preserve selection if the file still exists, otherwise select first.
        if let current = selectedFile, mdFiles.contains(where: { $0.id == current.id }) {
            // Keep current selection
        } else {
            if let first = mdFiles.first {
                selectFile(first)
            } else {
                selectedFile = nil
                editorContent = ""
                savedContent = ""
            }
        }
    }

    private func selectFile(_ file: MemoryFile) {
        // Prompt-less discard: if switching files with unsaved changes, just keep them
        // (the user can always revert). Auto-save would be better long-term.
        selectedFile = file
        loadFileContent(file)
    }

    private func loadFileContent(_ file: MemoryFile) {
        do {
            let content = try String(contentsOf: file.url, encoding: .utf8)
            editorContent = content
            savedContent = content
        } catch {
            editorContent = ""
            savedContent = ""
            print("MemoryEditor: failed to read \(file.id): \(error)")
        }
    }

    private func saveCurrentFile() {
        guard let file = selectedFile else { return }
        do {
            try editorContent.write(to: file.url, atomically: true, encoding: .utf8)
            savedContent = editorContent
        } catch {
            print("MemoryEditor: failed to save \(file.id): \(error)")
        }
    }

    private func createFile(name: String, content: String) {
        guard let dir = memoryDir else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = name.hasSuffix(".md") ? name : "\(name).md"
        let fileURL = dir.appendingPathComponent(filename)

        guard !fm.fileExists(atPath: fileURL.path) else {
            print("MemoryEditor: file already exists: \(filename)")
            return
        }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            loadFiles()
            // Select the newly created file.
            if let newFile = files.first(where: { $0.id == filename }) {
                selectFile(newFile)
            }
        } catch {
            print("MemoryEditor: failed to create \(filename): \(error)")
        }
    }

    private func deleteFile(_ file: MemoryFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            if selectedFile?.id == file.id {
                selectedFile = nil
                editorContent = ""
                savedContent = ""
            }
            loadFiles()
        } catch {
            print("MemoryEditor: failed to delete \(file.id): \(error)")
        }
    }

    private func createStarterMemory() {
        let projectName = appState.currentProject?.name ?? "Project"
        let starter = """
        # \(projectName) - Session Memory

        ## Current State

        <!-- Describe the project's current tech stack, deployment status, key decisions -->

        ## Key Patterns

        <!-- Document patterns and conventions Claude should follow -->

        ## Common Gotchas

        <!-- Capture pitfalls and non-obvious behaviors -->
        """
        // Remove the leading whitespace from the heredoc indentation.
        let content = starter.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var s = String(line)
                // Strip up to 8 leading spaces (our indentation).
                var stripped = 0
                while stripped < 8 && s.hasPrefix(" ") {
                    s.removeFirst()
                    stripped += 1
                }
                return s
            }
            .joined(separator: "\n")

        createFile(name: "MEMORY.md", content: content)
    }
}

// MARK: - File Row

struct MemoryFileRow: View {
    let file: MemoryFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.isPrimary ? "star.fill" : "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(file.isPrimary ? .orange : .secondary)
                .frame(width: 14)

            Text(file.displayName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)

            Spacer()

            if isHovering && !file.isPrimary {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("Delete file")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - New File Sheet

struct NewMemoryFileSheet: View {
    @Binding var isPresented: Bool
    let onCreate: (String, String) -> Void

    @State private var filename: String = ""
    @State private var content: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("New Memory File")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Filename")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 0) {
                    TextField("e.g. architecture", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text(".md")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }
            .frame(width: 320)

            VStack(alignment: .leading, spacing: 8) {
                Text("Initial content (optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextEditor(text: $content)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    )
            }
            .frame(width: 320)

            VStack(alignment: .leading, spacing: 4) {
                Label("Link from MEMORY.md for auto-discovery", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("e.g. See [Architecture](architecture.md)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 320, alignment: .leading)

            HStack(spacing: 12) {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Button("Create") {
                    let trimmed = filename.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let heading = "# \(trimmed.capitalized)\n\n"
                        let initial = content.isEmpty ? heading : content
                        onCreate(trimmed, initial)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}
