import SwiftUI
import GRDB

struct NoteListView: View {
    var globalMode: Bool = false
    @EnvironmentObject var appState: AppState
    @State private var notes: [Note] = []
    @State private var selectedNote: Note?
    @State private var searchText: String = ""

    private var filteredNotes: [Note] {
        let sorted = sortedNotes
        if searchText.isEmpty { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            // Left sidebar: note list
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Notes")
                        .font(ScopeTheme.Font.bodySemibold)
                    Spacer()
                    Button {
                        createNote()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("New note")
                }
                .padding(.horizontal, ScopeTheme.Spacing.md)
                .padding(.vertical, ScopeTheme.Spacing.sm)

                Divider()

                // Note list
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredNotes) { note in
                            NoteRow(note: note, isSelected: selectedNote?.id == note.id)
                                .onTapGesture {
                                    selectedNote = note
                                }
                        }
                    }
                }
            }
            .frame(minWidth: 200, idealWidth: 240)

            // Right: editor or placeholder
            if let note = selectedNote {
                NoteEditorView(
                    note: note,
                    onSave: { title, content in
                        saveNote(note: note, title: title, content: content)
                    },
                    onDelete: {
                        deleteNote(note: note)
                    },
                    onTogglePin: {
                        togglePin(note: note)
                    }
                )
                .frame(minWidth: 300)
            } else {
                VStack(spacing: ScopeTheme.Spacing.sm) {
                    Image(systemName: "note.text")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select or create a note")
                        .font(ScopeTheme.Font.bodyMedium)
                        .foregroundColor(.secondary)
                    Text("Use notes to capture project context")
                        .font(ScopeTheme.Font.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadNotes() }
        .onChange(of: appState.currentProject) { _, _ in
            selectedNote = nil
            loadNotes()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            loadNotes()
        }
    }

    // Pinned first, then by updatedAt descending
    private var sortedNotes: [Note] {
        notes.sorted { a, b in
            if a.pinned != b.pinned {
                return a.pinned
            }
            return a.updatedAt > b.updatedAt
        }
    }

    // MARK: - CRUD

    private func loadNotes() {
        do {
            if globalMode {
                notes = try DatabaseService.shared.dbQueue.read { db in
                    try Note
                        .filter(Column("isGlobal") == true)
                        .order(Column("updatedAt").desc)
                        .fetchAll(db)
                }
            } else {
                guard let project = appState.currentProject else {
                    notes = []
                    return
                }
                notes = try DatabaseService.shared.dbQueue.read { db in
                    try Note
                        .filter(Column("projectId") == project.id)
                        .filter(Column("isGlobal") == false)
                        .order(Column("updatedAt").desc)
                        .fetchAll(db)
                }
            }
        } catch {
            print("NoteListView: failed to load notes: \(error)")
        }
    }

    private func createNote() {
        let projectId: String
        if globalMode {
            projectId = "__global__"
        } else {
            guard let project = appState.currentProject else { return }
            projectId = project.id
        }

        let now = Date()
        var note = Note(
            id: nil,
            projectId: projectId,
            title: "Untitled Note",
            content: "",
            pinned: false,
            sessionId: nil,
            createdAt: now,
            updatedAt: now,
            isGlobal: globalMode
        )

        do {
            try DatabaseService.shared.dbQueue.write { db in
                try note.insert(db)
            }
            loadNotes()
            selectedNote = notes.first { $0.id == note.id }
        } catch {
            print("NoteListView: failed to create note: \(error)")
        }
    }

    private func saveNote(note: Note, title: String, content: String) {
        guard var updated = notes.first(where: { $0.id == note.id }) else { return }
        updated.title = title
        updated.content = content
        updated.updatedAt = Date()

        do {
            try DatabaseService.shared.dbQueue.write { db in
                try updated.update(db)
            }
            loadNotes()
            selectedNote = notes.first { $0.id == updated.id }
        } catch {
            print("NoteListView: failed to save note: \(error)")
        }
    }

    private func deleteNote(note: Note) {
        do {
            try DatabaseService.shared.dbQueue.write { db in
                _ = try Note.deleteOne(db, id: note.id)
            }
            if selectedNote?.id == note.id {
                selectedNote = nil
            }
            loadNotes()
        } catch {
            print("NoteListView: failed to delete note: \(error)")
        }
    }

    private func togglePin(note: Note) {
        guard var updated = notes.first(where: { $0.id == note.id }) else { return }
        updated.pinned.toggle()
        updated.updatedAt = Date()

        do {
            try DatabaseService.shared.dbQueue.write { db in
                try updated.update(db)
            }
            loadNotes()
            selectedNote = notes.first { $0.id == updated.id }
        } catch {
            print("NoteListView: failed to toggle pin: \(error)")
        }
    }
}

// MARK: - Note Row

struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    @EnvironmentObject var settings: AppSettings
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: ScopeTheme.Spacing.xs) {
            if note.pinned {
                Image(systemName: "pin.fill")
                    .font(ScopeTheme.Font.tag)
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxxs) {
                Text(settings.demoMode ? DemoContent.shared.mask(note.title, as: .note) : note.title)
                    .font(ScopeTheme.Font.footnoteMedium)
                    .lineLimit(1)

                Text(note.updatedAt, style: .relative)
                    .font(ScopeTheme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, ScopeTheme.Spacing.sm)
        .padding(.vertical, ScopeTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small)
                .fill(isSelected
                      ? Color.accentColor.opacity(ScopeTheme.Opacity.selection)
                      : isHovering ? ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.selection) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
