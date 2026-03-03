import SwiftUI

// MARK: - Annotation Models

enum AnnotationTool: CaseIterable {
    case pen, highlight, arrow, rectangle, ellipse, text

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Circle"
        case .text: return "Text"
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .highlight: return 14
        default: return 2.5
        }
    }
}

struct AnnotationElement: Identifiable {
    let id = UUID()
    let tool: AnnotationTool
    let color: Color
    let nsColor: NSColor
    let lineWidth: CGFloat
    var points: [CGPoint] = []
    var startPoint: CGPoint = .zero
    var endPoint: CGPoint = .zero
    var text: String = ""
    var position: CGPoint = .zero
}

// MARK: - Screenshot Annotation View

struct ScreenshotAnnotationView: View {
    let image: NSImage
    let onSave: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var annotations: [AnnotationElement] = []
    @State private var selectedTool: AnnotationTool = .rectangle
    @State private var selectedColor: Color = .red
    @State private var selectedNSColor: NSColor = .systemRed

    // Active drawing state
    @State private var activePoints: [CGPoint] = []
    @State private var dragStart: CGPoint = .zero
    @State private var dragEnd: CGPoint = .zero
    @State private var isDragging = false

    // Text editing state
    @State private var isEditingText = false
    @State private var textValue = ""
    @State private var textEditPosition: CGPoint = .zero
    @FocusState private var isTextFieldFocused: Bool

    @State private var canvasSize: CGSize = .zero

    private let toolbarColors: [(label: String, color: Color, nsColor: NSColor)] = [
        ("Red", .red, .systemRed),
        ("Orange", .orange, .systemOrange),
        ("Yellow", .yellow, .systemYellow),
        ("Green", .green, .systemGreen),
        ("Blue", .blue, .systemBlue),
        ("White", .white, .white),
        ("Black", Color(nsColor: .black), .black),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
            Divider()
            bottomBar
        }
        .frame(minWidth: 700, idealWidth: 1000, minHeight: 500, idealHeight: 750)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Tool buttons
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases, id: \.icon) { tool in
                    Button {
                        if isEditingText { commitText() }
                        selectedTool = tool
                    } label: {
                        Image(systemName: tool.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedTool == tool
                                          ? Color.accentColor.opacity(0.2)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tool.label)
                }
            }

            Divider().frame(height: 20)

            // Color swatches
            HStack(spacing: 4) {
                ForEach(toolbarColors, id: \.label) { item in
                    Circle()
                        .fill(item.color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .stroke(
                                    item.nsColor == selectedNSColor
                                        ? Color.accentColor
                                        : Color(nsColor: .separatorColor).opacity(0.3),
                                    lineWidth: item.nsColor == selectedNSColor ? 2 : 0.5
                                )
                        )
                        .onTapGesture {
                            selectedColor = item.color
                            selectedNSColor = item.nsColor
                        }
                }
            }

            Divider().frame(height: 20)

            // Undo
            Button {
                if !annotations.isEmpty { annotations.removeLast() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(annotations.isEmpty)
            .help("Undo (Cmd+Z)")

            // Clear all
            Button {
                annotations.removeAll()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(annotations.isEmpty)
            .help("Clear all")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Canvas

    private var canvas: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        // Committed annotations
                        Canvas { context, size in
                            renderAnnotations(annotations, in: &context)
                        }

                        // Active drawing preview
                        if isDragging {
                            Canvas { context, size in
                                renderActiveDrawing(in: &context)
                            }
                        }

                        // Text input field
                        if isEditingText {
                            TextField("Type here…", text: $textValue)
                                .textFieldStyle(.plain)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(selectedColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.black.opacity(0.4))
                                )
                                .frame(width: min(250, max(120, geo.size.width - textEditPosition.x - 16)))
                                .position(
                                    x: textEditPosition.x + min(125, (geo.size.width - textEditPosition.x - 16) / 2),
                                    y: textEditPosition.y
                                )
                                .focused($isTextFieldFocused)
                                .onSubmit { commitText() }
                        }

                        // Gesture capture
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(drawingGesture)
                    }
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Text("\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save Screenshot") {
                if isEditingText { commitText() }
                let finalImage = renderFinalImage()
                onSave(finalImage)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Gesture Handling

    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if selectedTool == .text { return }
                isDragging = true
                dragStart = value.startLocation
                dragEnd = value.location
                if selectedTool == .pen || selectedTool == .highlight {
                    activePoints.append(value.location)
                }
            }
            .onEnded { value in
                if selectedTool == .text {
                    if isEditingText { commitText() }
                    textEditPosition = value.startLocation
                    textValue = ""
                    isEditingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isTextFieldFocused = true
                    }
                    return
                }

                isDragging = false

                var element = AnnotationElement(
                    tool: selectedTool,
                    color: selectedColor,
                    nsColor: selectedNSColor,
                    lineWidth: selectedTool.lineWidth
                )

                switch selectedTool {
                case .pen, .highlight:
                    guard activePoints.count >= 2 else {
                        activePoints = []
                        return
                    }
                    element.points = activePoints
                case .arrow, .rectangle, .ellipse:
                    let dist = hypot(dragEnd.x - dragStart.x, dragEnd.y - dragStart.y)
                    guard dist > 3 else { return }
                    element.startPoint = dragStart
                    element.endPoint = dragEnd
                case .text:
                    return
                }

                annotations.append(element)
                activePoints = []
                dragStart = .zero
                dragEnd = .zero
            }
    }

    private func commitText() {
        let trimmed = textValue.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let element = AnnotationElement(
                tool: .text,
                color: selectedColor,
                nsColor: selectedNSColor,
                lineWidth: 0,
                text: trimmed,
                position: textEditPosition
            )
            annotations.append(element)
        }
        textValue = ""
        isEditingText = false
    }

    // MARK: - SwiftUI Canvas Rendering

    private func renderAnnotations(_ elements: [AnnotationElement], in context: inout GraphicsContext) {
        for element in elements {
            renderSingleAnnotation(element, in: &context)
        }
    }

    private func renderActiveDrawing(in context: inout GraphicsContext) {
        let color = selectedTool == .highlight ? selectedColor.opacity(0.35) : selectedColor
        let lineWidth = selectedTool.lineWidth

        switch selectedTool {
        case .pen, .highlight:
            guard activePoints.count >= 2 else { return }
            var path = Path()
            path.move(to: activePoints[0])
            for p in activePoints.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        case .rectangle:
            let rect = rectFromPoints(dragStart, dragEnd)
            context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(color), lineWidth: lineWidth)

        case .ellipse:
            let rect = rectFromPoints(dragStart, dragEnd)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)

        case .arrow:
            drawArrowSwiftUI(in: &context, from: dragStart, to: dragEnd, color: color, lineWidth: lineWidth)

        case .text:
            break
        }
    }

    private func renderSingleAnnotation(_ element: AnnotationElement, in context: inout GraphicsContext) {
        let color = element.tool == .highlight ? element.color.opacity(0.35) : element.color

        switch element.tool {
        case .pen, .highlight:
            guard element.points.count >= 2 else { return }
            var path = Path()
            path.move(to: element.points[0])
            for p in element.points.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: element.lineWidth, lineCap: .round, lineJoin: .round))

        case .rectangle:
            let rect = rectFromPoints(element.startPoint, element.endPoint)
            context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(color), lineWidth: element.lineWidth)

        case .ellipse:
            let rect = rectFromPoints(element.startPoint, element.endPoint)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: element.lineWidth)

        case .arrow:
            drawArrowSwiftUI(in: &context, from: element.startPoint, to: element.endPoint, color: color, lineWidth: element.lineWidth)

        case .text:
            context.draw(
                Text(element.text).font(.system(size: 16, weight: .semibold)).foregroundColor(element.color),
                at: element.position,
                anchor: .leading
            )
        }
    }

    private func drawArrowSwiftUI(in context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color, lineWidth: CGFloat) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), lineWidth: lineWidth)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLen: CGFloat = 14
        let arrowAngle: CGFloat = .pi / 6

        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle - arrowAngle), y: end.y - arrowLen * sin(angle - arrowAngle)))
        head.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + arrowAngle), y: end.y - arrowLen * sin(angle + arrowAngle)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    // MARK: - Final Image Render (Core Graphics)

    private func renderFinalImage() -> NSImage {
        if annotations.isEmpty { return image }
        guard canvasSize.width > 0, canvasSize.height > 0 else { return image }

        let result = NSImage(size: image.size)
        result.lockFocus()

        image.draw(in: NSRect(origin: .zero, size: image.size))

        guard let cg = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return result
        }

        // Flip to match SwiftUI's top-left origin
        cg.translateBy(x: 0, y: image.size.height)
        cg.scaleBy(x: 1, y: -1)

        let sx = image.size.width / canvasSize.width
        let sy = image.size.height / canvasSize.height

        for el in annotations {
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            switch el.tool {
            case .pen:
                guard el.points.count >= 2 else { continue }
                cg.setStrokeColor(el.nsColor.cgColor)
                cg.setLineWidth(el.lineWidth * sx)
                cg.beginPath()
                cg.move(to: scaled(el.points[0], sx, sy))
                for p in el.points.dropFirst() { cg.addLine(to: scaled(p, sx, sy)) }
                cg.strokePath()

            case .highlight:
                guard el.points.count >= 2 else { continue }
                cg.saveGState()
                cg.setStrokeColor(el.nsColor.cgColor)
                cg.setAlpha(0.35)
                cg.setLineWidth(el.lineWidth * sx)
                cg.beginPath()
                cg.move(to: scaled(el.points[0], sx, sy))
                for p in el.points.dropFirst() { cg.addLine(to: scaled(p, sx, sy)) }
                cg.strokePath()
                cg.restoreGState()

            case .rectangle:
                cg.setStrokeColor(el.nsColor.cgColor)
                cg.setLineWidth(el.lineWidth * sx)
                let p1 = scaled(el.startPoint, sx, sy)
                let p2 = scaled(el.endPoint, sx, sy)
                let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                cg.stroke(rect)

            case .ellipse:
                cg.setStrokeColor(el.nsColor.cgColor)
                cg.setLineWidth(el.lineWidth * sx)
                let p1 = scaled(el.startPoint, sx, sy)
                let p2 = scaled(el.endPoint, sx, sy)
                let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                cg.strokeEllipse(in: rect)

            case .arrow:
                cg.setStrokeColor(el.nsColor.cgColor)
                cg.setFillColor(el.nsColor.cgColor)
                cg.setLineWidth(el.lineWidth * sx)
                let start = scaled(el.startPoint, sx, sy)
                let end = scaled(el.endPoint, sx, sy)

                cg.beginPath()
                cg.move(to: start)
                cg.addLine(to: end)
                cg.strokePath()

                let angle = atan2(end.y - start.y, end.x - start.x)
                let arrowLen: CGFloat = 14 * sx
                let arrowAngle: CGFloat = .pi / 6
                cg.beginPath()
                cg.move(to: end)
                cg.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle - arrowAngle),
                                       y: end.y - arrowLen * sin(angle - arrowAngle)))
                cg.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + arrowAngle),
                                       y: end.y - arrowLen * sin(angle + arrowAngle)))
                cg.closePath()
                cg.fillPath()

            case .text:
                let pos = scaled(el.position, sx, sy)
                let fontSize: CGFloat = 16 * sx
                let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: el.nsColor
                ]
                // Flip back for text (NSString.draw expects unflipped coords)
                cg.saveGState()
                cg.translateBy(x: pos.x, y: pos.y)
                cg.scaleBy(x: 1, y: -1)
                (el.text as NSString).draw(at: .zero, withAttributes: attrs)
                cg.restoreGState()
            }
        }

        result.unlockFocus()
        return result
    }

    // MARK: - Helpers

    private func rectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func scaled(_ point: CGPoint, _ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
        CGPoint(x: point.x * sx, y: point.y * sy)
    }
}
