import SwiftUI

struct SchemaView: View {
    @EnvironmentObject var analyzer: ProjectAnalyzer

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var selectedTable: String?

    var body: some View {
        if analyzer.schemaTables.isEmpty {
            emptyState
        } else {
            ZStack {
                // Relationship lines (Canvas behind the cards)
                Canvas { context, size in
                    for table in analyzer.schemaTables {
                        for column in table.columns where column.isForeignKey {
                            guard let ref = column.references,
                                  let targetTable = analyzer.schemaTables.first(where: { $0.name == ref }) else { continue }

                            let fromPoint = CGPoint(
                                x: table.position.x + 120,
                                y: table.position.y + 50
                            )
                            let toPoint = CGPoint(
                                x: targetTable.position.x + 120,
                                y: targetTable.position.y + 30
                            )

                            var path = Path()
                            path.move(to: fromPoint)

                            // Bezier curve for nicer lines
                            let midX = (fromPoint.x + toPoint.x) / 2
                            path.addCurve(
                                to: toPoint,
                                control1: CGPoint(x: midX, y: fromPoint.y),
                                control2: CGPoint(x: midX, y: toPoint.y)
                            )

                            let isHighlighted = selectedTable == table.id || selectedTable == ref
                            context.stroke(
                                path,
                                with: .color(isHighlighted ? .accentColor : Color.secondary.opacity(0.3)),
                                style: StrokeStyle(lineWidth: isHighlighted ? 2 : 1, dash: [4, 3])
                            )

                            // Arrow dot at target
                            let dotRect = CGRect(x: toPoint.x - 3, y: toPoint.y - 3, width: 6, height: 6)
                            context.fill(
                                Path(ellipseIn: dotRect),
                                with: .color(isHighlighted ? .accentColor : .secondary.opacity(0.4))
                            )
                        }
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)

                // Table cards
                ForEach(analyzer.schemaTables) { table in
                    tableCard(table)
                        .position(x: table.position.x + 120, y: table.position.y + 30)
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(dragGesture)
            .gesture(magnifyGesture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipped()
        }
    }

    // MARK: - Table Card

    private func tableCard(_ table: SchemaTable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Table name header
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .font(.system(size: 10, weight: .semibold))
                Text(table.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                Text("\(table.columns.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selectedTable == table.id
                    ? Color.accentColor.opacity(0.15)
                    : Color(nsColor: .controlAccentColor).opacity(0.08)
            )

            Divider()

            // Columns
            VStack(alignment: .leading, spacing: 0) {
                ForEach(table.columns) { column in
                    HStack(spacing: 6) {
                        // Key indicator
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.yellow)
                        } else if column.isForeignKey {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8))
                                .foregroundColor(.purple)
                        } else {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 8)
                        }

                        Text(column.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Spacer()

                        Text(column.type)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedTable == table.id
                        ? Color.accentColor.opacity(0.5)
                        : Color(nsColor: .separatorColor).opacity(0.4),
                        lineWidth: selectedTable == table.id ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .onTapGesture {
            selectedTable = selectedTable == table.id ? nil : table.id
        }
    }

    // MARK: - Helpers

    private var canvasSize: CGSize {
        guard !analyzer.schemaTables.isEmpty else { return CGSize(width: 600, height: 400) }
        let maxX = analyzer.schemaTables.map { $0.position.x }.max() ?? 600
        let maxY = analyzer.schemaTables.map { $0.position.y }.max() ?? 400
        return CGSize(width: maxX + 300, height: maxY + 300)
    }

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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tablecells")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No database schema found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Supports Prisma, SQL, GRDB (Swift), and Django models")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
