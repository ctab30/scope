import SwiftUI

struct ArchitectureMapView: View {
    @EnvironmentObject var analyzer: ProjectAnalyzer

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var hoveredNode: String?
    @State private var selectedNode: String?

    private let typeColors: [String: Color] = [
        "swift": .orange,
        "ts": .blue, "tsx": .blue,
        "js": .yellow, "jsx": .yellow,
        "dart": .cyan,
        "py": .green,
        "rs": .red,
        "go": .teal,
    ]

    var body: some View {
        if analyzer.archNodes.isEmpty {
            emptyState
        } else {
            ZStack {
                graphCanvas
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(dragGesture)
                    .gesture(magnifyGesture)
                    .onTapGesture {
                        selectedNode = nil
                    }

                // Legend + stats overlay
                VStack {
                    HStack {
                        legend
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        stats
                    }
                }
                .padding(12)

                // Selected node detail
                if let nodeId = selectedNode,
                   let node = analyzer.archNodes.first(where: { $0.id == nodeId }) {
                    VStack {
                        Spacer()
                        HStack {
                            nodeDetail(node)
                            Spacer()
                        }
                    }
                    .padding(12)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipped()
        }
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        Canvas { context, size in
            // Draw edges
            for edge in analyzer.archEdges {
                guard let fromNode = analyzer.archNodes.first(where: { $0.id == edge.from }),
                      let toNode = analyzer.archNodes.first(where: { $0.id == edge.to }) else { continue }

                var path = Path()
                path.move(to: fromNode.position)
                path.addLine(to: toNode.position)

                let isHighlighted = selectedNode == edge.from || selectedNode == edge.to
                context.stroke(
                    path,
                    with: .color(isHighlighted ? .accentColor.opacity(0.6) : Color.secondary.opacity(0.15)),
                    lineWidth: isHighlighted ? 1.5 : 0.5
                )

                // Arrow head
                let dx = toNode.position.x - fromNode.position.x
                let dy = toNode.position.y - fromNode.position.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist > 20 {
                    let unitX = dx / dist
                    let unitY = dy / dist
                    let arrowTip = CGPoint(
                        x: toNode.position.x - unitX * 8,
                        y: toNode.position.y - unitY * 8
                    )
                    let arrowSize: CGFloat = 4
                    let perpX = -unitY * arrowSize
                    let perpY = unitX * arrowSize

                    var arrowPath = Path()
                    arrowPath.move(to: arrowTip)
                    arrowPath.addLine(to: CGPoint(x: arrowTip.x - unitX * arrowSize * 2 + perpX, y: arrowTip.y - unitY * arrowSize * 2 + perpY))
                    arrowPath.addLine(to: CGPoint(x: arrowTip.x - unitX * arrowSize * 2 - perpX, y: arrowTip.y - unitY * arrowSize * 2 - perpY))
                    arrowPath.closeSubpath()

                    context.fill(arrowPath, with: .color(isHighlighted ? .accentColor.opacity(0.6) : Color.secondary.opacity(0.2)))
                }
            }

            // Draw nodes
            for node in analyzer.archNodes {
                let isSelected = selectedNode == node.id
                let isHovered = hoveredNode == node.id
                let nodeColor = typeColors[node.fileType] ?? .gray
                let radius: CGFloat = isSelected ? 8 : (isHovered ? 7 : 5)

                let nodeRect = CGRect(
                    x: node.position.x - radius,
                    y: node.position.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                // Glow for selected
                if isSelected {
                    let glowRect = nodeRect.insetBy(dx: -4, dy: -4)
                    context.fill(
                        Path(ellipseIn: glowRect),
                        with: .color(nodeColor.opacity(0.2))
                    )
                }

                context.fill(
                    Path(ellipseIn: nodeRect),
                    with: .color(nodeColor)
                )

                // Label for hovered/selected
                if isSelected || isHovered {
                    let text = Text(node.name)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                    context.draw(
                        text,
                        at: CGPoint(x: node.position.x, y: node.position.y - radius - 8),
                        anchor: .bottom
                    )
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let adjustedLocation = CGPoint(
                    x: (location.x - offset.width) / scale,
                    y: (location.y - offset.height) / scale
                )
                hoveredNode = analyzer.archNodes.first(where: { node in
                    let dx = node.position.x - adjustedLocation.x
                    let dy = node.position.y - adjustedLocation.y
                    return sqrt(dx * dx + dy * dy) < 12
                })?.id
            case .ended:
                hoveredNode = nil
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                if let hovered = hoveredNode {
                    selectedNode = selectedNode == hovered ? nil : hovered
                }
            }
        )
    }

    private var canvasSize: CGSize {
        guard !analyzer.archNodes.isEmpty else { return CGSize(width: 600, height: 600) }
        let maxX = analyzer.archNodes.map { $0.position.x }.max() ?? 600
        let maxY = analyzer.archNodes.map { $0.position.y }.max() ?? 600
        return CGSize(width: maxX + 80, height: maxY + 80)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(0.3, min(3.0, value.magnification))
            }
    }

    // MARK: - Overlays

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File Types")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            let activeTypes = Set(analyzer.archNodes.map { $0.fileType })
            ForEach(Array(activeTypes).sorted(), id: \.self) { type in
                HStack(spacing: 4) {
                    Circle()
                        .fill(typeColors[type] ?? .gray)
                        .frame(width: 8, height: 8)
                    Text(".\(type)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.8))
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
    }

    private var stats: some View {
        HStack(spacing: 12) {
            Label("\(analyzer.archNodes.count) files", systemImage: "doc")
            Label("\(analyzer.archEdges.count) imports", systemImage: "arrow.right")
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
    }

    private func nodeDetail(_ node: ArchNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.name)
                .font(.system(size: 12, weight: .bold, design: .monospaced))

            Text(node.directory)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            if !node.imports.isEmpty {
                Text("Imports (\(node.imports.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                ForEach(node.imports.prefix(8), id: \.self) { imp in
                    Text(imp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
                if node.imports.count > 8 {
                    Text("+\(node.imports.count - 8) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
        .frame(maxWidth: 260)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No source files found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Architecture map shows import relationships between source files")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
