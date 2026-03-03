import SwiftUI

/// Compact status bar showing active Claude Code agents for the current terminal.
///
/// Sits between the tab bar and terminal content. Hidden when no Claude process
/// is detected. Shows agent count, elapsed times, and frozen warnings.
struct AgentStatusBar: View {
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        if monitor.claudeProcess != nil {
            HStack(spacing: 0) {
                // Claude process indicator
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Claude Code")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    if let claude = monitor.claudeProcess {
                        Text(claude.formattedElapsed)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !monitor.agents.isEmpty {
                    Divider()
                        .frame(height: 12)
                        .padding(.horizontal, 8)

                    // Agent pills
                    HStack(spacing: 4) {
                        ForEach(monitor.agents) { agent in
                            AgentPill(agent: agent)
                        }
                    }

                    // Frozen warning
                    if monitor.agents.contains(where: { $0.isPotentiallyFrozen }) {
                        Divider()
                            .frame(height: 12)
                            .padding(.horizontal, 6)

                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                            Text("Agent may be frozen")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    .frame(height: 0.5)
            }
        }
    }
}

/// A compact pill showing a single agent's status.
struct AgentPill: View {
    let agent: AgentMonitor.AgentInfo

    private var statusColor: Color {
        agent.isPotentiallyFrozen ? .orange : .blue
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text("Agent")
                .font(.system(size: 9, weight: .semibold))
            Text(agent.formattedElapsed)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.1))
                .overlay(
                    Capsule()
                        .strokeBorder(statusColor.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}
