import SwiftUI
import GRDB

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showSetupWizard = false

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, showSetupWizard: $showSetupWizard)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            TerminalSettingsTab(settings: settings)
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }

            ContextEngineSettingsTab(settings: settings)
                .tabItem {
                    Label("AI Engine", systemImage: "brain")
                }

            BrowserSettingsTab(settings: settings)
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }
        }
        .frame(width: 500, height: 550)
        .sheet(isPresented: $showSetupWizard) {
            MCPSetupView()
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @Binding var showSetupWizard: Bool
    @StateObject private var updateService = UpdateService.shared

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
                TextField("GitHub repo (owner/repo)", text: $settings.githubRepo)
                    .textFieldStyle(.roundedBorder)
                    .font(WorkspaceTheme.Font.footnote)
                Text("e.g. ctab30/scope")
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundStyle(.tertiary)

                HStack {
                    Button("Check Now") {
                        let parts = settings.githubRepo.split(separator: "/")
                        guard parts.count == 2 else { return }
                        Task {
                            await updateService.checkForUpdate(
                                owner: String(parts[0]),
                                repo: String(parts[1])
                            )
                        }
                    }
                    .disabled(settings.githubRepo.split(separator: "/").count != 2)

                    if updateService.updateAvailable, let version = updateService.latestVersion {
                        Text("v\(version) available")
                            .font(WorkspaceTheme.Font.footnoteMedium)
                            .foregroundColor(.green)
                    }
                }

                if updateService.updateAvailable {
                    Button("Download & Install") {
                        let parts = settings.githubRepo.split(separator: "/")
                        guard parts.count == 2 else { return }
                        Task {
                            await updateService.downloadAndInstall(
                                owner: String(parts[0]),
                                repo: String(parts[1])
                            )
                        }
                    }
                    .disabled(updateService.isDownloading)

                    if updateService.isDownloading {
                        ProgressView(value: updateService.downloadProgress)
                            .progressViewStyle(.linear)
                    }
                }

                if let error = updateService.error {
                    Text(error)
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundColor(.red)
                }
            }

            Section("Notifications") {
                Toggle("Notify when Claude finishes", isOn: $settings.notifyOnClaudeDone)
            }

            Section("Demo Mode") {
                Toggle("Enable demo mode", isOn: $settings.demoMode)
                Text("Replaces all client names, project names, and task titles with dummy data for clean screenshots. The database is never modified.")
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Claude Code MCP") {
                Button("Run Setup Wizard") {
                    showSetupWizard = true
                }
                Text("Re-run the MCP onboarding wizard to detect and connect Claude Code.")
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Terminal Tab

private struct TerminalSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Font Size: \(Int(settings.terminalFontSize))pt")
                    Slider(
                        value: $settings.terminalFontSize,
                        in: 10...24,
                        step: 1
                    )
                }
            }

            Section("Scrollback") {
                Stepper(
                    "Scrollback Lines: \(settings.scrollbackLines)",
                    value: $settings.scrollbackLines,
                    in: 1000...100000,
                    step: 1000
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - AI Engine Tab

private struct ContextEngineSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject var contextEngine: ContextEngine

    var body: some View {
        Form {
            Section("Code Search") {
                Toggle("Enable context search", isOn: $settings.contextSearchEnabled)

                Picker("Embedding Model", selection: $settings.embeddingModel) {
                    Text("text-embedding-3-small").tag("openai/text-embedding-3-small")
                    Text("text-embedding-3-large").tag("openai/text-embedding-3-large")
                }

                HStack {
                    Text("Index Status:")
                        .font(WorkspaceTheme.Font.footnote)
                    Text(contextEngine.indexStatus.capitalized)
                        .font(WorkspaceTheme.Font.footnoteMedium)
                        .foregroundColor(statusColor)
                    if contextEngine.isIndexing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }

                if contextEngine.totalChunks > 0 {
                    Text("\(contextEngine.totalChunks) chunks indexed")
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = contextEngine.lastError {
                    Text(error)
                        .font(WorkspaceTheme.Font.footnote)
                        .foregroundColor(.red)
                }

                HStack {
                    Button("Rebuild Index") { contextEngine.rebuildIndex() }
                        .disabled(contextEngine.isIndexing)
                    Button("Clear Index") { Task { await contextEngine.clearIndex() } }
                        .disabled(contextEngine.isIndexing)
                }
            }

            Section("Automation") {
                Toggle("Auto-snapshot sessions", isOn: $settings.autoSnapshotSessions)
                Toggle("Auto-update codebase tree", isOn: $settings.autoUpdateCodebaseTree)
                Toggle("MCP server auto-start", isOn: $settings.mcpServerAutoStart)
                Toggle("Instruction file injection", isOn: $settings.instructionInjection)

                HStack {
                    Text("Snapshot debounce: \(Int(settings.snapshotDebounce))s")
                    Slider(
                        value: $settings.snapshotDebounce,
                        in: 5...120,
                        step: 5
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statusColor: Color {
        switch contextEngine.indexStatus {
        case "ready": return .green
        case "indexing": return .white
        case "error": return .red
        default: return .secondary
        }
    }
}

// MARK: - Browser Tab

private struct BrowserSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var newDomain: String = ""

    var body: some View {
        Form {
            Section("Domain Allowlist") {
                Text("When non-empty, the browser MCP tools can only navigate to these domains. Localhost and 127.0.0.1 are always allowed.")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundStyle(.tertiary)

                ForEach(Array(settings.browserAllowedDomains.enumerated()), id: \.offset) { index, domain in
                    HStack {
                        Text(domain)
                            .font(WorkspaceTheme.Font.mono)
                        Spacer()
                        Button {
                            settings.browserAllowedDomains.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: WorkspaceTheme.Spacing.xs) {
                    TextField("example.com or *.example.com", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .font(WorkspaceTheme.Font.footnote)
                        .onSubmit { addDomain() }

                    Button("Add") { addDomain() }
                        .font(WorkspaceTheme.Font.footnote)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if settings.browserAllowedDomains.isEmpty {
                    HStack(spacing: WorkspaceTheme.Spacing.xxs) {
                        Image(systemName: "info.circle")
                            .font(WorkspaceTheme.Font.caption)
                        Text("Empty list = all domains allowed")
                            .font(WorkspaceTheme.Font.footnote)
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Section("Network Capture") {
                Picker("Response body limit", selection: $settings.networkBodyLimit) {
                    Text("2 KB").tag(2048)
                    Text("10 KB").tag(10240)
                    Text("50 KB (default)").tag(51200)
                    Text("100 KB").tag(102400)
                }
                Text("Larger limits capture more of each response body in the Network tab but use more memory.")
                    .font(WorkspaceTheme.Font.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !settings.browserAllowedDomains.contains(domain) else { return }
        settings.browserAllowedDomains.append(domain)
        newDomain = ""
    }
}
