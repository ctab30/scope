import SwiftUI

struct VisualizerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var analyzer: ProjectAnalyzer

    enum VisTab: String, CaseIterable {
        case architecture = "Architecture"
        case schema = "Schema"
        case files = "Files"
        case git = "Git History"

        var icon: String {
            switch self {
            case .architecture: return "arrow.triangle.branch"
            case .schema: return "tablecells"
            case .files: return "square.grid.2x2"
            case .git: return "clock.arrow.2.circlepath"
            }
        }
    }

    @State private var selectedTab: VisTab = .architecture

    var body: some View {
        VStack(spacing: 0) {
            // Sub-tab bar
            HStack(spacing: 2) {
                ForEach(VisTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedTab == tab
                                      ? Color.accentColor.opacity(0.15)
                                      : Color.clear)
                        )
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // Rescan button
                Button {
                    if let path = appState.currentProject?.path {
                        analyzer.scan(projectPath: path)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Rescan")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(analyzer.isScanning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Content
            if analyzer.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scanning project...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.currentProject == nil {
                emptyState(icon: "folder.badge.questionmark", message: "Select a project to visualize")
            } else {
                Group {
                    switch selectedTab {
                    case .architecture:
                        ArchitectureMapView()
                    case .schema:
                        SchemaView()
                    case .files:
                        FileHeatmapView()
                    case .git:
                        GitGraphView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let path = appState.currentProject?.path, analyzer.archNodes.isEmpty {
                analyzer.scan(projectPath: path)
            }
        }
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
