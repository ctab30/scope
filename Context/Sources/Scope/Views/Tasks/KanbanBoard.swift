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

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var priority: Int = 0
    @State private var selectedLabels: Set<String> = []

    var body: some View {
        VStack(spacing: ScopeTheme.Spacing.lg) {
            Text("New Task")
                .font(ScopeTheme.Font.headline)

            VStack(alignment: .leading, spacing: ScopeTheme.Spacing.md) {
                TextField("Task title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(ScopeTheme.Font.body)

                // Description
                TextEditor(text: $description)
                    .font(ScopeTheme.Font.footnote)
                    .scrollContentBackground(.hidden)
                    .padding(ScopeTheme.Spacing.xs)
                    .frame(height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(ScopeTheme.Colors.textBg.opacity(0.3))
                    )

                // Priority
                HStack(spacing: ScopeTheme.Spacing.xxs) {
                    Text("Priority:")
                        .font(ScopeTheme.Font.footnoteMedium)
                        .foregroundColor(.secondary)
                    ForEach(TaskItem.Priority.allCases, id: \.rawValue) { level in
                        Button {
                            priority = level.rawValue
                        } label: {
                            Text(level.label)
                                .font(ScopeTheme.Font.caption)
                                .padding(.horizontal, ScopeTheme.Spacing.sm)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(priority == level.rawValue
                                              ? level.color.opacity(0.15)
                                              : Color.clear)
                                )
                                .foregroundColor(priority == level.rawValue ? level.color : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Labels
                HStack(spacing: ScopeTheme.Spacing.xxs) {
                    Text("Labels:")
                        .font(ScopeTheme.Font.footnoteMedium)
                        .foregroundColor(.secondary)
                    ForEach(TaskItem.predefinedLabels.prefix(6), id: \.self) { label in
                        Button {
                            if selectedLabels.contains(label) {
                                selectedLabels.remove(label)
                            } else {
                                selectedLabels.insert(label)
                            }
                        } label: {
                            Text(label)
                                .font(ScopeTheme.Font.tag)
                                .textCase(.uppercase)
                                .padding(.horizontal, ScopeTheme.Spacing.xs)
                                .padding(.vertical, ScopeTheme.Spacing.xxxs)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(selectedLabels.contains(label)
                                              ? TaskItem.labelColor(for: label).opacity(0.15)
                                              : ScopeTheme.Colors.separator.opacity(ScopeTheme.Opacity.badge))
                                )
                                .foregroundColor(selectedLabels.contains(label)
                                                 ? TaskItem.labelColor(for: label)
                                                 : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 400)

            HStack(spacing: ScopeTheme.Spacing.md) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                        var task = TaskItem(
                            id: nil,
                            projectId: appState.currentProject?.id ?? "__global__",
                            title: title.trimmingCharacters(in: .whitespaces),
                            description: description.isEmpty ? nil : description,
                            status: "todo",
                            priority: priority,
                            sourceSession: nil,
                            source: "manual",
                            createdAt: Date(),
                            completedAt: nil,
                            labels: nil,
                            attachments: nil
                        )
                        task.setLabels(Array(selectedLabels).sorted())
                        onCreate(task)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(ScopeTheme.Spacing.xxl)
    }
}
