import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject var appState: AppState

    @State private var rootNodes: [FileTreeNode] = []
    @State private var selectedNodeId: String?
    @State private var searchText = ""
    @State private var treeVersion = 0

    // Content cache: relative path -> (content, language)
    @State private var contentCache: [String: (content: String, language: String?)] = [:]
    @State private var currentContent: String?
    @State private var currentLanguage: String?
    @State private var currentFileName: String?
    @State private var isTruncated = false
    @State private var isBinary = false

    // Edit mode state
    @State private var isEditMode = false
    @State private var showDiff = false
    @State private var editedContent: String = ""
    @State private var selectedFile: FileTreeNode?

    private static let maxFileSize = 512 * 1024 // 512 KB
    private static let maxLineCount = 10_000

    var body: some View {
        Group {
            if appState.currentProject == nil {
                emptyState(icon: "folder", title: "Select a project", subtitle: "Choose a project from the sidebar to browse files")
            } else {
                HSplitView {
                    treePanel
                        .frame(minWidth: 220, idealWidth: 260)

                    viewerPanel
                        .frame(minWidth: 300)
                }
            }
        }
        .onAppear { loadRoot() }
        .onChange(of: appState.currentProject) { _, _ in
            resetAll()
            loadRoot()
        }
    }

    // MARK: - Tree Panel

    private var treePanel: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: ScopeTheme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(ScopeTheme.Font.footnote)
                    .foregroundColor(.secondary)
                TextField("Filter files…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(ScopeTheme.Font.footnote)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(ScopeTheme.Font.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ScopeTheme.Spacing.md)
            .padding(.vertical, ScopeTheme.Spacing.sm)
            .background(ScopeTheme.Colors.controlBg)
            .cornerRadius(ScopeTheme.Radius.small)
            .padding(.horizontal, ScopeTheme.Spacing.sm)
            .padding(.vertical, ScopeTheme.Spacing.sm)

            Divider()

            // Tree
            ScrollView {
                LazyVStack(spacing: 1) {
                    let nodes = searchText.isEmpty ? visibleNodes : filteredNodes
                    ForEach(nodes, id: \.id) { node in
                        FileTreeRowView(node: node, isSelected: selectedNodeId == node.id)
                            .onTapGesture {
                                handleNodeTap(node)
                            }
                    }
                    .id(treeVersion) // force re-render on tree mutations
                }
                .padding(.vertical, ScopeTheme.Spacing.xxs)
                .padding(.horizontal, ScopeTheme.Spacing.xxs)
            }
        }
    }

    // MARK: - Viewer Panel

    private var viewerPanel: some View {
        Group {
            if isBinary {
                emptyState(icon: "doc.fill", title: "Binary file", subtitle: "This file cannot be previewed as text")
            } else if let content = currentContent {
                VStack(spacing: 0) {
                    // File name header
                    if let name = currentFileName {
                        HStack {
                            Text(name)
                                .font(ScopeTheme.Font.mono)
                                .foregroundColor(.primary)
                            if let lang = currentLanguage {
                                Text(lang)
                                    .font(ScopeTheme.Font.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, ScopeTheme.Spacing.xs)
                                    .padding(.vertical, ScopeTheme.Spacing.xxxs)
                                    .background(
                                        RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                                            .fill(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.border))
                                    )
                            }
                            Spacer()

                            if currentContent != nil && !isBinary {
                                // Diff toggle
                                Button {
                                    showDiff.toggle()
                                    if showDiff { isEditMode = false }
                                } label: {
                                    Image(systemName: showDiff ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
                                        .font(ScopeTheme.Font.footnoteMedium)
                                        .foregroundColor(showDiff ? .accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Toggle Git Diff")

                                // Edit/View toggle
                                Button {
                                    if !isEditMode {
                                        editedContent = currentContent ?? ""
                                    }
                                    isEditMode.toggle()
                                    if isEditMode { showDiff = false }
                                } label: {
                                    Image(systemName: isEditMode ? "pencil.circle.fill" : "pencil.circle")
                                        .font(ScopeTheme.Font.footnoteMedium)
                                        .foregroundColor(isEditMode ? .accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help(isEditMode ? "Switch to Read Mode" : "Switch to Edit Mode")
                            }
                        }
                        .padding(.horizontal, ScopeTheme.Spacing.md)
                        .padding(.vertical, ScopeTheme.Spacing.sm)

                        Divider()
                    }

                    if isTruncated {
                        HStack(spacing: ScopeTheme.Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(ScopeTheme.Font.footnote)
                                .foregroundColor(.white)
                            Text("File truncated — showing first portion only")
                                .font(ScopeTheme.Font.footnote)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, ScopeTheme.Spacing.md)
                        .padding(.vertical, ScopeTheme.Spacing.xs)
                        .background(Color.white.opacity(ScopeTheme.Opacity.hover))
                    }

                    if isEditMode {
                        CodeEditorView(
                            content: $editedContent,
                            language: currentLanguage
                        )
                    } else if showDiff, let path = selectedFile?.fullPath.path {
                        DiffViewerView(filePath: path)
                    } else {
                        CodeViewerView(content: content, language: currentLanguage)
                    }
                }
                .onChange(of: selectedNodeId) { _, _ in
                    isEditMode = false
                    showDiff = false
                    editedContent = ""
                }
                .background {
                    if isEditMode, let path = selectedFile?.fullPath.path {
                        Button("") {
                            saveFile(content: editedContent, to: path)
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                    }
                }
            } else {
                emptyState(icon: "doc.text", title: "Select a file to view", subtitle: "Click a file in the tree to preview its contents")
            }
        }
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: ScopeTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(ScopeTheme.Font.bodyMedium)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(ScopeTheme.Font.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tree Traversal

    private var visibleNodes: [FileTreeNode] {
        var result: [FileTreeNode] = []
        func walk(_ nodes: [FileTreeNode]) {
            for node in nodes.sorted(by: { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }) {
                result.append(node)
                if node.isDirectory && node.isExpanded {
                    walk(node.sortedChildren)
                }
            }
        }
        walk(rootNodes)
        return result
    }

    private var filteredNodes: [FileTreeNode] {
        let query = searchText.lowercased()
        var result: [FileTreeNode] = []
        func walk(_ nodes: [FileTreeNode]) {
            for node in nodes {
                if !node.isDirectory && node.name.lowercased().contains(query) {
                    result.append(node)
                }
                if node.isDirectory, let children = node.children {
                    walk(children)
                } else if node.isDirectory {
                    // Load lazily for search
                    node.loadChildren()
                    walk(node.sortedChildren)
                }
            }
        }
        walk(rootNodes)
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Actions

    private func handleNodeTap(_ node: FileTreeNode) {
        if node.isDirectory {
            node.loadChildren()
            node.isExpanded.toggle()
            treeVersion += 1
        } else {
            selectedNodeId = node.id
            selectedFile = node
            loadFileContent(node)
        }
    }

    private func loadFileContent(_ node: FileTreeNode) {
        // Check cache
        if let cached = contentCache[node.id] {
            currentContent = cached.content
            currentLanguage = cached.language
            currentFileName = node.name
            isBinary = false
            isTruncated = false
            return
        }

        let url = node.fullPath
        let language = FileTreeNode.detectLanguage(from: node.name)

        // Check file size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            currentContent = nil
            currentLanguage = nil
            currentFileName = node.name
            isBinary = true
            isTruncated = false
            return
        }

        // Read with size limit
        let readSize = min(size, Self.maxFileSize)
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            isBinary = true
            currentContent = nil
            currentLanguage = nil
            currentFileName = node.name
            isTruncated = false
            return
        }
        defer { fileHandle.closeFile() }

        let data = fileHandle.readData(ofLength: readSize)

        // Try UTF-8 decode
        guard var text = String(data: data, encoding: .utf8) else {
            isBinary = true
            currentContent = nil
            currentLanguage = nil
            currentFileName = node.name
            isTruncated = false
            return
        }

        isBinary = false
        var truncated = size > Self.maxFileSize

        // Line count limit
        let lines = text.components(separatedBy: "\n")
        if lines.count > Self.maxLineCount {
            text = lines.prefix(Self.maxLineCount).joined(separator: "\n")
            truncated = true
        }

        isTruncated = truncated
        currentContent = text
        currentLanguage = language
        currentFileName = node.name

        // Cache
        contentCache[node.id] = (content: text, language: language)
    }

    // MARK: - Save

    private func saveFile(content: String, to path: String) {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            // Update cache so the viewer shows the saved content
            if let file = selectedFile {
                let lang = FileTreeNode.detectLanguage(from: file.name)
                contentCache[file.id] = (content: content, language: lang)
                currentContent = content
            }
        } catch {
            print("FileBrowserView: failed to save file: \(error)")
        }
    }

    // MARK: - Lifecycle

    private func loadRoot() {
        guard let project = appState.currentProject else {
            rootNodes = []
            return
        }
        rootNodes = FileTreeNode.makeRoot(for: project.path)
    }

    private func resetAll() {
        rootNodes = []
        selectedNodeId = nil
        selectedFile = nil
        searchText = ""
        contentCache = [:]
        currentContent = nil
        currentLanguage = nil
        currentFileName = nil
        isTruncated = false
        isBinary = false
        isEditMode = false
        showDiff = false
        editedContent = ""
        treeVersion += 1
    }
}
