import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GRDB

struct TaskDetailView: View {
    let task: TaskItem
    let onSave: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var claudeService: ClaudeService
    @EnvironmentObject var settings: AppSettings

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var priority: Int = 0
    @State private var selectedLabels: Set<String> = []
    @State private var customLabel: String = ""
    @State private var selectedProjectId: String = "__global__"

    @State private var attachedImages: [String] = []
    @State private var attachedMarkdown: [String] = []
    @State private var expandedFiles: Set<String> = []
    @State private var isDropTargeted = false
    @State private var notes: [TaskNote] = []
    @State private var newNoteText: String = ""


    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Task Details")
                    .font(WorkspaceTheme.Font.headline)
                Spacer()

                // Source badge
                Text(task.source.uppercased())
                    .font(WorkspaceTheme.Font.tag)
                    .tracking(0.3)
                    .padding(.horizontal, WorkspaceTheme.Spacing.xs)
                    .padding(.vertical, WorkspaceTheme.Spacing.xxxs)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(task.source == "claude" || task.source == "ai-extracted"
                                  ? Color.purple.opacity(WorkspaceTheme.Opacity.subtleBorder)
                                  : WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.subtleBorder))
                    )
                    .foregroundColor(task.source == "claude" || task.source == "ai-extracted" ? .purple : .secondary)
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.xl)
            .padding(.vertical, WorkspaceTheme.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.lg) {
                    // Title
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xxs) {
                        Text("Title")
                            .font(WorkspaceTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)
                        TextField("Task title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(WorkspaceTheme.Font.body)
                    }

                    // Project assignment
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                        Text("Project")
                            .font(WorkspaceTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)

                        Picker("Project", selection: $selectedProjectId) {
                            ForEach(appState.projects.filter { $0.id != "__global__" }) { project in
                                Text(projectPickerLabel(project))
                                    .tag(project.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    // Description
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xxs) {
                        Text("Description")
                                .font(WorkspaceTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)

                        TextEditor(text: $description)
                            .font(WorkspaceTheme.Font.mono)
                            .scrollContentBackground(.hidden)
                            .padding(WorkspaceTheme.Spacing.sm)
                            .frame(minHeight: 120)
                            .background(
                                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                    .fill(WorkspaceTheme.Colors.controlBg.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                    .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.border), lineWidth: 0.5)
                            )

                    }

                    // Priority
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                        Text("Priority")
                            .font(WorkspaceTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)

                        Picker("Priority", selection: $priority) {
                            ForEach(TaskItem.Priority.allCases, id: \.rawValue) { level in
                                Text(level.label).tag(level.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Labels
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                        Text("Labels")
                            .font(WorkspaceTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)

                        // Predefined labels
                        FlowLayout(spacing: WorkspaceTheme.Spacing.xxs) {
                            ForEach(TaskItem.predefinedLabels, id: \.self) { label in
                                LabelChip(
                                    label: label,
                                    isSelected: selectedLabels.contains(label),
                                    color: TaskItem.labelColor(for: label)
                                ) {
                                    if selectedLabels.contains(label) {
                                        selectedLabels.remove(label)
                                    } else {
                                        selectedLabels.insert(label)
                                    }
                                }
                            }
                        }

                        // Custom label input
                        HStack(spacing: WorkspaceTheme.Spacing.xs) {
                            TextField("Add custom label", text: $customLabel)
                                .textFieldStyle(.roundedBorder)
                                .font(WorkspaceTheme.Font.footnote)
                                .frame(width: 150)
                                .onSubmit {
                                    addCustomLabel()
                                }

                            Button("Add") {
                                addCustomLabel()
                            }
                            .font(WorkspaceTheme.Font.footnote)
                            .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        // Show custom labels that are selected but not predefined
                        let customSelected = selectedLabels.filter { !TaskItem.predefinedLabels.contains($0) }
                        if !customSelected.isEmpty {
                            HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                                ForEach(Array(customSelected).sorted(), id: \.self) { label in
                                    LabelChip(label: label, isSelected: true, color: .secondary) {
                                        selectedLabels.remove(label)
                                    }
                                }
                            }
                        }
                    }

                    // Metadata
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xxs) {
                        Text("Info")
                            .font(WorkspaceTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)

                        HStack(spacing: WorkspaceTheme.Spacing.md) {
                            Label(task.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()), systemImage: "calendar")
                            if let session = task.sourceSession {
                                Label(String(session.prefix(8)), systemImage: "link")
                            }
                        }
                        .font(WorkspaceTheme.Font.caption)
                        .foregroundColor(.secondary)
                    }

                    // Notes thread
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                        HStack {
                            Text("Notes")
                                .font(WorkspaceTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)
                            if !notes.isEmpty {
                                Text("(\(notes.count))")
                                    .font(WorkspaceTheme.Font.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        // Existing notes
                        if !notes.isEmpty {
                            VStack(spacing: WorkspaceTheme.Spacing.xxs) {
                                ForEach(notes) { note in
                                    HStack(alignment: .top, spacing: WorkspaceTheme.Spacing.xs) {
                                        Image(systemName: noteIcon(note.source))
                                            .font(.system(size: 9))
                                            .foregroundColor(noteColor(note.source))
                                            .frame(width: 12, alignment: .center)
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xxxs) {
                                            Text(settings.demoMode ? DemoContent.shared.mask(note.content, as: .snippet) : note.content)
                                                .font(WorkspaceTheme.Font.footnote)
                                                .foregroundColor(.primary.opacity(0.85))

                                            Text(note.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                                .font(WorkspaceTheme.Font.tag)
                                                .foregroundStyle(.tertiary)
                                        }

                                        Spacer()

                                        Button {
                                            deleteNote(note)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, WorkspaceTheme.Spacing.xxs)
                                    .padding(.horizontal, WorkspaceTheme.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                            .fill(WorkspaceTheme.Colors.controlBg.opacity(0.4))
                                    )
                                }
                            }
                        }

                        // Add note input
                        HStack(spacing: WorkspaceTheme.Spacing.xs) {
                            TextField("Add a note...", text: $newNoteText)
                                .textFieldStyle(.roundedBorder)
                                .font(WorkspaceTheme.Font.footnote)
                                .onSubmit { addNote() }

                            Button {
                                addNote()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty
                                                     ? .secondary : .accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    // Markdown Files
                    if !attachedMarkdown.isEmpty {
                        VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                            Text("Files")
                                .font(WorkspaceTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)

                            ForEach(attachedMarkdown, id: \.self) { path in
                                let filename = (path as NSString).lastPathComponent
                                let isExpanded = expandedFiles.contains(path)
                                VStack(alignment: .leading, spacing: 0) {
                                    Button {
                                        if isExpanded { expandedFiles.remove(path) }
                                        else { expandedFiles.insert(path) }
                                    } label: {
                                        HStack(spacing: WorkspaceTheme.Spacing.xs) {
                                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 10)
                                            Image(systemName: filename == "PLAN.md" ? "list.bullet.rectangle" : "doc.text")
                                                .font(WorkspaceTheme.Font.caption)
                                                .foregroundColor(filename == "PLAN.md" ? .orange : .blue)
                                            Text(filename)
                                                .font(WorkspaceTheme.Font.footnoteMedium)
                                                .foregroundColor(.primary)
                                            Spacer()
                                            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                                               let size = attrs[.size] as? Int {
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                    .font(WorkspaceTheme.Font.tag)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        .padding(.vertical, WorkspaceTheme.Spacing.xs)
                                        .padding(.horizontal, WorkspaceTheme.Spacing.sm)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if isExpanded {
                                        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                                            ScrollView {
                                                Text(content)
                                                    .font(WorkspaceTheme.Font.mono)
                                                    .foregroundColor(.primary.opacity(0.85))
                                                    .textSelection(.enabled)
                                                    .padding(WorkspaceTheme.Spacing.sm)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .frame(maxHeight: 300)
                                            .background(
                                                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                                    .fill(WorkspaceTheme.Colors.controlBg.opacity(0.4))
                                            )
                                            .padding(.horizontal, WorkspaceTheme.Spacing.sm)
                                            .padding(.bottom, WorkspaceTheme.Spacing.xs)
                                        }
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                        .fill(WorkspaceTheme.Colors.controlBg.opacity(0.3))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                        .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.border), lineWidth: 0.5)
                                )
                            }
                        }
                    }

                    // Attachments
                    VStack(alignment: .leading, spacing: WorkspaceTheme.Spacing.xs) {
                        HStack {
                            Text("Attachments")
                                .font(WorkspaceTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                pickImages()
                            } label: {
                                HStack(spacing: WorkspaceTheme.Spacing.xxxs) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Add Image")
                                        .font(WorkspaceTheme.Font.caption)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        // Drop zone + thumbnails
                        ZStack {
                            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                .fill(isDropTargeted
                                      ? Color.accentColor.opacity(WorkspaceTheme.Opacity.hover)
                                      : WorkspaceTheme.Colors.controlBg.opacity(0.3))
                            RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                                .strokeBorder(
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                                )
                                .foregroundColor(isDropTargeted ? .accentColor : WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.border))

                            if attachedImages.isEmpty {
                                VStack(spacing: WorkspaceTheme.Spacing.xxs) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.tertiary)
                                    Text("Drop images here")
                                        .font(WorkspaceTheme.Font.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: WorkspaceTheme.Spacing.sm) {
                                        ForEach(attachedImages, id: \.self) { path in
                                            AttachmentThumbnail(path: path) {
                                                attachedImages.removeAll { $0 == path }
                                            }
                                        }
                                    }
                                    .padding(WorkspaceTheme.Spacing.sm)
                                }
                            }
                        }
                        .frame(height: attachedImages.isEmpty ? 60 : 80)
                        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                    }

                }
                .padding(WorkspaceTheme.Spacing.xl)
            }

            Divider()

            // Bottom bar
            HStack {
                Button(role: .destructive) {
                    onDelete(task)
                    dismiss()
                } label: {
                    HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                        Image(systemName: "trash")
                            .font(WorkspaceTheme.Font.caption)
                        Text("Delete")
                            .font(WorkspaceTheme.Font.footnoteMedium)
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveChanges()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, WorkspaceTheme.Spacing.xl)
            .padding(.vertical, WorkspaceTheme.Spacing.md)
        }
        .frame(width: 520, height: 800)
        .onAppear {
            title = task.title
            description = task.description ?? ""
            priority = task.priority
            selectedProjectId = task.projectId
            selectedLabels = Set(task.labelsArray)
            let allAttachments = task.attachmentsArray
            attachedMarkdown = allAttachments.filter { $0.hasSuffix(".md") }
            attachedImages = allAttachments.filter { !$0.hasSuffix(".md") }
            loadNotes()
        }
    }

    // MARK: - Actions

    private func saveChanges() {
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.description = description.isEmpty ? nil : description
        updated.priority = priority
        updated.projectId = selectedProjectId
        updated.setLabels(Array(selectedLabels).sorted())
        updated.setAttachments(attachedMarkdown + attachedImages)
        onSave(updated)
        dismiss()
    }

    private func projectPickerLabel(_ project: Project) -> String {
        let name = settings.demoMode ? DemoContent.shared.mask(project.name, as: .project) : project.name
        let tags = project.tagsArray
        if tags.isEmpty { return name }
        let maskedTags = settings.demoMode ? tags.map { DemoContent.shared.mask($0, as: .project) } : tags
        return "\(name) (\(maskedTags.joined(separator: ", ")))"
    }

    private func addCustomLabel() {
        let label = customLabel.trimmingCharacters(in: .whitespaces).lowercased()
        if !label.isEmpty {
            selectedLabels.insert(label)
            customLabel = ""
        }
    }



    // MARK: - Notes

    private func loadNotes() {
        guard let taskId = task.id else { return }
        do {
            notes = try DatabaseService.shared.dbQueue.read { db in
                try TaskNote
                    .filter(Column("taskId") == taskId)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }
        } catch {
            print("TaskDetailView: failed to load notes: \(error)")
        }
    }

    private func addNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let taskId = task.id else { return }
        var note = TaskNote(
            id: nil,
            taskId: taskId,
            content: text,
            source: "manual",
            sessionId: nil,
            createdAt: Date()
        )
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try note.insert(db)
            }
            newNoteText = ""
            loadNotes()
        } catch {
            print("TaskDetailView: failed to add note: \(error)")
        }
    }

    private func deleteNote(_ note: TaskNote) {
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in
                try note.delete(db)
            }
            loadNotes()
        } catch {
            print("TaskDetailView: failed to delete note: \(error)")
        }
    }

    private func noteIcon(_ source: String) -> String {
        switch source {
        case "claude": return "sparkle"
        case "system": return "gear"
        default:       return "person"
        }
    }

    private func noteColor(_ source: String) -> Color {
        switch source {
        case "claude": return .purple
        case "system": return .secondary
        default:       return .blue
        }
    }

    // MARK: - Image Attachments

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    let ext = url.pathExtension.lowercased()
                    let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]
                    guard imageExts.contains(ext) else { return }
                    DispatchQueue.main.async {
                        if !attachedImages.contains(url.path) {
                            attachedImages.append(url.path)
                        }
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data = data else { return }
                    let fileName = "task-img-\(Int(Date().timeIntervalSince1970)).png"
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("workspace-task-images", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let fileURL = dir.appendingPathComponent(fileName)
                    if let rep = NSBitmapImageRep(data: data),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: fileURL)
                        DispatchQueue.main.async {
                            attachedImages.append(fileURL.path)
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .bmp, .tiff, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Attach Images"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !attachedImages.contains(url.path) {
                    attachedImages.append(url.path)
                }
            }
        }
    }

}

// MARK: - Label Chip

struct LabelChip: View {
    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(WorkspaceTheme.Font.caption)
                .padding(.horizontal, WorkspaceTheme.Spacing.sm)
                .padding(.vertical, WorkspaceTheme.Spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? color.opacity(0.15) : WorkspaceTheme.Colors.controlBg.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? color.opacity(WorkspaceTheme.Opacity.border) : WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.border), lineWidth: 0.5)
                )
                .foregroundColor(isSelected ? color : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Attachment Thumbnail

struct AttachmentThumbnail: View {
    let path: String
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                            .stroke(WorkspaceTheme.Colors.separator.opacity(WorkspaceTheme.Opacity.border), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: WorkspaceTheme.Radius.small, style: .continuous)
                    .fill(WorkspaceTheme.Colors.controlBg)
                    .frame(width: 64, height: 64)
                    .overlay {
                        VStack(spacing: WorkspaceTheme.Spacing.xxxs) {
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
            }

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .help((path as NSString).lastPathComponent)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(subviews: subviews, in: proposal.width ?? 0)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews: subviews, in: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }

        return (positions, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
