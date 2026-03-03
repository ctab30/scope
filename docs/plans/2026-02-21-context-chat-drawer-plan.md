# Context Chat Drawer — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a persistent, context-aware chat drawer that uses `claude -p` to answer questions about projects, tasks, sessions, and notes — with action buttons to create tasks, save notes, copy, or paste to terminal.

**Architecture:** Side drawer overlays the right panel (GUIPanelView). `ContextAssembler` gathers project data from SQLite. `ClaudeService.chat()` builds a prompt with context + conversation history and shells out to `claude -p`. Chat history persists in two new DB tables.

**Tech Stack:** SwiftUI, GRDB, ClaudeService (`claude -p` CLI)

---

### Task 1: DB Models — ChatConversation + ChatMessage

**Files:**
- Create: `Context/Sources/Context/Models/ChatConversation.swift`
- Create: `Context/Sources/Context/Models/ChatMessage.swift`
- Modify: `Context/Sources/Context/Services/DatabaseService.swift` (after line 249, before `return migrator`)

**Step 1: Create ChatConversation model**

Create `Context/Sources/Context/Models/ChatConversation.swift`:

```swift
import Foundation
import GRDB

struct ChatConversation: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String?  // nil = global/home scope
    var title: String
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "chatConversations"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

**Step 2: Create ChatMessage model**

Create `Context/Sources/Context/Models/ChatMessage.swift`:

```swift
import Foundation
import GRDB

struct ChatMessage: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var conversationId: Int64
    var role: String  // "user" or "assistant"
    var content: String
    var createdAt: Date

    static let databaseTableName = "chatMessages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

**Step 3: Add v12 migration to DatabaseService.swift**

In `DatabaseService.swift`, insert before `return migrator` (after the v11 migration):

```swift
migrator.registerMigration("v12_createChatTables") { db in
    try db.create(table: "chatConversations") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("projectId", .text) // nullable — null means global
        t.column("title", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
    }

    try db.create(table: "chatMessages") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("conversationId", .integer).notNull()
            .references("chatConversations", onDelete: .cascade)
        t.column("role", .text).notNull()
        t.column("content", .text).notNull()
        t.column("createdAt", .datetime).notNull()
    }
}
```

**Step 4: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 5: Commit**

```
git add Context/Sources/Context/Models/ChatConversation.swift Context/Sources/Context/Models/ChatMessage.swift Context/Sources/Context/Services/DatabaseService.swift
git commit -m "feat(chat): add ChatConversation and ChatMessage models with v12 migration"
```

---

### Task 2: ContextAssembler Service

**Files:**
- Create: `Context/Sources/Context/Services/ContextAssembler.swift`

**Step 1: Create ContextAssembler**

This service gathers project data from the DB and formats it as a text preamble for Claude.

```swift
import Foundation
import GRDB

struct ContextAssembler {
    /// Assemble context for a specific project. Returns a text preamble.
    static func projectContext(projectId: String, projectName: String, projectPath: String) -> String {
        var parts: [String] = []
        var totalChars = 0
        let maxChars = 8_000

        parts.append("""
        You are a helpful assistant with deep context about the "\(projectName)" project.
        Project path: \(projectPath)

        Answer questions about this project's tasks, sessions, notes, architecture, and codebase.
        When referencing tasks, include their status and priority. Be concise and specific.
        """)
        totalChars += parts.last!.count

        // Active tasks
        if let tasks = try? DatabaseService.shared.dbQueue.read({ db in
            try TaskItem
                .filter(Column("projectId") == projectId)
                .filter(Column("status") != "done")
                .order(Column("priority").desc, Column("createdAt").desc)
                .limit(20)
                .fetchAll(db)
        }), !tasks.isEmpty {
            var section = "\nACTIVE TASKS (\(tasks.count)):\n"
            for task in tasks {
                let priority = TaskItem.Priority(rawValue: task.priority)?.label ?? "None"
                let labels = task.labelsArray.joined(separator: ", ")
                section += "- [\(priority.uppercased())] \(task.title) (status: \(task.status)"
                if !labels.isEmpty { section += ", labels: \(labels)" }
                section += ")\n"
                if let desc = task.description, !desc.isEmpty {
                    section += "  \(String(desc.prefix(120)))\n"
                }
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Pinned notes (full content, highest priority)
        if let notes = try? DatabaseService.shared.dbQueue.read({ db in
            try Note
                .filter(Column("projectId") == projectId)
                .filter(Column("pinned") == true)
                .order(Column("updatedAt").desc)
                .limit(5)
                .fetchAll(db)
        }), !notes.isEmpty {
            var section = "\nPINNED NOTES:\n"
            for note in notes {
                let content = String(note.content.prefix(500))
                section += "## \(note.title)\n\(content)\n\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Recent sessions
        if let sessions = try? DatabaseService.shared.dbQueue.read({ db in
            try Session
                .filter(Column("projectId") == projectId)
                .order(Column("startedAt").desc)
                .limit(5)
                .fetchAll(db)
        }), !sessions.isEmpty {
            var section = "\nRECENT SESSIONS:\n"
            for session in sessions {
                let date = session.startedAt?.formatted(.dateTime.month(.abbreviated).day()) ?? "?"
                let summary = session.summary ?? "No summary"
                let model = session.model ?? "unknown"
                section += "- \(date): \"\(String(summary.prefix(150)))\" (\(model))\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Recent notes (titles only)
        if let notes = try? DatabaseService.shared.dbQueue.read({ db in
            try Note
                .filter(Column("projectId") == projectId)
                .filter(Column("pinned") == false)
                .order(Column("updatedAt").desc)
                .limit(10)
                .fetchAll(db)
        }), !notes.isEmpty {
            var section = "\nRECENT NOTES:\n"
            for note in notes {
                section += "- \(note.title)\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        return parts.joined(separator: "\n")
    }

    /// Assemble context for the global/home view.
    static func globalContext() -> String {
        var parts: [String] = []
        var totalChars = 0
        let maxChars = 8_000

        parts.append("""
        You are a helpful assistant with context about all projects in this workspace.
        Answer questions about projects, tasks, sessions, and notes across the entire workspace.
        Be concise and specific.
        """)
        totalChars += parts.last!.count

        // All projects with task counts
        if let projects = try? DatabaseService.shared.dbQueue.read({ db in
            try Project.order(Column("lastOpened").desc).fetchAll(db)
        }), !projects.isEmpty {
            var section = "\nPROJECTS (\(projects.count)):\n"
            for project in projects.prefix(20) {
                let taskCount = (try? DatabaseService.shared.dbQueue.read { db in
                    try TaskItem.filter(Column("projectId") == project.id).filter(Column("status") != "done").fetchCount(db)
                }) ?? 0
                let lastActive = project.lastOpened?.formatted(.dateTime.month(.abbreviated).day()) ?? "never"
                section += "- \(project.name): \(taskCount) active tasks, last active \(lastActive)\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Global tasks
        if let tasks = try? DatabaseService.shared.dbQueue.read({ db in
            try TaskItem
                .filter(Column("isGlobal") == true)
                .filter(Column("status") != "done")
                .order(Column("priority").desc)
                .limit(15)
                .fetchAll(db)
        }), !tasks.isEmpty {
            var section = "\nGLOBAL TASKS (\(tasks.count)):\n"
            for task in tasks {
                let priority = TaskItem.Priority(rawValue: task.priority)?.label ?? "None"
                section += "- [\(priority.uppercased())] \(task.title) (status: \(task.status))\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        // Global pinned notes
        if let notes = try? DatabaseService.shared.dbQueue.read({ db in
            try Note
                .filter(Column("isGlobal") == true)
                .filter(Column("pinned") == true)
                .order(Column("updatedAt").desc)
                .limit(5)
                .fetchAll(db)
        }), !notes.isEmpty {
            var section = "\nGLOBAL PINNED NOTES:\n"
            for note in notes {
                section += "## \(note.title)\n\(String(note.content.prefix(400)))\n\n"
            }
            if totalChars + section.count < maxChars {
                parts.append(section)
                totalChars += section.count
            }
        }

        return parts.joined(separator: "\n")
    }
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```
git add Context/Sources/Context/Services/ContextAssembler.swift
git commit -m "feat(chat): add ContextAssembler for project and global context gathering"
```

---

### Task 3: ClaudeService Chat Method

**Files:**
- Modify: `Context/Sources/Context/Services/ClaudeService.swift`

**Step 1: Add chat method**

Add after the `enrichTask` method (around line 127), before `// MARK: - Extract Tasks`:

```swift
// MARK: - Chat

/// Multi-turn chat with assembled project context.
/// Sends context + conversation history to Claude via CLI.
func chat(
    messages: [(role: String, content: String)],
    context: String
) async -> String? {
    // Build the full prompt with context and conversation history
    var prompt = "<context>\n\(context)\n</context>\n\n"

    // Include conversation history (cap at ~25K chars)
    var historyChars = 0
    let maxHistory = 25_000
    var historyLines: [String] = []

    for msg in messages {
        let line: String
        if msg.role == "user" {
            line = "User: \(msg.content)"
        } else {
            line = "Assistant: \(msg.content)"
        }
        if historyChars + line.count > maxHistory { break }
        historyLines.append(line)
        historyChars += line.count
    }

    if historyLines.count > 1 {
        prompt += "Conversation so far:\n"
        // All messages except the last (which is the current question)
        for line in historyLines.dropLast() {
            prompt += line + "\n\n"
        }
        prompt += "\nLatest message:\n\(historyLines.last ?? "")\n"
    } else if let last = historyLines.last {
        prompt += last + "\n"
    }

    prompt += "\nRespond helpfully and concisely. Reference specific tasks, sessions, files, or notes when relevant. Use markdown formatting."

    return await generate(prompt: prompt)
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```
git add Context/Sources/Context/Services/ClaudeService.swift
git commit -m "feat(chat): add multi-turn chat method to ClaudeService"
```

---

### Task 4: ChatMessageView — Message Bubble with Action Buttons

**Files:**
- Create: `Context/Sources/Context/Views/Chat/ChatMessageView.swift`

**Step 1: Create the message view**

```swift
import SwiftUI

struct ChatMessageView: View {
    let message: ChatMessage
    let projectId: String?
    let onCreateTask: (String) -> Void
    let onAddToNotes: (String) -> Void
    let onSendToTerminal: (String) -> Void

    @State private var isHovering = false
    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == "user" {
                Spacer(minLength: 60)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                )

            Text(message.createdAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(message.content))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

            // Action buttons — show on hover
            if isHovering {
                HStack(spacing: 2) {
                    actionButton("Create Task", icon: "checklist") {
                        onCreateTask(message.content)
                    }
                    actionButton("Add to Notes", icon: "note.text.badge.plus") {
                        onAddToNotes(message.content)
                    }
                    actionButton(showCopied ? "Copied!" : "Copy", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            showCopied = false
                        }
                    }
                    actionButton("To Terminal", icon: "terminal") {
                        onSendToTerminal(message.content)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text(message.createdAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Action Button

    private func actionButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```
git add Context/Sources/Context/Views/Chat/ChatMessageView.swift
git commit -m "feat(chat): add ChatMessageView with action buttons"
```

---

### Task 5: ChatDrawerView — The Full Drawer UI

**Files:**
- Create: `Context/Sources/Context/Views/Chat/ChatDrawerView.swift`

**Step 1: Create the drawer view**

```swift
import SwiftUI
import GRDB

struct ChatDrawerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var claudeService = ClaudeService()
    @Binding var isOpen: Bool

    @State private var conversations: [ChatConversation] = []
    @State private var currentConversation: ChatConversation?
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    private var projectId: String? {
        appState.currentProject?.id
    }

    private var contextLabel: String {
        appState.currentProject?.name ?? "All Projects"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty && !claudeService.isGenerating {
                            emptyState
                        }
                        ForEach(messages) { msg in
                            ChatMessageView(
                                message: msg,
                                projectId: projectId,
                                onCreateTask: { content in createTask(from: content) },
                                onAddToNotes: { content in addToNotes(content) },
                                onSendToTerminal: { content in sendToTerminal(content) }
                            )
                            .id(msg.id)
                        }
                        if claudeService.isGenerating {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                Text("Thinking...")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .id("loading")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(messages.last?.id ?? "loading", anchor: .bottom)
                    }
                }
                .onChange(of: claudeService.isGenerating) { _, isGenerating in
                    if isGenerating {
                        withAnimation {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            inputBar
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadConversations() }
        .onChange(of: appState.currentProject?.id) { _, _ in
            loadConversations()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat")
                    .font(.system(size: 13, weight: .semibold))
                Text(contextLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Conversation picker
            if conversations.count > 1 {
                Menu {
                    ForEach(conversations) { conv in
                        Button {
                            selectConversation(conv)
                        } label: {
                            Text(conv.title)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Previous conversations")
            }

            Button {
                newConversation()
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New conversation")

            Button {
                isOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Ask anything about \(contextLabel)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text("Tasks, sessions, architecture, code flows...")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about \(contextLabel)...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        sendMessage()
                    }
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(
                        inputText.trimmingCharacters(in: .whitespaces).isEmpty || claudeService.isGenerating
                        ? .secondary.opacity(0.3)
                        : .accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || claudeService.isGenerating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Data Operations

    private func loadConversations() {
        let pid = projectId
        do {
            conversations = try DatabaseService.shared.dbQueue.read { db in
                if let pid = pid {
                    return try ChatConversation
                        .filter(Column("projectId") == pid)
                        .order(Column("updatedAt").desc)
                        .limit(20)
                        .fetchAll(db)
                } else {
                    return try ChatConversation
                        .filter(Column("projectId") == nil)
                        .order(Column("updatedAt").desc)
                        .limit(20)
                        .fetchAll(db)
                }
            }
            if let first = conversations.first {
                selectConversation(first)
            } else {
                currentConversation = nil
                messages = []
            }
        } catch {
            print("ChatDrawer: failed to load conversations: \(error)")
        }
    }

    private func selectConversation(_ conversation: ChatConversation) {
        currentConversation = conversation
        do {
            messages = try DatabaseService.shared.dbQueue.read { db in
                try ChatMessage
                    .filter(Column("conversationId") == conversation.id!)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }
        } catch {
            print("ChatDrawer: failed to load messages: \(error)")
        }
    }

    private func newConversation() {
        currentConversation = nil
        messages = []
        inputText = ""
        isInputFocused = true
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !claudeService.isGenerating else { return }
        inputText = ""

        Task {
            // Create conversation if needed
            if currentConversation == nil {
                let title = String(text.prefix(60)) + (text.count > 60 ? "..." : "")
                var conv = ChatConversation(
                    projectId: projectId,
                    title: title,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                do {
                    try DatabaseService.shared.dbQueue.write { db in
                        try conv.insert(db)
                    }
                    currentConversation = conv
                    conversations.insert(conv, at: 0)
                } catch {
                    print("ChatDrawer: failed to create conversation: \(error)")
                    return
                }
            }

            guard let convId = currentConversation?.id else { return }

            // Save user message
            var userMsg = ChatMessage(
                conversationId: convId,
                role: "user",
                content: text,
                createdAt: Date()
            )
            do {
                try DatabaseService.shared.dbQueue.write { db in
                    try userMsg.insert(db)
                }
                messages.append(userMsg)
            } catch {
                print("ChatDrawer: failed to save user message: \(error)")
                return
            }

            // Assemble context
            let context: String
            if let project = appState.currentProject {
                context = ContextAssembler.projectContext(
                    projectId: project.id,
                    projectName: project.name,
                    projectPath: project.path
                )
            } else {
                context = ContextAssembler.globalContext()
            }

            // Build message history for Claude
            let history = messages.map { (role: $0.role, content: $0.content) }

            // Call Claude
            guard let response = await claudeService.chat(messages: history, context: context) else {
                // Save error as assistant message
                let errorText = claudeService.lastError ?? "Failed to get response from Claude."
                var errorMsg = ChatMessage(
                    conversationId: convId,
                    role: "assistant",
                    content: "⚠️ \(errorText)",
                    createdAt: Date()
                )
                try? DatabaseService.shared.dbQueue.write { db in
                    try errorMsg.insert(db)
                }
                messages.append(errorMsg)
                return
            }

            // Save assistant message
            var assistantMsg = ChatMessage(
                conversationId: convId,
                role: "assistant",
                content: response,
                createdAt: Date()
            )
            do {
                try DatabaseService.shared.dbQueue.write { db in
                    try assistantMsg.insert(db)
                }
                messages.append(assistantMsg)

                // Update conversation timestamp
                try DatabaseService.shared.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE chatConversations SET updatedAt = ? WHERE id = ?",
                        arguments: [Date(), convId]
                    )
                }
            } catch {
                print("ChatDrawer: failed to save assistant message: \(error)")
            }
        }
    }

    // MARK: - Action Handlers

    private func createTask(from content: String) {
        let title = "Chat: " + String(content.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        var task = TaskItem(
            id: nil,
            projectId: appState.currentProject?.id ?? "__global__",
            title: title,
            description: content,
            status: "todo",
            priority: 2,
            sourceSession: nil,
            source: "chat",
            createdAt: Date(),
            completedAt: nil,
            labels: nil,
            attachments: nil
        )
        task.setLabels(["feature"])
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try task.insert(db)
            }
            NotificationCenter.default.post(name: .tasksDidChange, object: nil)
        } catch {
            print("ChatDrawer: failed to create task: \(error)")
        }
    }

    private func addToNotes(_ content: String) {
        let title = "Chat: " + String(content.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        var note = Note(
            projectId: appState.currentProject?.id ?? "__global__",
            title: title,
            content: content,
            pinned: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        if appState.currentProject == nil {
            note.isGlobal = true
        }
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try note.insert(db)
            }
        } catch {
            print("ChatDrawer: failed to create note: \(error)")
        }
    }

    private func sendToTerminal(_ content: String) {
        NotificationCenter.default.post(
            name: .pasteToTerminal,
            object: nil,
            userInfo: ["text": content]
        )
    }
}

extension Notification.Name {
    static let pasteToTerminal = Notification.Name("pasteToTerminal")
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```
git add Context/Sources/Context/Views/Chat/ChatDrawerView.swift
git commit -m "feat(chat): add ChatDrawerView with full conversation UI and action handlers"
```

---

### Task 6: Wire into GUIPanelView — Chat Icon + Drawer Overlay

**Files:**
- Modify: `Context/Sources/Context/Views/GUIPanelView.swift`

**Step 1: Add state and chat button to GUIPanelView**

In `GUIPanelView`, add state variable (line 84, after `@StateObject private var browserViewModel`):

```swift
@State private var showChatDrawer = false
```

**Step 2: Add chat button to home header**

In the home header `HStack` (line 109), before `MCPIndicator`, add:

```swift
chatButton
```

**Step 3: Add chat button to project header**

In `projectHeader` (line 200), before `MCPIndicator`, add:

```swift
chatButton
```

**Step 4: Add chat button computed property**

After the `tabBar` computed property (around line 222), add:

```swift
private var chatButton: some View {
    Button {
        withAnimation(.easeInOut(duration: 0.2)) {
            showChatDrawer.toggle()
        }
    } label: {
        Image(systemName: showChatDrawer ? "bubble.right.fill" : "bubble.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(showChatDrawer ? .accentColor : .secondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(showChatDrawer ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Chat")
}
```

**Step 5: Add drawer overlay**

Wrap the entire VStack body content in a ZStack (or add `.overlay`) so the drawer slides over. At the end of the `body` computed property, before `.background(Color(nsColor: .windowBackgroundColor))`, add an overlay:

```swift
.overlay(alignment: .trailing) {
    if showChatDrawer {
        HStack(spacing: 0) {
            // Backdrop
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChatDrawer = false
                    }
                }

            // Drawer
            ChatDrawerView(isOpen: $showChatDrawer)
                .transition(.move(edge: .trailing))
        }
    }
}
```

**Step 6: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 7: Commit**

```
git add Context/Sources/Context/Views/GUIPanelView.swift
git commit -m "feat(chat): wire chat icon and drawer overlay into GUIPanelView"
```

---

### Task 7: Terminal Paste Notification Listener

**Files:**
- Modify: `Context/Sources/Context/Terminal/TerminalWrapper.swift`

**Step 1: Add notification listener**

In the `TerminalWrapper` SwiftUI view, add an `.onReceive` modifier for the `.pasteToTerminal` notification. This should go alongside the other modifiers on the view. In the `makeNSView` or `updateNSView` Coordinator, or more simply, the notification can be handled in the `TerminalTabView` which already handles `.launchTask`.

Actually, the cleanest approach: add the listener in `TerminalTabView.swift` since it already handles `.launchTask` notifications and has access to the active terminal.

Find the `.onReceive` for `.launchTask` in `TerminalTabView.swift` and add a parallel listener:

```swift
.onReceive(NotificationCenter.default.publisher(for: .pasteToTerminal)) { notification in
    guard let text = notification.userInfo?["text"] as? String,
          let activeTab = tabs.first(where: { $0.id == activeTabId }),
          let coord = activeTab.coordinator else { return }
    coord.sendText(text)
}
```

The exact wiring depends on how `TerminalTabView` exposes coordinator access. If the coordinator isn't directly accessible, an alternative is to use `NSPasteboard` + programmatic paste:

```swift
.onReceive(NotificationCenter.default.publisher(for: .pasteToTerminal)) { notification in
    guard let text = notification.userInfo?["text"] as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    // The user can then Cmd+V to paste
}
```

This simpler approach copies to clipboard, giving the user control over when to paste. Prefer this if direct terminal injection is complex to wire.

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```
git add Context/Sources/Context/Terminal/TerminalTabView.swift
git commit -m "feat(chat): add terminal paste notification listener for Send to Terminal action"
```

---

### Task 8: Add "chat" source color to TaskCard

**Files:**
- Modify: `Context/Sources/Context/Views/Tasks/TaskCard.swift`

**Step 1: Add source color**

In `TaskCardView`'s `sourceColor` computed property, add after the `"browser"` case:

```swift
case "chat": return .indigo
```

**Step 2: Build + package**

Run: `cd Context && swift build 2>&1 | tail -5`
Then: `bash scripts/package-app.sh`
Expected: Both succeed.

**Step 3: Commit**

```
git add Context/Sources/Context/Views/Tasks/TaskCard.swift
git commit -m "feat(chat): add chat source color to TaskCard"
```

---

### Task 9: Final Integration Build + Package

**Step 1: Full build**

```bash
cd Context && swift build 2>&1 | tail -10
```

**Step 2: Package**

```bash
bash scripts/package-app.sh
```

**Step 3: Final commit with all files**

Verify nothing is left unstaged, then create a final integration commit if needed.

---

## Testing Checklist

1. Open app, navigate to a project
2. Click chat icon (top right) — drawer slides in
3. Type a question about the project — loading spinner shows, then response appears
4. Hover assistant message — action buttons appear
5. Click "Create Task" — task appears on kanban board with "CHAT" source badge
6. Click "Add to Notes" — note appears in Notes tab
7. Click "Copy" — clipboard contains response text
8. Click "To Terminal" — text goes to clipboard (for pasting)
9. Click "New Chat" — conversation resets
10. Close drawer, reopen — previous conversation loads
11. Switch to home view — chat context switches to global
12. Ask a cross-project question — context includes all projects
