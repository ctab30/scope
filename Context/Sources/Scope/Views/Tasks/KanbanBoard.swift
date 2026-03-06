import SwiftUI
import GRDB
import UniformTypeIdentifiers

struct KanbanBoard: View {
    var globalMode: Bool = false
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var todoTasks: [TaskItem] = []
    @State private var inProgressTasks: [TaskItem] = []
    @State private var needsAttentionTasks: [TaskItem] = []
    @State private var doneTasks: [TaskItem] = []
    @State private var showingNewTask = false
    @State private var selectedTask: TaskItem?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Task Board")
                    .font(ScopeTheme.Font.bodySemibold)

                Spacer()

                // Task counts
                HStack(spacing: ScopeTheme.Spacing.sm) {
                    Label("\(todoTasks.count + inProgressTasks.count + needsAttentionTasks.count) open", systemImage: "circle.dotted")
                    Label("\(doneTasks.count) done", systemImage: "checkmark.circle")
                }
                .font(ScopeTheme.Font.caption)
                .foregroundColor(.secondary)

                Button {
                    showingNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, ScopeTheme.Spacing.lg)
            .padding(.vertical, ScopeTheme.Spacing.md)

            Divider()

            // Three-column Kanban with drag-and-drop
            HStack(spacing: 0) {
                KanbanColumn(
                    title: "Todo",
                    icon: "circle",
                    color: .orange,
                    status: "todo",
                    tasks: todoTasks,
                    onTapTask: { openDetail($0) },
                    onDropTask: { taskId in moveTaskById(taskId, to: "todo") },
                    projectLookup: globalMode ? projectLookup : [:],
                    onProjectBadgeTap: globalMode ? { navigateToProject($0) } : nil,
                    contextMenuItems: { task in
                        Button("Move to In Progress") { moveTask(task, to: "in_progress") }
                        Divider()
                        Button("Delete", role: .destructive) { deleteTask(task) }
                    }
                )
                Divider()
                KanbanColumn(
                    title: "In Progress",
                    icon: "circle.lefthalf.filled",
                    color: .blue,
                    status: "in_progress",
                    tasks: inProgressTasks,
                    onTapTask: { openDetail($0) },
                    onDropTask: { taskId in moveTaskById(taskId, to: "in_progress") },
                    projectLookup: globalMode ? projectLookup : [:],
                    onProjectBadgeTap: globalMode ? { navigateToProject($0) } : nil,
                    contextMenuItems: { task in
                        Button("Move to Done") { moveTask(task, to: "done") }
                        Button("Move back to Todo") { moveTask(task, to: "todo") }
                        Divider()
                        Button("Delete", role: .destructive) { deleteTask(task) }
                    }
                )
                Divider()
                KanbanColumn(
                    title: "Needs Attention",
                    icon: "exclamationmark.circle.fill",
                    color: .red,
                    status: "needs_attention",
                    tasks: needsAttentionTasks,
                    onTapTask: { openDetail($0) },
                    onDropTask: { taskId in moveTaskById(taskId, to: "needs_attention") },
                    projectLookup: globalMode ? projectLookup : [:],
                    onProjectBadgeTap: globalMode ? { navigateToProject($0) } : nil,
                    contextMenuItems: { task in
                        if globalMode {
                            Button("Open Project") { openWindow(value: task.projectId) }
                            Divider()
                        }
                        Button("Move to In Progress") { moveTask(task, to: "in_progress") }
                        Button("Move to Todo") { moveTask(task, to: "todo") }
                        Divider()
                        Button("Delete", role: .destructive) { deleteTask(task) }
                    }
                )
                Divider()
                KanbanColumn(
                    title: "Done",
                    icon: "checkmark.circle.fill",
                    color: .green,
                    status: "done",
                    tasks: doneTasks,
                    onTapTask: { openDetail($0) },
                    onDropTask: { taskId in moveTaskById(taskId, to: "done") },
                    projectLookup: globalMode ? projectLookup : [:],
                    onProjectBadgeTap: globalMode ? { navigateToProject($0) } : nil,
                    contextMenuItems: { task in
                        Button("Move back to In Progress") { moveTask(task, to: "in_progress") }
                        Divider()
                        Button("Delete", role: .destructive) { deleteTask(task) }
                    }
                )
            }
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskSheet(isPresented: $showingNewTask, onCreate: { task in
                createTask(task)
            })
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailView(
                task: task,
                onSave: { updated in
                    saveTask(updated)
                },
                onDelete: { task in
                    deleteTask(task)
                },
                onDismiss: {
                    selectedTask = nil
                }
            )
        }
        .onAppear { loadTasks() }
        .onChange(of: appState.currentProject) { _, _ in loadTasks() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            loadTasks()
        }
    }

    // MARK: - Project Lookup (for global mode badges)

    private var projectLookup: [String: String] {
        Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0.name) })
    }

    private func navigateToProject(_ projectId: String) {
        guard let project = appState.projects.first(where: { $0.id == projectId }) else { return }
        appState.selectedTab = .tasks
        appState.selectProject(project)
    }

    // MARK: - Actions

    private func openDetail(_ task: TaskItem) {
        selectedTask = task
    }

    private func loadTasks() {
        do {
            let allTasks: [TaskItem]
            if globalMode {
                allTasks = try DatabaseService.shared.dbQueue.read { db in
                    try TaskItem
                        .order(Column("priority").desc, Column("createdAt").desc)
                        .fetchAll(db)
                }
            } else {
                guard let project = appState.currentProject else {
                    todoTasks = []; inProgressTasks = []; needsAttentionTasks = []; doneTasks = []
                    return
                }
                allTasks = try DatabaseService.shared.dbQueue.read { db in
                    try TaskItem
                        .filter(Column("projectId") == project.id)
                        .order(Column("priority").desc, Column("createdAt").desc)
                        .fetchAll(db)
                }
            }
            todoTasks = allTasks.filter { $0.status == "todo" }
            inProgressTasks = allTasks.filter { $0.status == "in_progress" }
            needsAttentionTasks = allTasks.filter { $0.status == "needs_attention" }
            doneTasks = allTasks.filter { $0.status == "done" }
        } catch {
            print("KanbanBoard: failed to load tasks: \(error)")
        }
    }

    private func moveTask(_ task: TaskItem, to newStatus: String) {
        var updated = task
        updated.status = newStatus
        if newStatus == "done" {
            updated.completedAt = Date()
        } else {
            updated.completedAt = nil
        }
        saveTask(updated)
    }

    private func moveTaskById(_ taskId: Int64, to newStatus: String) {
        let allTasks = todoTasks + inProgressTasks + needsAttentionTasks + doneTasks
        guard let task = allTasks.first(where: { $0.id == taskId }) else { return }
        moveTask(task, to: newStatus)
    }

    private func createTask(_ task: TaskItem) {
        var newTask = task
        if globalMode {
            newTask.isGlobal = true
        }
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try newTask.insert(db)
            }
            loadTasks()
            NotificationCenter.default.post(name: .tasksDidChange, object: nil)
        } catch {
            print("KanbanBoard: failed to create task: \(error)")
        }
    }

    private func saveTask(_ task: TaskItem) {
        do {
            try DatabaseService.shared.dbQueue.write { db in
                try task.update(db)
            }
            loadTasks()
            NotificationCenter.default.post(name: .tasksDidChange, object: nil)
        } catch {
            print("KanbanBoard: failed to save task: \(error)")
        }
    }

    private func deleteTask(_ task: TaskItem) {
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in
                try task.delete(db)
            }
            loadTasks()
            NotificationCenter.default.post(name: .tasksDidChange, object: nil)
        } catch {
            print("KanbanBoard: failed to delete task: \(error)")
        }
    }

}

// MARK: - Kanban Column (with drop target)

struct KanbanColumn<MenuContent: View>: View {
    let title: String
    let icon: String
    let color: Color
    let status: String
    let tasks: [TaskItem]
    let onTapTask: (TaskItem) -> Void
    let onDropTask: (Int64) -> Void
    var projectLookup: [String: String] = [:]
    var onProjectBadgeTap: ((String) -> Void)? = nil
    @ViewBuilder let contextMenuItems: (TaskItem) -> MenuContent

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: ScopeTheme.Spacing.xs) {
                Rectangle()
                    .fill(color)
                    .frame(width: 3, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                Text(title)
                    .font(ScopeTheme.Font.footnoteSemibold)
                    .lineLimit(1)
                Spacer()
                Text("\(tasks.count)")
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, ScopeTheme.Spacing.sm)
            .padding(.vertical, ScopeTheme.Spacing.sm)

            Divider()

            // Task list (drop target)
            ScrollView {
                if tasks.isEmpty {
                    Text("No tasks")
                        .font(ScopeTheme.Font.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ScopeTheme.Spacing.xl)
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(tasks) { task in
                            TaskCardView(
                                task: task,
                                projectName: task.projectId != "__global__" ? projectLookup[task.projectId] : nil,
                                onProjectTap: task.projectId != "__global__" ? { onProjectBadgeTap?(task.projectId) } : nil
                            ) {
                                onTapTask(task)
                            }
                            .onDrag {
                                NSItemProvider(object: "\(task.id ?? 0)" as NSString)
                            }
                            .contextMenu {
                                contextMenuItems(task)
                            }
                        }
                    }
                    .padding(.vertical, ScopeTheme.Spacing.xxs)
                }
            }
            .frame(maxHeight: .infinity)
            .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let idString = item as? String,
                          let taskId = Int64(idString) else { return }
                    DispatchQueue.main.async {
                        onDropTask(taskId)
                    }
                }
                return true
            }
        }
        .background(isDropTargeted ? color.opacity(0.04) : Color.clear)
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }
}

// MARK: - New Task Sheet (Rich)

struct NewTaskSheet: View {
    @Binding var isPresented: Bool
    let onCreate: (TaskItem) -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var priority: Int = 0
    @State private var selectedLabels: Set<String> = []
    @State private var customLabel: String = ""
    @State private var selectedProjectId: String = ""
    @State private var attachedImages: [String] = []
    @State private var isDropTargeted = false
    private let selectedStatus: String = "todo"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Task")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                        TextField("What needs to be done?", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Project
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Project")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                        Picker("Project", selection: $selectedProjectId) {
                            ForEach(appState.projects.filter { $0.id != "__global__" }) { project in
                                Text(settings.demoMode ? DemoContent.shared.mask(project.name, as: .project) : project.name)
                                    .tag(project.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                        TextEditor(text: $description)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 100)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 0.5)
                            )
                    }

                    // Priority
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority")
                            .font(.subheadline.weight(.medium))
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Labels")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)

                        FlowLayout(spacing: 6) {
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

                        // Custom label
                        HStack(spacing: 8) {
                            TextField("Custom label", text: $customLabel)
                                .textFieldStyle(.roundedBorder)
                                .font(.footnote)
                                .frame(width: 150)
                                .onSubmit { addCustomLabel() }

                            Button("Add") { addCustomLabel() }
                                .font(.footnote)
                                .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        // Custom selected labels
                        let customSelected = selectedLabels.filter { !TaskItem.predefinedLabels.contains($0) }
                        if !customSelected.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(Array(customSelected).sorted(), id: \.self) { label in
                                    LabelChip(label: label, isSelected: true, color: .secondary) {
                                        selectedLabels.remove(label)
                                    }
                                }
                            }
                        }
                    }

                    // Attachments
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Attachments")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                pickImages()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Add Image")
                                        .font(.caption)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isDropTargeted
                                      ? Color.accentColor.opacity(0.1)
                                      : Color.secondary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                                )
                                .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.3))

                            if attachedImages.isEmpty {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.tertiary)
                                    Text("Drop images here")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(attachedImages, id: \.self) { path in
                                            AttachmentThumbnail(path: path) {
                                                attachedImages.removeAll { $0 == path }
                                            }
                                        }
                                    }
                                    .padding(8)
                                }
                            }
                        }
                        .frame(height: attachedImages.isEmpty ? 60 : 80)
                        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Bottom bar
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Button("Create Task") {
                    createTask()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 720)
        .onAppear {
            selectedProjectId = appState.currentProject?.id ?? appState.projects.first?.id ?? "__global__"
        }
    }

    private func createTask() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var task = TaskItem(
            id: nil,
            projectId: selectedProjectId,
            title: title.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            status: selectedStatus,
            priority: priority,
            sourceSession: nil,
            source: "manual",
            createdAt: Date(),
            completedAt: nil,
            labels: nil,
            attachments: nil
        )
        task.setLabels(Array(selectedLabels).sorted())
        if !attachedImages.isEmpty {
            task.setAttachments(attachedImages)
        }
        onCreate(task)
        isPresented = false
    }

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

    private func addCustomLabel() {
        let label = customLabel.trimmingCharacters(in: .whitespaces).lowercased()
        if !label.isEmpty {
            selectedLabels.insert(label)
            customLabel = ""
        }
    }
}
