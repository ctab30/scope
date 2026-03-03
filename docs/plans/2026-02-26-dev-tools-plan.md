# Dev Tools Enhancement — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add three Tier 1 features to the Context app: a full code editor with diff viewing, a browser DevTools panel with element inspector, and a project services hub with auto-detected deep links.

**Architecture:** Each feature is self-contained and independently shippable. The code editor upgrades the existing `CodeViewerView` NSTextView wrapper with editing + diff. The DevTools panel adds a collapsible bottom panel to `BrowserView` with JS injection for DOM inspection. The services hub adds a new tab to `GUIPanelView` with config file detection and deep linking.

**Tech Stack:** SwiftUI, AppKit (NSTextView, NSRulerView), WebKit (WKWebView, WKUserScript, WKScriptMessageHandler), Foundation (Process for git CLI).

---

## Feature 1: Code Editor Upgrade

### Task 1: Add Edit Mode Toggle to FileBrowserView

**Files:**
- Modify: `Context/Sources/Context/Views/Files/FileBrowserView.swift`

**Step 1: Add state variables for edit mode**

In `FileBrowserView`, add these state variables alongside the existing ones near the top of the struct:

```swift
@State private var isEditMode = false
@State private var showDiff = false
@State private var editedContent: String = ""
```

**Step 2: Add toolbar buttons to the file header**

In `viewerPanel` (line 95), inside the file name header `HStack` (line 103), before the `Spacer()` on line 118, add edit/diff toggle buttons:

```swift
Spacer()

if currentContent != nil && !isBinary {
    // Diff toggle
    Button {
        showDiff.toggle()
    } label: {
        Image(systemName: showDiff ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(showDiff ? .accentColor : .secondary)
    }
    .buttonStyle(.plain)
    .help("Toggle Git Diff")

    // Edit/View toggle
    Button {
        if !isEditMode {
            editedContent = currentContent ?? ""
        }
        isEditMode.toggle()
    } label: {
        Image(systemName: isEditMode ? "pencil.circle.fill" : "pencil.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isEditMode ? .accentColor : .secondary)
    }
    .buttonStyle(.plain)
    .help(isEditMode ? "Switch to Read Mode" : "Switch to Edit Mode")
}
```

Remove the existing `Spacer()` on line 118 since we added it above.

**Step 3: Route to editor or viewer based on mode**

Replace line 141 (`CodeViewerView(content: content, language: currentLanguage)`) with:

```swift
if isEditMode {
    CodeEditorView(
        content: $editedContent,
        language: currentLanguage,
        filePath: selectedFile?.fullPath.path
    )
} else if showDiff, let path = selectedFile?.fullPath.path {
    DiffViewerView(filePath: path, originalContent: content)
} else {
    CodeViewerView(content: content, language: currentLanguage)
}
```

**Step 4: Reset edit mode on file selection change**

Add to the existing `.onChange(of: selectedFile)` handler (or create one if missing):

```swift
.onChange(of: selectedFile) { _, _ in
    isEditMode = false
    showDiff = false
    editedContent = ""
}
```

**Step 5: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: Build will fail because `CodeEditorView` and `DiffViewerView` don't exist yet. That's expected — we'll create them next.

**Step 6: Commit**

```bash
git add Context/Sources/Context/Views/Files/FileBrowserView.swift
git commit -m "feat(files): add edit mode and diff toggle to file viewer toolbar"
```

---

### Task 2: Create CodeEditorView (Editable NSTextView)

**Files:**
- Create: `Context/Sources/Context/Views/Files/CodeEditorView.swift`

**Step 1: Create the editable NSTextView wrapper**

Create `CodeEditorView.swift` with a full `NSViewRepresentable` wrapping an editable `NSTextView`. Pattern follows the existing `CodeViewerView` (at `Views/Files/CodeViewerView.swift`) but with editing enabled.

```swift
import SwiftUI
import AppKit

struct CodeEditorView: NSViewRepresentable {
    @Binding var content: String
    let language: String?
    let filePath: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator

        // Allow undo
        textView.allowsUndo = true

        scrollView.documentView = textView

        // Line number ruler (reuse existing pattern from CodeViewerView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler

        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler

        // Set initial content
        let highlighter = SyntaxHighlighter()
        let attributed = highlighter.highlight(content, language: language)
        textView.textStorage?.setAttributedString(attributed)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Only update if content changed externally (not from user typing)
        guard !context.coordinator.isEditing else { return }
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let current = textView.string
        if current != content {
            let highlighter = SyntaxHighlighter()
            let attributed = highlighter.highlight(content, language: language)
            textView.textStorage?.setAttributedString(attributed)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var textView: NSTextView?
        var rulerView: LineNumberRulerView?
        var isEditing = false
        private var rehighlightWorkItem: DispatchWorkItem?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            parent.content = textView.string
            rulerView?.needsDisplay = true

            // Debounced re-highlighting (300ms after last edit)
            rehighlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView else { return }
                let highlighter = SyntaxHighlighter()
                let cursorRange = tv.selectedRange()
                let attributed = highlighter.highlight(tv.string, language: self.parent.language)
                tv.textStorage?.setAttributedString(attributed)
                tv.setSelectedRange(cursorRange)
            }
            rehighlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)

            DispatchQueue.main.async { self.isEditing = false }
        }

        // Cmd+S to save
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Cmd+S is handled by the key equivalent on the SwiftUI side
            return false
        }
    }
}
```

**Step 2: Add Cmd+S save handler to FileBrowserView**

Back in `FileBrowserView.swift`, add a background keyboard shortcut in the `viewerPanel` `VStack`:

```swift
.background {
    if isEditMode, let path = selectedFile?.fullPath.path {
        Button("") {
            saveFile(content: editedContent, to: path)
        }
        .keyboardShortcut("s", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}
```

And add the save function:

```swift
private func saveFile(content: String, to path: String) {
    do {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        // Update cache so switching back to read mode shows saved content
        if let file = selectedFile {
            let lang = FileTreeNode.detectLanguage(for: file.name)
            contentCache[file.id] = (content: content, language: lang)
        }
    } catch {
        print("FileBrowserView: failed to save file: \(error)")
    }
}
```

**Step 3: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: Build may fail because `DiffViewerView` doesn't exist yet. `CodeEditorView` and save logic should compile.

**Step 4: Commit**

```bash
git add Context/Sources/Context/Views/Files/CodeEditorView.swift Context/Sources/Context/Views/Files/FileBrowserView.swift
git commit -m "feat(files): add editable code editor with syntax highlighting and Cmd+S save"
```

---

### Task 3: Create DiffViewerView (Git Diff Display)

**Files:**
- Create: `Context/Sources/Context/Views/Files/DiffViewerView.swift`

**Step 1: Create the diff viewer**

This view runs `git diff` on the file and renders the output with colored line backgrounds.

```swift
import SwiftUI
import AppKit

struct DiffViewerView: View {
    let filePath: String
    let originalContent: String

    @State private var diffLines: [DiffLine] = []
    @State private var hasDiff = false

    struct DiffLine: Identifiable {
        let id = UUID()
        let text: String
        let type: LineType

        enum LineType {
            case context
            case addition
            case deletion
            case header
        }
    }

    var body: some View {
        Group {
            if !hasDiff {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                    Text("No uncommitted changes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diffLines) { line in
                            diffLineRow(line)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { loadDiff() }
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            Text(line.type == .addition ? "+" : (line.type == .deletion ? "-" : " "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(lineColor(line.type))
                .frame(width: 16, alignment: .center)

            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(line.type == .header ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(lineBackground(line.type))
    }

    private func lineColor(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .addition: return .green
        case .deletion: return .red
        case .header: return .secondary
        case .context: return .secondary.opacity(0.3)
        }
    }

    private func lineBackground(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .addition: return .green.opacity(0.08)
        case .deletion: return .red.opacity(0.08)
        case .header: return Color(nsColor: .separatorColor).opacity(0.1)
        case .context: return .clear
        }
    }

    private func loadDiff() {
        // Find git root relative to the file
        let fileURL = URL(fileURLWithPath: filePath)
        let directory = fileURL.deletingLastPathComponent().path

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--no-color", "--", filePath]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            hasDiff = false
            return
        }

        hasDiff = true
        diffLines = output.components(separatedBy: .newlines).map { line in
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                return DiffLine(text: line, type: .header)
            } else if line.hasPrefix("@@") {
                return DiffLine(text: line, type: .header)
            } else if line.hasPrefix("+") {
                return DiffLine(text: String(line.dropFirst()), type: .addition)
            } else if line.hasPrefix("-") {
                return DiffLine(text: String(line.dropFirst()), type: .deletion)
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                return DiffLine(text: text, type: .context)
            }
        }
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS — all three components (CodeEditorView, DiffViewerView, FileBrowserView integration) should compile.

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Files/DiffViewerView.swift
git commit -m "feat(files): add git diff viewer with colored line highlights"
```

---

## Feature 2: Browser DevTools Panel

### Task 4: Create DevTools Data Models and Element Picker JS

**Files:**
- Create: `Context/Sources/Context/Views/Browser/DevToolsModels.swift`

**Step 1: Create the data models**

```swift
import Foundation

// MARK: - DevTools Data Models

struct InspectedElement {
    let selector: String
    let tagName: String
    let id: String?
    let classes: [String]
    let attributes: [String: String]
    let axRef: String?
    let rect: ElementRect
    let children: [ElementSummary]
    let parent: ElementSummary?
}

struct ElementSummary: Identifiable {
    let id = UUID()
    let tagName: String
    let elementId: String?
    let classes: [String]
    let selector: String
}

struct ElementRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ComputedStyles {
    let typography: [(String, String)]   // font-family, font-size, etc.
    let layout: [(String, String)]       // display, position, flex, etc.
    let spacing: [(String, String)]      // margin, padding
    let colors: [(String, String)]       // color, background-color, etc.
    let border: [(String, String)]       // border, border-radius, etc.
    let other: [(String, String)]        // everything else
}

struct BoxModelData {
    let content: (width: Double, height: Double)
    let padding: (top: Double, right: Double, bottom: Double, left: Double)
    let border: (top: Double, right: Double, bottom: Double, left: Double)
    let margin: (top: Double, right: Double, bottom: Double, left: Double)
}
```

**Step 2: Commit**

```bash
git add Context/Sources/Context/Views/Browser/DevToolsModels.swift
git commit -m "feat(devtools): add data models for element inspection"
```

---

### Task 5: Add DevTools JS Injection to BrowserTab

**Files:**
- Modify: `Context/Sources/Context/Views/Browser/BrowserTab.swift`

**Step 1: Register a new message handler for DevTools**

In `BrowserTab.init()` (line 104), after the existing `consoleLog` handler registration on line 142, add:

```swift
config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: "devtools")
```

**Step 2: Add DevTools published state**

Near the top of the `BrowserTab` class (after line 55), add:

```swift
@Published var inspectedElement: InspectedElement?
@Published var inspectedStyles: ComputedStyles?
@Published var inspectedBoxModel: BoxModelData?
@Published var isElementPickerActive = false
```

**Step 3: Add element picker injection method**

Add these methods to `BrowserTab`:

```swift
// MARK: - DevTools Element Picker

func startElementPicker() {
    isElementPickerActive = true
    let js = """
    (function() {
        if (window.__ctxDevToolsOverlay) return;
        var overlay = document.createElement('div');
        overlay.id = '__ctxDevToolsOverlay';
        overlay.style.cssText = 'position:fixed;pointer-events:none;border:2px solid #2196F3;background:rgba(33,150,243,0.1);z-index:999999;transition:all 0.05s;display:none;';
        document.body.appendChild(overlay);
        window.__ctxDevToolsOverlay = overlay;
        window.__ctxDevToolsLastTarget = null;

        function getSelector(el) {
            if (el.id) return '#' + el.id;
            var path = [];
            while (el && el.nodeType === 1) {
                var s = el.tagName.toLowerCase();
                if (el.id) { path.unshift('#' + el.id); break; }
                if (el.className && typeof el.className === 'string') {
                    var cls = el.className.trim().split(/\\s+/).filter(c => !c.startsWith('__ctx')).slice(0,2).join('.');
                    if (cls) s += '.' + cls;
                }
                var parent = el.parentElement;
                if (parent) {
                    var siblings = Array.from(parent.children).filter(c => c.tagName === el.tagName);
                    if (siblings.length > 1) s += ':nth-child(' + (Array.from(parent.children).indexOf(el) + 1) + ')';
                }
                path.unshift(s);
                el = parent;
            }
            return path.join(' > ');
        }

        document.addEventListener('mousemove', function handler(e) {
            if (!window.__ctxDevToolsOverlay) { document.removeEventListener('mousemove', handler); return; }
            var t = e.target;
            if (t === overlay || t.id === '__ctxDevToolsOverlay') return;
            window.__ctxDevToolsLastTarget = t;
            var r = t.getBoundingClientRect();
            overlay.style.display = 'block';
            overlay.style.top = r.top + 'px';
            overlay.style.left = r.left + 'px';
            overlay.style.width = r.width + 'px';
            overlay.style.height = r.height + 'px';
        }, true);

        document.addEventListener('click', function handler(e) {
            if (!window.__ctxDevToolsOverlay) { document.removeEventListener('click', handler); return; }
            e.preventDefault();
            e.stopPropagation();
            var t = window.__ctxDevToolsLastTarget || e.target;
            var r = t.getBoundingClientRect();
            var attrs = {};
            for (var i = 0; i < t.attributes.length; i++) {
                attrs[t.attributes[i].name] = t.attributes[i].value;
            }
            window.webkit.messageHandlers.devtools.postMessage({
                type: 'elementSelected',
                selector: getSelector(t),
                tagName: t.tagName.toLowerCase(),
                id: t.id || null,
                classes: t.className ? t.className.split(/\\s+/) : [],
                attributes: attrs,
                axRef: t.getAttribute('data-ax-ref') || null,
                rect: { x: r.x, y: r.y, width: r.width, height: r.height }
            });
            // Remove picker after selection
            overlay.style.display = 'none';
        }, true);
    })();
    """
    webView.evaluateJavaScript(js)
}

func stopElementPicker() {
    isElementPickerActive = false
    let js = """
    (function() {
        var overlay = document.getElementById('__ctxDevToolsOverlay');
        if (overlay) overlay.remove();
        window.__ctxDevToolsOverlay = null;
        window.__ctxDevToolsLastTarget = null;
    })();
    """
    webView.evaluateJavaScript(js)
}

func fetchComputedStyles(selector: String) async -> ComputedStyles? {
    let js = """
    (function() {
        var el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
        if (!el) return null;
        var s = window.getComputedStyle(el);
        var get = function(props) { return props.map(function(p) { return [p, s.getPropertyValue(p)]; }).filter(function(x) { return x[1] && x[1] !== 'none' && x[1] !== 'normal' && x[1] !== 'auto' && x[1] !== '0px'; }); };
        return {
            typography: get(['font-family','font-size','font-weight','line-height','letter-spacing','text-align','text-decoration','text-transform','color']),
            layout: get(['display','position','top','right','bottom','left','float','flex-direction','justify-content','align-items','gap','grid-template-columns','grid-template-rows','overflow','z-index']),
            spacing: get(['margin-top','margin-right','margin-bottom','margin-left','padding-top','padding-right','padding-bottom','padding-left']),
            colors: get(['color','background-color','background','opacity']),
            border: get(['border','border-top','border-right','border-bottom','border-left','border-radius','outline','box-shadow']),
            other: []
        };
    })();
    """
    guard let result = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else {
        return nil
    }
    func toPairs(_ key: String) -> [(String, String)] {
        (result[key] as? [[Any]])?.compactMap { arr in
            guard arr.count == 2, let k = arr[0] as? String, let v = arr[1] as? String else { return nil }
            return (k, v)
        } ?? []
    }
    return ComputedStyles(
        typography: toPairs("typography"), layout: toPairs("layout"),
        spacing: toPairs("spacing"), colors: toPairs("colors"),
        border: toPairs("border"), other: []
    )
}

func fetchBoxModel(selector: String) async -> BoxModelData? {
    let js = """
    (function() {
        var el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
        if (!el) return null;
        var s = window.getComputedStyle(el);
        var r = el.getBoundingClientRect();
        var p = function(v) { return parseFloat(v) || 0; };
        return {
            width: r.width, height: r.height,
            pt: p(s.paddingTop), pr: p(s.paddingRight), pb: p(s.paddingBottom), pl: p(s.paddingLeft),
            bt: p(s.borderTopWidth), br: p(s.borderRightWidth), bb: p(s.borderBottomWidth), bl: p(s.borderLeftWidth),
            mt: p(s.marginTop), mr: p(s.marginRight), mb: p(s.marginBottom), ml: p(s.marginLeft)
        };
    })();
    """
    guard let r = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else {
        return nil
    }
    let d = { (k: String) -> Double in (r[k] as? Double) ?? 0 }
    return BoxModelData(
        content: (width: d("width"), height: d("height")),
        padding: (top: d("pt"), right: d("pr"), bottom: d("pb"), left: d("pl")),
        border: (top: d("bt"), right: d("br"), bottom: d("bb"), left: d("bl")),
        margin: (top: d("mt"), right: d("mr"), bottom: d("mb"), left: d("ml"))
    )
}
```

**Step 4: Handle the devtools message handler**

In the existing `userContentController(_:didReceive:)` method (around line 912), add handling for the `devtools` message name:

```swift
if message.name == "devtools" {
    guard let body = message.body as? [String: Any],
          let type = body["type"] as? String else { return }

    if type == "elementSelected" {
        let tagName = body["tagName"] as? String ?? "unknown"
        let id = body["id"] as? String
        let classes = body["classes"] as? [String] ?? []
        let attrs = body["attributes"] as? [String: String] ?? [:]
        let axRef = body["axRef"] as? String
        let rectDict = body["rect"] as? [String: Double] ?? [:]
        let selector = body["selector"] as? String ?? ""

        let rect = ElementRect(
            x: rectDict["x"] ?? 0, y: rectDict["y"] ?? 0,
            width: rectDict["width"] ?? 0, height: rectDict["height"] ?? 0
        )

        DispatchQueue.main.async { [weak self] in
            self?.inspectedElement = InspectedElement(
                selector: selector, tagName: tagName, id: id,
                classes: classes, attributes: attrs, axRef: axRef,
                rect: rect, children: [], parent: nil
            )
            self?.isElementPickerActive = false

            // Fetch styles and box model
            Task {
                self?.inspectedStyles = await self?.fetchComputedStyles(selector: selector)
                self?.inspectedBoxModel = await self?.fetchBoxModel(selector: selector)
            }
        }
    }
}
```

**Step 5: Clean up devtools handler in deinit**

In the `deinit` method (around line 164), add cleanup for the devtools handler:

```swift
webView.configuration.userContentController.removeScriptMessageHandler(forName: "devtools")
```

**Step 6: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS

**Step 7: Commit**

```bash
git add Context/Sources/Context/Views/Browser/BrowserTab.swift Context/Sources/Context/Views/Browser/DevToolsModels.swift
git commit -m "feat(devtools): add element picker JS injection and computed style fetching"
```

---

### Task 6: Create DevTools Panel UI

**Files:**
- Create: `Context/Sources/Context/Views/Browser/DevToolsPanel.swift`

**Step 1: Create the DevTools panel with tabs**

```swift
import SwiftUI

struct DevToolsPanel: View {
    @ObservedObject var tab: BrowserTab
    @Binding var isVisible: Bool

    enum DevToolsTab: String, CaseIterable {
        case elements = "Elements"
        case styles = "Styles"
        case boxModel = "Box Model"
    }

    @State private var selectedTab: DevToolsTab = .elements

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // Element picker toggle
                Button {
                    if tab.isElementPickerActive {
                        tab.stopElementPicker()
                    } else {
                        tab.startElementPicker()
                    }
                } label: {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(tab.isElementPickerActive ? .accentColor : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(tab.isElementPickerActive ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Pick Element")

                // Tab switcher
                ForEach(DevToolsTab.allCases, id: \.self) { devTab in
                    Button {
                        selectedTab = devTab
                    } label: {
                        Text(devTab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == devTab ? .semibold : .regular))
                            .foregroundColor(selectedTab == devTab ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(selectedTab == devTab
                                          ? Color(nsColor: .controlBackgroundColor)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Selected element label
                if let el = tab.inspectedElement {
                    HStack(spacing: 2) {
                        Text(el.tagName)
                            .foregroundColor(.purple)
                        if let id = el.id, !id.isEmpty {
                            Text("#\(id)")
                                .foregroundColor(.blue)
                        }
                        if !el.classes.isEmpty {
                            Text(".\(el.classes.prefix(2).joined(separator: "."))")
                                .foregroundColor(.green)
                        }
                        if let ref = el.axRef {
                            Text("[\(ref)]")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                }

                // Close button
                Button {
                    tab.stopElementPicker()
                    isVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .elements:
                    elementsTab
                case .styles:
                    stylesTab
                case .boxModel:
                    boxModelTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Elements Tab

    private var elementsTab: some View {
        Group {
            if let el = tab.inspectedElement {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Tag and attributes
                        Text("<\(el.tagName)\(attributeString(el))>")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.purple)
                            .textSelection(.enabled)
                            .padding(8)

                        // All attributes
                        ForEach(Array(el.attributes.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 4) {
                                Text(key)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.blue)
                                Text("=")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text("\"\(value)\"")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                emptyState("Click the picker icon, then click an element on the page")
            }
        }
    }

    // MARK: - Styles Tab

    private var stylesTab: some View {
        Group {
            if let styles = tab.inspectedStyles {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        styleSection("Typography", styles.typography)
                        styleSection("Layout", styles.layout)
                        styleSection("Spacing", styles.spacing)
                        styleSection("Colors", styles.colors)
                        styleSection("Border", styles.border)
                    }
                    .padding(8)
                }
            } else if tab.inspectedElement != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState("Select an element to view its styles")
            }
        }
    }

    private func styleSection(_ title: String, _ props: [(String, String)]) -> some View {
        Group {
            if !props.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    ForEach(Array(props.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 4) {
                            Text(pair.0)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(":")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(pair.1)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Box Model Tab

    private var boxModelTab: some View {
        Group {
            if let box = tab.inspectedBoxModel {
                VStack {
                    Spacer()
                    boxModelDiagram(box)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if tab.inspectedElement != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState("Select an element to view its box model")
            }
        }
    }

    private func boxModelDiagram(_ box: BoxModelData) -> some View {
        ZStack {
            // Margin (outermost)
            boxLayer(
                label: "margin",
                color: Color.orange.opacity(0.15),
                top: box.margin.top, right: box.margin.right,
                bottom: box.margin.bottom, left: box.margin.left,
                innerWidth: box.content.width + box.padding.left + box.padding.right + box.border.left + box.border.right,
                innerHeight: box.content.height + box.padding.top + box.padding.bottom + box.border.top + box.border.bottom
            )

            // Border
            boxLayer(
                label: "border",
                color: Color.yellow.opacity(0.2),
                top: box.border.top, right: box.border.right,
                bottom: box.border.bottom, left: box.border.left,
                innerWidth: box.content.width + box.padding.left + box.padding.right,
                innerHeight: box.content.height + box.padding.top + box.padding.bottom
            )

            // Padding
            boxLayer(
                label: "padding",
                color: Color.green.opacity(0.15),
                top: box.padding.top, right: box.padding.right,
                bottom: box.padding.bottom, left: box.padding.left,
                innerWidth: box.content.width,
                innerHeight: box.content.height
            )

            // Content (innermost)
            VStack(spacing: 2) {
                Text("\(Int(box.content.width)) x \(Int(box.content.height))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .frame(width: max(80, min(box.content.width * 0.5, 200)), height: max(40, min(box.content.height * 0.3, 60)))
            .background(Color.blue.opacity(0.2))
        }
        .frame(width: 320, height: 200)
    }

    private func boxLayer(label: String, color: Color, top: Double, right: Double, bottom: Double, left: Double, innerWidth: Double, innerHeight: Double) -> some View {
        ZStack {
            Rectangle().fill(color)
            VStack {
                Text(fmt(top))
                    .font(.system(size: 9, design: .monospaced))
                Spacer()
                HStack {
                    Text(fmt(left))
                        .font(.system(size: 9, design: .monospaced))
                    Spacer()
                    Text(fmt(right))
                        .font(.system(size: 9, design: .monospaced))
                }
                Spacer()
                Text(fmt(bottom))
                    .font(.system(size: 9, design: .monospaced))
            }
            .padding(2)
        }
        .overlay(
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(2),
            alignment: .topLeading
        )
    }

    // MARK: - Helpers

    private func attributeString(_ el: InspectedElement) -> String {
        var parts: [String] = []
        if let id = el.id, !id.isEmpty { parts.append("id=\"\(id)\"") }
        if !el.classes.isEmpty { parts.append("class=\"\(el.classes.joined(separator: " "))\"") }
        if let ref = el.axRef { parts.append("data-ax-ref=\"\(ref)\"") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fmt(_ v: Double) -> String {
        v == 0 ? "-" : "\(Int(v))"
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Browser/DevToolsPanel.swift
git commit -m "feat(devtools): add DevTools panel UI with elements, styles, and box model tabs"
```

---

### Task 7: Integrate DevTools Panel into BrowserView

**Files:**
- Modify: `Context/Sources/Context/Views/Browser/BrowserView.swift`

**Step 1: Add DevTools state**

In `BrowserView`, add a state variable near the existing state (around line 8):

```swift
@State private var showDevTools = false
```

**Step 2: Add DevTools toggle button to navBar**

In the `navBar` computed property (line 139), after the console log badge button (after line 273), add a DevTools toggle:

```swift
// DevTools
Button {
    showDevTools.toggle()
} label: {
    Image(systemName: "hammer")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(showDevTools ? .accentColor : (viewModel.activeTab != nil ? .primary : .secondary.opacity(0.4)))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
.disabled(viewModel.activeTab == nil)
.help("DevTools")
```

**Step 3: Add DevTools panel below the web content**

In the main `VStack` body (line 28), after the web content `Group` (after line 65) and before the ScreenshotGalleryStrip section (line 68), add the DevTools panel:

```swift
// DevTools panel
if showDevTools, let tab = viewModel.activeTab {
    Divider()
    DevToolsPanel(tab: tab, isVisible: $showDevTools)
        .frame(height: 250)
}
```

**Step 4: Stop element picker on tab switch**

In the existing `.onChange(of: viewModel.activeTabId)` handler (line 73), add:

```swift
// Stop element picker when switching tabs
if let oldId, let oldTab = viewModel.tabs.first(where: { $0.id == oldId }) {
    oldTab.stopElementPicker()
}
```

**Step 5: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS

**Step 6: Commit**

```bash
git add Context/Sources/Context/Views/Browser/BrowserView.swift
git commit -m "feat(devtools): integrate DevTools panel into browser with element picker toggle"
```

---

## Feature 3: Project Services Hub

### Task 8: Create Service Detection Engine

**Files:**
- Create: `Context/Sources/Context/Services/ProjectServicesDetector.swift`

**Step 1: Create the service detector**

```swift
import Foundation

// MARK: - Detected Service Models

enum ServiceType: String, CaseIterable {
    case firebase = "Firebase"
    case supabase = "Supabase"
    case vercel = "Vercel"
    case netlify = "Netlify"
    case docker = "Docker"
    case railway = "Railway"
    case aws = "AWS Amplify"
}

struct DetectedService: Identifiable {
    let id = UUID()
    let type: ServiceType
    let projectId: String?       // extracted from config
    let configPath: String       // path to the config file that triggered detection
    let dashboardURL: URL?       // deep link to the service dashboard

    var icon: String {
        switch type {
        case .firebase: return "flame"
        case .supabase: return "server.rack"
        case .vercel: return "triangle"
        case .netlify: return "network"
        case .docker: return "shippingbox"
        case .railway: return "tram"
        case .aws: return "cloud"
        }
    }

    var displayName: String { type.rawValue }
}

struct EnvironmentFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let entries: [(key: String, value: String)]
}

// MARK: - Detector

class ProjectServicesDetector {
    static func scan(projectPath: String) -> [DetectedService] {
        let fm = FileManager.default
        var services: [DetectedService] = []

        // Firebase
        let firebaseConfig = "\(projectPath)/firebase.json"
        let firebaseRC = "\(projectPath)/.firebaserc"
        if fm.fileExists(atPath: firebaseConfig) || fm.fileExists(atPath: firebaseRC) {
            let projectId = extractFirebaseProjectId(from: firebaseRC)
            let url = projectId.flatMap { URL(string: "https://console.firebase.google.com/project/\($0)") }
            services.append(DetectedService(
                type: .firebase, projectId: projectId,
                configPath: fm.fileExists(atPath: firebaseConfig) ? firebaseConfig : firebaseRC,
                dashboardURL: url
            ))
        }

        // Supabase
        let supabaseConfig = "\(projectPath)/supabase/config.toml"
        if fm.fileExists(atPath: supabaseConfig) {
            let ref = extractSupabaseRef(projectPath: projectPath)
            let url = ref.flatMap { URL(string: "https://supabase.com/dashboard/project/\($0)") }
            services.append(DetectedService(
                type: .supabase, projectId: ref,
                configPath: supabaseConfig,
                dashboardURL: url
            ))
        }

        // Vercel
        let vercelJSON = "\(projectPath)/vercel.json"
        let vercelProject = "\(projectPath)/.vercel/project.json"
        if fm.fileExists(atPath: vercelJSON) || fm.fileExists(atPath: vercelProject) {
            let (org, project) = extractVercelInfo(from: vercelProject)
            var url: URL?
            if let org, let project {
                url = URL(string: "https://vercel.com/\(org)/\(project)")
            } else {
                url = URL(string: "https://vercel.com/dashboard")
            }
            services.append(DetectedService(
                type: .vercel, projectId: project,
                configPath: fm.fileExists(atPath: vercelProject) ? vercelProject : vercelJSON,
                dashboardURL: url
            ))
        }

        // Netlify
        let netlifyToml = "\(projectPath)/netlify.toml"
        if fm.fileExists(atPath: netlifyToml) {
            services.append(DetectedService(
                type: .netlify, projectId: nil,
                configPath: netlifyToml,
                dashboardURL: URL(string: "https://app.netlify.com")
            ))
        }

        // Docker
        let dockerCompose = "\(projectPath)/docker-compose.yml"
        let dockerComposeYaml = "\(projectPath)/docker-compose.yaml"
        let dockerfile = "\(projectPath)/Dockerfile"
        if fm.fileExists(atPath: dockerCompose) || fm.fileExists(atPath: dockerComposeYaml) || fm.fileExists(atPath: dockerfile) {
            let configFile = fm.fileExists(atPath: dockerCompose) ? dockerCompose : (fm.fileExists(atPath: dockerComposeYaml) ? dockerComposeYaml : dockerfile)
            services.append(DetectedService(
                type: .docker, projectId: nil,
                configPath: configFile,
                dashboardURL: nil
            ))
        }

        // Railway
        let railwayToml = "\(projectPath)/railway.toml"
        let railwayJSON = "\(projectPath)/railway.json"
        if fm.fileExists(atPath: railwayToml) || fm.fileExists(atPath: railwayJSON) {
            services.append(DetectedService(
                type: .railway, projectId: nil,
                configPath: fm.fileExists(atPath: railwayToml) ? railwayToml : railwayJSON,
                dashboardURL: URL(string: "https://railway.app/dashboard")
            ))
        }

        // AWS Amplify
        let amplifyDir = "\(projectPath)/amplify"
        if fm.fileExists(atPath: amplifyDir) {
            services.append(DetectedService(
                type: .aws, projectId: nil,
                configPath: amplifyDir,
                dashboardURL: URL(string: "https://console.aws.amazon.com/amplify")
            ))
        }

        return services
    }

    // MARK: - .env File Parsing

    static func scanEnvironmentFiles(projectPath: String) -> [EnvironmentFile] {
        let fm = FileManager.default
        let envNames = [".env", ".env.local", ".env.development", ".env.staging", ".env.production", ".env.example"]
        var files: [EnvironmentFile] = []

        for name in envNames {
            let path = "\(projectPath)/\(name)"
            if fm.fileExists(atPath: path),
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let entries = content
                    .components(separatedBy: .newlines)
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    .compactMap { line -> (key: String, value: String)? in
                        let parts = line.split(separator: "=", maxSplits: 1)
                        guard parts.count == 2 else { return nil }
                        return (key: String(parts[0]).trimmingCharacters(in: .whitespaces),
                                value: String(parts[1]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    }
                if !entries.isEmpty {
                    files.append(EnvironmentFile(name: name, path: path, entries: entries))
                }
            }
        }

        // Also check for Supabase URL in env files (for Supabase detection without config.toml)
        return files
    }

    // MARK: - Config Extractors

    private static func extractFirebaseProjectId(from rcPath: String) -> String? {
        guard let content = try? String(contentsOfFile: rcPath, encoding: .utf8),
              let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else { return nil }
        return projects["default"]
    }

    private static func extractSupabaseRef(projectPath: String) -> String? {
        // Try to extract from .env files
        let envFiles = [".env", ".env.local", ".env.development"]
        for name in envFiles {
            if let content = try? String(contentsOfFile: "\(projectPath)/\(name)", encoding: .utf8) {
                for line in content.components(separatedBy: .newlines) {
                    if line.hasPrefix("SUPABASE_URL=") || line.hasPrefix("NEXT_PUBLIC_SUPABASE_URL=") || line.hasPrefix("VITE_SUPABASE_URL=") {
                        // Extract ref from URL like https://abcdefg.supabase.co
                        let url = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                        if let match = url.range(of: #"https://([a-z]+)\.supabase\.co"#, options: .regularExpression) {
                            let ref = url[match].replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: ".supabase.co", with: "")
                            return ref
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func extractVercelInfo(from projectPath: String) -> (org: String?, project: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: projectPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let org = json["orgId"] as? String
        let project = json["projectId"] as? String
        return (org, project)
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/ProjectServicesDetector.swift
git commit -m "feat(services): add project services detector with Firebase, Supabase, Vercel, Docker, Railway, Netlify, AWS support"
```

---

### Task 9: Create Project Services Hub View

**Files:**
- Create: `Context/Sources/Context/Views/Services/ProjectServicesView.swift`

**Step 1: Create the services hub view**

```swift
import SwiftUI

struct ProjectServicesView: View {
    @EnvironmentObject var appState: AppState

    @State private var detectedServices: [DetectedService] = []
    @State private var envFiles: [EnvironmentFile] = []
    @State private var isScanning = false

    // Sections collapsed state
    @State private var collapsedSections: Set<String> = []

    // Env value reveal
    @State private var revealedKeys: Set<String> = []

    var body: some View {
        Group {
            if detectedServices.isEmpty && envFiles.isEmpty && !isScanning {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Detected Services
                        if !detectedServices.isEmpty {
                            servicesSection
                        }

                        // Environment Files
                        if !envFiles.isEmpty {
                            environmentSection
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { scan() }
        .onChange(of: appState.currentProject) { _, _ in scan() }
    }

    // MARK: - Services Section

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Detected Services", count: detectedServices.count, section: "services")

            if !collapsedSections.contains("services") {
                ForEach(detectedServices) { service in
                    serviceCard(service)
                }
            }
        }
    }

    private func serviceCard(_ service: DetectedService) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: service.icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.1))
                )

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .font(.system(size: 13, weight: .medium))

                if let projectId = service.projectId {
                    Text(projectId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Config path badge
            Text(URL(fileURLWithPath: service.configPath).lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor).opacity(0.2))
                )

            // Open Dashboard button
            if let url = service.dashboardURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Environment Section

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Environment Variables", count: envFiles.reduce(0) { $0 + $1.entries.count }, section: "env")

            if !collapsedSections.contains("env") {
                ForEach(envFiles) { file in
                    envFileCard(file)
                }
            }
        }
    }

    private func envFileCard(_ file: EnvironmentFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // File name header
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(file.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                Text("\(file.entries.count) vars")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.bottom, 4)

            // Entries
            ForEach(Array(file.entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 4) {
                    Text(entry.key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 100, alignment: .trailing)

                    Text("=")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    let uniqueKey = "\(file.name):\(entry.key)"
                    if revealedKeys.contains(uniqueKey) {
                        Text(entry.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    } else {
                        Button {
                            revealedKeys.insert(uniqueKey)
                        } label: {
                            Text(String(repeating: "\u{2022}", count: min(entry.value.count, 20)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, count: Int, section: String) -> some View {
        Button {
            if collapsedSections.contains(section) {
                collapsedSections.remove(section)
            } else {
                collapsedSections.insert(section)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedSections.contains(section) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    )

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No services detected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Add config files like firebase.json, supabase/config.toml, or vercel.json to detect services")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scan() {
        guard let project = appState.currentProject else { return }
        isScanning = true
        detectedServices = ProjectServicesDetector.scan(projectPath: project.path)
        envFiles = ProjectServicesDetector.scanEnvironmentFiles(projectPath: project.path)
        isScanning = false
        revealedKeys = []
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Services/ProjectServicesView.swift
git commit -m "feat(services): add project services hub view with service cards and env viewer"
```

---

### Task 10: Add Services Tab to GUIPanelView

**Files:**
- Modify: `Context/Sources/Context/ViewModels/AppState.swift`
- Modify: `Context/Sources/Context/Views/GUIPanelView.swift`

**Step 1: Add the services case to GUITab enum**

In `AppState.swift`, add a new case to the `GUITab` enum (after `github` on line 22):

```swift
case services = "Services"
```

And add its icon in the `icon` computed property (after the `github` case on line 35):

```swift
case .services: return "puzzlepiece.extension"
```

**Step 2: Add the services case to GUIPanelView switch**

In `GUIPanelView.swift`, in the tab content switch (around line 152), add a case for services (after the `github` case on line 168):

```swift
case .services:
    ProjectServicesView()
```

**Step 3: Build and verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -5`
Expected: PASS — the tab will automatically appear in the tab bar since `GUITab` is `CaseIterable`.

**Step 4: Commit**

```bash
git add Context/Sources/Context/ViewModels/AppState.swift Context/Sources/Context/Views/GUIPanelView.swift
git commit -m "feat(services): add Services tab to GUI panel"
```

---

### Task 11: Final Build Verification and Cleanup

**Files:**
- All files from Tasks 1–10

**Step 1: Full clean build**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && swift build 2>&1 | tail -20`
Expected: PASS with no warnings related to our changes.

**Step 2: Review all new files exist**

Verify these files were created:
- `Context/Sources/Context/Views/Files/CodeEditorView.swift`
- `Context/Sources/Context/Views/Files/DiffViewerView.swift`
- `Context/Sources/Context/Views/Browser/DevToolsModels.swift`
- `Context/Sources/Context/Views/Browser/DevToolsPanel.swift`
- `Context/Sources/Context/Services/ProjectServicesDetector.swift`
- `Context/Sources/Context/Views/Services/ProjectServicesView.swift`

**Step 3: Review all modified files**

Verify these files were modified correctly:
- `Context/Sources/Context/Views/Files/FileBrowserView.swift` — edit/diff toggles + save
- `Context/Sources/Context/Views/Browser/BrowserTab.swift` — devtools handler + element picker
- `Context/Sources/Context/Views/Browser/BrowserView.swift` — devtools panel integration
- `Context/Sources/Context/ViewModels/AppState.swift` — services tab enum case
- `Context/Sources/Context/Views/GUIPanelView.swift` — services tab routing

**Step 4: Commit if any cleanup needed**

If any cleanup was required, commit with:
```bash
git commit -m "chore: final cleanup for dev tools features"
```
