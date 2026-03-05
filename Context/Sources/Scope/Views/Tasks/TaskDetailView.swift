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
    @State private var enrichError: String?
    @State private var attachedImages: [String] = []
    @State private var isDropTargeted = false
    @State private var notes: [TaskNote] = []
    @State private var newNoteText: String = ""


    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Task Details")
                    .font(ScopeTheme.Font.headline)
                Spacer()

                // Source badge
                Text(task.source.uppercased())
                    .font(ScopeTheme.Font.tag)
                    .tracking(0.3)
                    .padding(.horizontal, ScopeTheme.Spacing.xs)
                    .padding(.vertical, ScopeTheme.Spacing.xxxs)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(task.source == "claude" || task.source == "ai-extracted"
                                  ? Color.purple.opacity(ScopeTheme.Opacity.subtleBorder)
                                  : ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.subtleBorder))
                    )
                    .foregroundColor(task.source == "claude" || task.source == "ai-extracted" ? .purple : .secondary)
            }
            .padding(.horizontal, ScopeTheme.Spacing.xl)
            .padding(.vertical, ScopeTheme.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: ScopeTheme.Spacing.lg) {
                    // Title
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxs) {
                        Text("Title")
                            .font(ScopeTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)
                        TextField("Task title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(ScopeTheme.Font.body)
                    }

                    // Project assignment
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                        Text("Project")
                            .font(ScopeTheme.Font.footnoteSemibold)
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
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxs) {
                        HStack {
                            Text("Description")
                                .font(ScopeTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)
                            Spacer()

                            // AI Enrich button
                            if claudeService.isGenerating {
                                HStack(spacing: ScopeTheme.Spacing.xxs) {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                    Text("Enriching...")
                                        .font(ScopeTheme.Font.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button {
                                    enrichWithAI()
                                } label: {
                                    Label("Enrich with AI", systemImage: "sparkles")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        TextEditor(text: $description)
                            .font(ScopeTheme.Font.mono)
                            .scrollContentBackground(.hidden)
                            .padding(ScopeTheme.Spacing.sm)
                            .frame(minHeight: 120)
                            .background(
                                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                                    .fill(ScopeTheme.Colors.controlBg.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                                    .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.border), lineWidth: 0.5)
                            )

                        if let error = enrichError {
                            HStack(spacing: ScopeTheme.Spacing.xxs) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(ScopeTheme.Font.caption)
                                Text(error)
                                    .font(ScopeTheme.Font.caption)
                            }
                            .foregroundColor(.white)
                        }
                    }

                    // Priority
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                        Text("Priority")
                            .font(ScopeTheme.Font.footnoteSemibold)
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
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                        Text("Labels")
                            .font(ScopeTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)

                        // Predefined labels
                        FlowLayout(spacing: ScopeTheme.Spacing.xxs) {
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
                        HStack(spacing: ScopeTheme.Spacing.xs) {
                            TextField("Add custom label", text: $customLabel)
                                .textFieldStyle(.roundedBorder)
                                .font(ScopeTheme.Font.footnote)
                                .frame(width: 150)
                                .onSubmit {
                                    addCustomLabel()
                                }

                            Button("Add") {
                                addCustomLabel()
                            }
                            .font(ScopeTheme.Font.footnote)
                            .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        // Show custom labels that are selected but not predefined
                        let customSelected = selectedLabels.filter { !TaskItem.predefinedLabels.contains($0) }
                        if !customSelected.isEmpty {
                            HStack(spacing: ScopeTheme.Spacing.xxs) {
                                ForEach(Array(customSelected).sorted(), id: \.self) { label in
                                    LabelChip(label: label, isSelected: true, color: .secondary) {
                                        selectedLabels.remove(label)
                                    }
                                }
                            }
                        }
                    }

                    // Metadata
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxs) {
                        Text("Info")
                            .font(ScopeTheme.Font.footnoteSemibold)
                            .foregroundColor(.secondary)

                        HStack(spacing: ScopeTheme.Spacing.md) {
                            Label(task.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()), systemImage: "calendar")
                            if let session = task.sourceSession {
                                Label(String(session.prefix(8)), systemImage: "link")
                            }
                        }
                        .font(ScopeTheme.Font.caption)
                        .foregroundColor(.secondary)
                    }

                    // Notes thread
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                        HStack {
                            Text("Notes")
                                .font(ScopeTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)
                            if !notes.isEmpty {
                                Text("(\(notes.count))")
                                    .font(ScopeTheme.Font.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        // Existing notes
                        if !notes.isEmpty {
                            VStack(spacing: ScopeTheme.Spacing.xxs) {
                                ForEach(notes) { note in
                                    HStack(alignment: .top, spacing: ScopeTheme.Spacing.xs) {
                                        Image(systemName: noteIcon(note.source))
                                            .font(.system(size: 9))
                                            .foregroundColor(noteColor(note.source))
                                            .frame(width: 12, alignment: .center)
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xxxs) {
                                            Text(settings.demoMode ? DemoContent.shared.mask(note.content, as: .snippet) : note.content)
                                                .font(ScopeTheme.Font.footnote)
                                                .foregroundColor(.primary.opacity(0.85))

                                            Text(note.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                                .font(ScopeTheme.Font.tag)
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
                                    .padding(.vertical, ScopeTheme.Spacing.xxs)
                                    .padding(.horizontal, ScopeTheme.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                                            .fill(ScopeTheme.Colors.controlBg.opacity(0.4))
                                    )
                                }
                            }
                        }

                        // Add note input
                        HStack(spacing: ScopeTheme.Spacing.xs) {
                            TextField("Add a note...", text: $newNoteText)
                                .textFieldStyle(.roundedBorder)
                                .font(ScopeTheme.Font.footnote)
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

                    // Attachments
                    VStack(alignment: .leading, spacing: ScopeTheme.Spacing.xs) {
                        HStack {
                            Text("Attachments")
                                .font(ScopeTheme.Font.footnoteSemibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                pickImages()
                            } label: {
                                HStack(spacing: ScopeTheme.Spacing.xxxs) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Add Image")
                                        .font(ScopeTheme.Font.caption)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        // Drop zone + thumbnails
                        ZStack {
                            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                                .fill(isDropTargeted
                                      ? Color.accentColor.opacity(ScopeTheme.Opacity.hover)
                                      : ScopeTheme.Colors.controlBg.opacity(0.3))
                            RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                                .strokeBorder(
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                                )
                                .foregroundColor(isDropTargeted ? .accentColor : ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.border))

                            if attachedImages.isEmpty {
                                VStack(spacing: ScopeTheme.Spacing.xxs) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.tertiary)
                                    Text("Drop images here")
                                        .font(ScopeTheme.Font.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: ScopeTheme.Spacing.sm) {
                                        ForEach(attachedImages, id: \.self) { path in
                                            AttachmentThumbnail(path: path) {
                                                attachedImages.removeAll { $0 == path }
                                            }
                                        }
                                    }
                                    .padding(ScopeTheme.Spacing.sm)
                                }
                            }
                        }
                        .frame(height: attachedImages.isEmpty ? 60 : 80)
                        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                    }

                }
                .padding(ScopeTheme.Spacing.xl)
            }

            Divider()

            // Bottom bar
            HStack {
                Button(role: .destructive) {
                    onDelete(task)
                    dismiss()
                } label: {
                    HStack(spacing: ScopeTheme.Spacing.xxs) {
                        Image(systemName: "trash")
                            .font(ScopeTheme.Font.caption)
                        Text("Delete")
                            .font(ScopeTheme.Font.footnoteMedium)
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
            .padding(.horizontal, ScopeTheme.Spacing.xl)
            .padding(.vertical, ScopeTheme.Spacing.md)
        }
        .frame(width: 520, height: 740)
        .onAppear {
            title = task.title
            description = task.description ?? ""
            priority = task.priority
            selectedProjectId = task.projectId
            selectedLabels = Set(task.labelsArray)
            attachedImages = task.attachmentsArray
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
        updated.setAttachments(attachedImages)
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


    private func enrichWithAI() {
        enrichError = nil
        Task {
            if let result = await claudeService.enrichTask(title: title, currentDescription: description) {
                description = result
            } else {
                enrichError = claudeService.lastError ?? "Failed to enrich"
            }
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
                        .appendingPathComponent("scope-task-images", isDirectory: true)
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
                .font(ScopeTheme.Font.caption)
                .padding(.horizontal, ScopeTheme.Spacing.sm)
                .padding(.vertical, ScopeTheme.Spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? color.opacity(0.15) : ScopeTheme.Colors.controlBg.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? color.opacity(ScopeTheme.Opacity.border) : ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.border), lineWidth: 0.5)
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
                    .clipShape(RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                            .stroke(ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.border), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: ScopeTheme.Radius.small, style: .continuous)
                    .fill(ScopeTheme.Colors.controlBg)
                    .frame(width: 64, height: 64)
                    .overlay {
                        VStack(spacing: ScopeTheme.Spacing.xxxs) {
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
