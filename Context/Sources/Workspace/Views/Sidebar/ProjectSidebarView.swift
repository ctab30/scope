import SwiftUI
import AppKit

// MARK: - ProjectSidebarView

struct ProjectSidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showingNewClient = false
    @State private var newClientName = ""
    @State private var newClientColor = Client.defaultColors[0]
    @State private var editingTagProjectId: String? = nil
    @State private var editingTagText = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                // "Projects" header row
                Section {
                    Button {
                        appState.selectHome()
                    } label: {
                        Text("Projects")
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }

                // Client groups
                ForEach(appState.projectsByClient, id: \.client?.id) { group in
                    if let client = group.client {
                        Section {
                            ForEach(group.projects) { project in
                                projectRow(project: project)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hex: client.color) ?? .blue)
                                    .frame(width: 8, height: 8)
                                Text(settings.demoMode ? DemoContent.shared.mask(client.name, as: .client) : client.name)
                            }
                            .contextMenu {
                                Button("Rename...") { /* TODO: inline rename */ }
                                Button("Delete", role: .destructive) {
                                    appState.deleteClient(client)
                                }
                            }
                        }
                    } else {
                        Section("Ungrouped") {
                            ForEach(group.projects) { project in
                                projectRow(project: project)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom actions
            HStack(spacing: 0) {
                Button {
                    openFolderPicker()
                } label: {
                    Text("Add")
                        .font(.footnote.weight(.medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(height: 16)

                Button {
                    showingNewClient = true
                } label: {
                    Text("Group")
                        .font(.footnote.weight(.medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingNewClient) {
            NewClientSheet(
                isPresented: $showingNewClient,
                name: $newClientName,
                color: $newClientColor,
                onCreate: {
                    appState.createClient(name: newClientName, color: newClientColor)
                    newClientName = ""
                    newClientColor = Client.defaultColors[0]
                }
            )
        }
    }

    // MARK: - Open Folder

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            appState.addProjectFromFolder(url)
            if let project = appState.projects.first(where: { $0.path == path }) {
                appState.selectHome()
                openWindow(value: project.id)
            }
        }
    }

    // MARK: - Project Row

    @ViewBuilder
    private func projectRow(project: Project) -> some View {
        Button {
            openWindow(value: project.id)
        } label: {
            Label {
                HStack {
                    Text(settings.demoMode ? DemoContent.shared.mask(project.name, as: .project) : project.name)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let tag = project.tagsArray.first {
                        Spacer()
                        Text(settings.demoMode ? DemoContent.shared.mask(tag, as: .project) : tag)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "folder.fill")
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { editingTagProjectId == project.id },
            set: { if !$0 { editingTagProjectId = nil } }
        )) {
            VStack(spacing: 8) {
                Text("Project Tag")
                    .font(.headline)
                TextField("e.g. main, api, web", text: $editingTagText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { saveTag(for: project) }
                HStack(spacing: 8) {
                    if !project.tagsArray.isEmpty {
                        Button("Clear") {
                            editingTagText = ""
                            saveTag(for: project)
                        }
                        .font(.footnote)
                    }
                    Spacer()
                    Button("Cancel") { editingTagProjectId = nil }
                        .font(.footnote)
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { saveTag(for: project) }
                        .font(.footnote)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .contextMenu {
            Button("Set Tag...") {
                editingTagText = project.tagsArray.first ?? ""
                editingTagProjectId = project.id
            }
            Menu("Set Group") {
                Button("None") {
                    appState.updateProjectClient(project, clientId: nil)
                }
                Divider()
                ForEach(appState.clients) { client in
                    Button(client.name) {
                        appState.updateProjectClient(project, clientId: client.id)
                    }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }
            Divider()
            Button("Remove Project", role: .destructive) {
                appState.removeProject(project)
            }
        }
    }

    private func saveTag(for project: Project) {
        let tag = editingTagText.trimmingCharacters(in: .whitespaces)
        appState.updateProjectTag(project, tag: tag.isEmpty ? nil : tag)
        editingTagProjectId = nil
    }
}

// MARK: - NewClientSheet

struct NewClientSheet: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var color: String
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Group")
                .font(.headline)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack(spacing: 6) {
                ForEach(Client.defaultColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: color == hex ? 2 : 0)
                        )
                        .shadow(color: color == hex ? .accentColor.opacity(0.4) : .clear, radius: 3)
                        .onTapGesture { color = hex }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        onCreate()
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}

// MARK: - Color Hex Extension

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6,
              let val = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8) & 0xFF) / 255,
            blue: Double(val & 0xFF) / 255
        )
    }
}
