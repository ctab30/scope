import SwiftUI

/// Quick-launch buttons for each supported CLI, displayed in the terminal tab bar.
/// Each button opens a dropdown with launch options and MCP/instruction setup.
struct CLIQuickLaunchView: View {
    @EnvironmentObject var appSettings: AppSettings
    let projectPath: String
    let onLaunchCLI: (_ title: String, _ command: String) -> Void

    @State private var setupResult: String?
    @State private var installCacheLoaded = false

    private let injector = ContextInjector()

    var body: some View {
        HStack(spacing: 6) {
            let _ = installCacheLoaded  // force re-evaluation after cache loads
            ForEach(CLIProvider.allCases) { cli in
                cliMenu(for: cli)
            }
        }
        .task {
            await CLIProvider.refreshInstallationStatus()
            installCacheLoaded = true
        }
        .alert("Setup", isPresented: Binding(
            get: { setupResult != nil },
            set: { if !$0 { setupResult = nil } }
        )) {
            Button("OK") { setupResult = nil }
        } message: {
            Text(setupResult ?? "")
        }
    }

    @ViewBuilder
    private func cliMenu(for cli: CLIProvider) -> some View {
        let installed = cli.isInstalled
        let isPreferred = appSettings.preferredCLI == cli

        Menu {
            if installed {
                Button("Launch \(cli.displayName)") {
                    onLaunchCLI(cli.displayName, cli.command)
                }
            }

            Divider()

            Button("Setup MCP") {
                setupMCP(for: cli)
            }

            Button("Setup Instructions") {
                setupInstructions(for: cli)
            }

            Divider()

            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
            } else {
                Label("Not installed", systemImage: "xmark.circle")
            }

            if isPreferred {
                Label("Preferred CLI", systemImage: "star.fill")
            } else {
                Button("Set as Preferred") {
                    appSettings.preferredCLI = cli
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(installed ? cli.color : .secondary.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(cli.shortName)
                    .font(ScopeTheme.Font.caption)
                    .foregroundColor(installed ? (isPreferred ? cli.color : .primary) : .secondary.opacity(0.4))

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(cli.displayName + (installed ? "" : " (not installed)"))
    }

    // MARK: - Setup Actions

    private func setupMCP(for cli: CLIProvider) {
        do {
            let path = try injector.installMCP(for: cli, projectPath: projectPath)
            setupResult = "MCP configured for \(cli.displayName) at \(path)"
        } catch {
            setupResult = "Failed: \(error.localizedDescription)"
        }
    }

    private func setupInstructions(for cli: CLIProvider) {
        do {
            try injector.updateInstructionFile(for: cli, projectPath: projectPath)
            setupResult = "\(cli.instructionFileName) updated"
        } catch {
            setupResult = "Failed: \(error.localizedDescription)"
        }
    }
}
