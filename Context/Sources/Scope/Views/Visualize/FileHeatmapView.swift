import SwiftUI

struct FileHeatmapView: View {
    @EnvironmentObject var analyzer: ProjectAnalyzer

    @State private var hoveredFile: String?
    @State private var containerSize: CGSize = .zero

    private let typeColors: [String: Color] = [
        "swift": .orange,
        "ts": .blue, "tsx": .blue,
        "js": .yellow, "jsx": .yellow,
        "dart": .cyan,
        "py": .green,
        "rs": .red,
        "go": .teal,
        "json": .purple,
        "yaml": .gray, "yml": .gray,
        "md": .mint,
        "css": .pink, "scss": .pink,
        "html": .indigo,
    ]

    var body: some View {
        if analyzer.fileNodes.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                // Legend
                HStack(spacing: 12) {
                    let activeTypes = Set(analyzer.fileNodes.map(\.fileType)).sorted()
                    ForEach(activeTypes.prefix(10), id: \.self) { type in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(typeColors[type] ?? .gray)
                                .frame(width: 10, height: 10)
                            Text(".\(type)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    if activeTypes.count > 10 {
                        Text("+\(activeTypes.count - 10) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(analyzer.fileNodes.count) files")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // Treemap
                GeometryReader { geo in
                    let rects = computeTreemap(
                        files: analyzer.fileNodes,
                        in: CGRect(origin: .zero, size: geo.size)
                    )
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(rects.enumerated()), id: \.element.0.id) { _, pair in
                            let (file, rect) = pair
                            treemapCell(file: file, rect: rect)
                        }
                    }
                }
                .padding(4)

                // Hover detail
                if let fileId = hoveredFile,
                   let file = analyzer.fileNodes.first(where: { $0.id == fileId }) {
                    HStack(spacing: 12) {
                        Text(file.id)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(formatSize(file.size))
                            .font(.system(size: 11, weight: .medium))
                        Text("~\(file.lineCount) lines")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
            }
        }
    }

    // MARK: - Treemap Cell

    private func treemapCell(file: FileNode, rect: CGRect) -> some View {
        let isHovered = hoveredFile == file.id
        let color = typeColors[file.fileType] ?? .gray

        return RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(isHovered ? 0.6 : 0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(isHovered ? 0.8 : 0.15), lineWidth: isHovered ? 1.5 : 0.5)
            )
            .overlay(
                // Show filename if cell is big enough
                rect.width > 50 && rect.height > 20
                    ? Text(file.name)
                        .font(.system(size: min(10, rect.width / CGFloat(file.name.count + 2)), design: .monospaced))
                        .foregroundColor(.primary.opacity(0.8))
                        .lineLimit(1)
                        .padding(3)
                    : nil
            )
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .position(x: rect.midX, y: rect.midY)
            .onHover { hover in
                hoveredFile = hover ? file.id : nil
            }
    }

    // MARK: - Treemap Algorithm (Squarified)

    private func computeTreemap(files: [FileNode], in bounds: CGRect) -> [(FileNode, CGRect)] {
        guard !files.isEmpty else { return [] }

        let sorted = files.sorted { $0.size > $1.size }
        let totalSize = sorted.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return [] }

        var result: [(FileNode, CGRect)] = []
        squarify(
            files: sorted,
            index: 0,
            bounds: bounds,
            totalSize: Double(totalSize),
            result: &result
        )
        return result
    }

    private func squarify(
        files: [FileNode],
        index: Int,
        bounds: CGRect,
        totalSize: Double,
        result: inout [(FileNode, CGRect)]
    ) {
        guard index < files.count else { return }
        guard bounds.width > 1 && bounds.height > 1 else { return }

        let remaining = files[index...]
        let remainingSize = remaining.reduce(0.0) { $0 + Double($1.size) }
        guard remainingSize > 0 else { return }

        let isWide = bounds.width >= bounds.height

        // Fill a row/column with items that give the best aspect ratio
        var row: [FileNode] = []
        var rowSize: Double = 0
        var bestAspect: CGFloat = .greatestFiniteMagnitude
        var nextIndex = index

        for file in remaining {
            let candidateSize = rowSize + Double(file.size)
            let fraction = candidateSize / remainingSize
            let rowLength = isWide ? bounds.width * CGFloat(fraction) : bounds.height * CGFloat(fraction)
            let crossLength = isWide ? bounds.height : bounds.width

            // Worst aspect ratio in this row
            var worstAspect: CGFloat = 0
            for item in row + [file] {
                let itemFraction = Double(item.size) / candidateSize
                let itemLength = crossLength * CGFloat(itemFraction)
                let aspect = max(rowLength / max(itemLength, 1), itemLength / max(rowLength, 1))
                worstAspect = max(worstAspect, aspect)
            }

            if worstAspect <= bestAspect || row.isEmpty {
                bestAspect = worstAspect
                row.append(file)
                rowSize = candidateSize
                nextIndex += 1
            } else {
                break
            }
        }

        // Layout the row
        let fraction = rowSize / remainingSize
        let rowLength = isWide ? bounds.width * CGFloat(fraction) : bounds.height * CGFloat(fraction)
        var crossOffset: CGFloat = 0

        for item in row {
            let itemFraction = Double(item.size) / rowSize
            let crossLength = isWide ? bounds.height : bounds.width
            let itemCrossLength = crossLength * CGFloat(itemFraction)

            let rect: CGRect
            if isWide {
                rect = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + crossOffset,
                    width: rowLength,
                    height: itemCrossLength
                )
            } else {
                rect = CGRect(
                    x: bounds.minX + crossOffset,
                    y: bounds.minY,
                    width: itemCrossLength,
                    height: rowLength
                )
            }
            result.append((item, rect.insetBy(dx: 1, dy: 1)))
            crossOffset += itemCrossLength
        }

        // Recurse on remaining space
        let remainingBounds: CGRect
        if isWide {
            remainingBounds = CGRect(
                x: bounds.minX + rowLength,
                y: bounds.minY,
                width: bounds.width - rowLength,
                height: bounds.height
            )
        } else {
            remainingBounds = CGRect(
                x: bounds.minX,
                y: bounds.minY + rowLength,
                width: bounds.width,
                height: bounds.height - rowLength
            )
        }

        squarify(
            files: files,
            index: nextIndex,
            bounds: remainingBounds,
            totalSize: totalSize,
            result: &result
        )
    }

    // MARK: - Helpers

    private func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1f KB", Double(bytes) / 1_000)
        } else {
            return "\(bytes) B"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No files found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("File heatmap shows files sized by their byte count, colored by type")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
