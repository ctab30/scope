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

                // Project type badge
                Text(devEnv.projectType.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(devEnv.projectType.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(devEnv.projectType.color.opacity(0.12))
                    )

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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovering
                          ? command.color.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isHovering
                            ? command.color.opacity(0.3)
                            : Color(nsColor: .separatorColor).opacity(0.3),
                            lineWidth: 0.5)
            )
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
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
