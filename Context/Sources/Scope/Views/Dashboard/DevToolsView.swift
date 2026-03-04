import SwiftUI

/// Shows detected project type, available dev commands, and active local server ports.
///
/// Commands launch in new terminal tabs via the `.launchTask` notification.
/// Ports are polled every 5 seconds and shown with their process names.
struct DevToolsView: View {
    @EnvironmentObject var devEnv: DevEnvironment
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: devEnv.projectType.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(devEnv.projectType.color)

                Text("Dev Tools")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Text(devEnv.projectType.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(devEnv.projectType.color)

                Spacer()

                // Active port count
                if !devEnv.activePorts.isEmpty {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("\(devEnv.activePorts.count) port\(devEnv.activePorts.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                // Commands
                if !devEnv.commands.isEmpty {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ], spacing: 8) {
                        ForEach(devEnv.commands) { cmd in
                            DevCommandButton(command: cmd) {
                                launchCommand(cmd)
                            }
                        }
                    }
                }

                // Active ports
                if !devEnv.activePorts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Active Servers", systemImage: "network")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)

                        ForEach(devEnv.activePorts) { port in
                            PortRow(port: port)
                        }
                    }
                }
            }
        }
        .padding(ScopeTheme.Spacing.lg)
    }

    private func launchCommand(_ cmd: DevCommand) {
        NotificationCenter.default.post(
            name: .launchTask,
            object: nil,
            userInfo: [
                LaunchTaskKey.title: cmd.title,
                LaunchTaskKey.command: cmd.command,
                LaunchTaskKey.projectId: appState.currentProject?.id ?? ""
            ]
        )
    }
}

// MARK: - Dev Command Button

struct DevCommandButton: View {
    let command: DevCommand
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: command.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(command.color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(command.subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary.opacity(isHovering ? 0.8 : 0.3))
            }
            .padding(.horizontal, ScopeTheme.Spacing.sm)
            .padding(.vertical, ScopeTheme.Spacing.xs)
            .background(isHovering ? command.color.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Port Row

struct PortRow: View {
    let port: ActivePort
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)

            Text(":\(port.port)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)

            Text(port.processName)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer()

            // Open in browser
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "safari")
                        .font(.system(size: 9))
                    Text("Open")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(isHovering ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ScopeTheme.Spacing.sm)
        .padding(.vertical, ScopeTheme.Spacing.xs)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
