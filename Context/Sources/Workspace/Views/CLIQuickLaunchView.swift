import SwiftUI

/// Quick-launch button for Claude Code, displayed in the terminal tab bar.
/// Provides launch modes: normal, dangermode, resume, and continue.
struct CLIQuickLaunchView: View {
    let projectPath: String
    let onLaunchCLI: (_ title: String, _ command: String) -> Void

    @State private var installCheckVersion = 0

    var body: some View {
        HStack(spacing: 6) {
            let _ = installCheckVersion
            claudeMenu
        }
        .task(id: installCheckVersion) {
            await CLIProvider.refreshInstallationStatus()
            // If not installed, re-check periodically in case user installs it
            if !CLIProvider.claude.isInstalled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                if !Task.isCancelled {
                    installCheckVersion += 1
                }
            }
        }
    }

    @ViewBuilder
    private var claudeMenu: some View {
        let installed = CLIProvider.claude.isInstalled

        Menu {
            if installed {
                Button {
                    onLaunchCLI("Claude Code", "claude")
                } label: {
                    Label("New Session", systemImage: "plus.message")
                }

                Button {
                    onLaunchCLI("Claude (Resume)", "claude --resume")
                } label: {
                    Label("Resume Last Session", systemImage: "arrow.uturn.backward")
                }

                Button {
                    onLaunchCLI("Claude (Continue)", "claude --continue")
                } label: {
                    Label("Continue Last Session", systemImage: "arrow.forward")
                }

                Divider()

                Button {
                    onLaunchCLI("Claude (Dangermode)", "claude --dangerously-skip-permissions")
                } label: {
                    Label("Dangermode", systemImage: "bolt.shield")
                }

                Button {
                    onLaunchCLI("Claude (Verbose)", "claude --verbose")
                } label: {
                    Label("Verbose", systemImage: "text.alignleft")
                }
            } else {
                Label("Claude Code not installed", systemImage: "xmark.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(installed ? Color.white : .secondary.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text("Claude")
                    .font(WorkspaceTheme.Font.caption)
                    .foregroundColor(installed ? .white : .secondary.opacity(0.4))

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Claude Code" + (installed ? "" : " (not installed)"))
    }
}
