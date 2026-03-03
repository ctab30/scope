# Embedded Browser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a WKWebView-based multi-tab browser as a tab in the right GUI panel with navigation controls, persistent state, and screenshot capture.

**Architecture:** New `BrowserView` rendered in a `ZStack` alongside the existing tab content switch so WKWebViews persist in memory across GUI tab changes. Each browser tab owns a `WKWebView` instance; switching between browser tabs uses the same ZStack opacity pattern used by `TerminalTabView`.

**Tech Stack:** SwiftUI, WebKit (WKWebView), NSViewRepresentable. No new dependencies.

**Design doc:** `docs/plans/2026-02-21-embedded-browser-design.md`

---

## Task 1: Add `.browser` to GUITab enum

**Files:**
- Modify: `Context/Sources/Context/ViewModels/AppState.swift:13-33`

**Step 1: Add the enum case and icon**

In `AppState.swift`, add `case browser = "Browser"` to the `GUITab` enum after `rules`, and add the icon mapping:

```swift
enum GUITab: String, CaseIterable {
    case tasks = "Tasks"
    case dashboard = "Dashboard"
    case sessions = "Sessions"
    case notes = "Notes"
    case memory = "Memory"
    case rules = "Rules"
    case browser = "Browser"
    case visualize = "Visualize"

    var icon: String {
        switch self {
        case .dashboard: return "house"
        case .sessions: return "clock"
        case .tasks: return "checklist"
        case .notes: return "note.text"
        case .memory: return "brain"
        case .rules: return "doc.text.magnifyingglass"
        case .browser: return "globe"
        case .visualize: return "chart.dots.scatter"
        }
    }
}
```

Note: Place `browser` before `visualize` so it appears before the hidden Visualize tab.

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build succeeds. The `.browser` case will cause a non-exhaustive switch warning in `GUIPanelView.swift` — that's expected and will be fixed in Task 5.

**Step 3: Commit**

```bash
git add Context/Sources/Context/ViewModels/AppState.swift
git commit -m "feat(browser): add browser case to GUITab enum"
```

---

## Task 2: Create BrowserTab model

**Files:**
- Create: `Context/Sources/Context/Views/Browser/BrowserTab.swift`

**Step 1: Create the Browser directory**

```bash
mkdir -p Context/Sources/Context/Views/Browser
```

**Step 2: Write BrowserTab.swift**

This mirrors `TerminalTab.swift` in structure. Each tab owns a `WKWebView` instance and uses KVO to observe title, URL, loading state, and navigation availability.

```swift
import Foundation
import WebKit
import Combine

class BrowserTab: NSObject, Identifiable, ObservableObject {
    let id = UUID()
    let webView: WKWebView

    @Published var title: String = "New Tab"
    @Published var currentURL: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.title = wv.title ?? "New Tab"
                }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.currentURL = wv.url?.absoluteString ?? ""
                }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.isLoading = wv.isLoading
                }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.canGoBack = wv.canGoBack
                }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.canGoForward = wv.canGoForward
                }
            },
        ]
    }

    func navigate(to urlString: String) {
        var input = urlString.trimmingCharacters(in: .whitespaces)
        // Auto-prepend https:// if no scheme
        if !input.contains("://") {
            // Detect localhost patterns
            if input.hasPrefix("localhost") || input.hasPrefix("127.0.0.1") {
                input = "http://\(input)"
            } else {
                input = "https://\(input)"
            }
        }
        guard let url = URL(string: input) else { return }
        webView.load(URLRequest(url: url))
    }
}
```

**Step 3: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build succeeds (with the non-exhaustive switch warning still present).

**Step 4: Commit**

```bash
git add Context/Sources/Context/Views/Browser/BrowserTab.swift
git commit -m "feat(browser): add BrowserTab model with KVO observation"
```

---

## Task 3: Create WebViewWrapper (NSViewRepresentable)

**Files:**
- Create: `Context/Sources/Context/Views/Browser/WebViewWrapper.swift`

**Step 1: Write WebViewWrapper.swift**

This bridges `WKWebView` to SwiftUI. It also acts as the `WKNavigationDelegate` to handle self-signed certs for localhost.

```swift
import SwiftUI
import WebKit

struct WebViewWrapper: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No updates needed — WKWebView is externally managed by BrowserTab
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        /// Accept self-signed certificates for localhost dev servers.
        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let host = challenge.protectionSpace.host
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust,
               (host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build succeeds.

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Browser/WebViewWrapper.swift
git commit -m "feat(browser): add WebViewWrapper NSViewRepresentable with localhost cert handling"
```

---

## Task 4: Create BrowserView (main view)

**Files:**
- Create: `Context/Sources/Context/Views/Browser/BrowserView.swift`

**Step 1: Write BrowserView.swift**

This is the main browser view containing the nav bar, tab strip, and web content area. Pattern mirrors `TerminalTabView.swift` closely.

```swift
import SwiftUI
import WebKit

struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @State private var urlBarText: String = ""
    @State private var isUrlBarFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            navBar

            // Thin separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)

            // Tab strip
            tabStrip

            // Thin separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)

            // Web content — all tabs stay alive in a ZStack
            ZStack {
                ForEach(viewModel.tabs) { tab in
                    let isActive = tab.id == viewModel.activeTabId
                    WebViewWrapper(webView: tab.webView)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                }
            }
            .overlay {
                if viewModel.tabs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No tabs open")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onAppear {
            if viewModel.tabs.isEmpty {
                viewModel.newTab()
            }
        }
        .onChange(of: viewModel.activeTabId) { _, _ in
            syncUrlBar()
        }
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        HStack(spacing: 6) {
            // Back
            Button {
                viewModel.activeTab?.webView.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.activeTab?.canGoBack == true ? .primary : .secondary.opacity(0.3))
            .disabled(viewModel.activeTab?.canGoBack != true)

            // Forward
            Button {
                viewModel.activeTab?.webView.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.activeTab?.canGoForward == true ? .primary : .secondary.opacity(0.3))
            .disabled(viewModel.activeTab?.canGoForward != true)

            // Reload / Stop
            Button {
                if viewModel.activeTab?.isLoading == true {
                    viewModel.activeTab?.webView.stopLoading()
                } else {
                    viewModel.activeTab?.webView.reload()
                }
            } label: {
                Image(systemName: viewModel.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            // URL bar
            TextField("Enter URL or search...", text: $urlBarText, onCommit: {
                guard !urlBarText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                viewModel.activeTab?.navigate(to: urlBarText)
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onReceive(viewModel.objectWillChange) {
                syncUrlBar()
            }

            // Screenshot
            Button {
                takeScreenshot()
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Capture screenshot")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab Strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(viewModel.tabs) { tab in
                        browserTabButton(for: tab)
                    }
                }
            }

            Button(action: { viewModel.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func browserTabButton(for tab: BrowserTab) -> some View {
        let isSelected = tab.id == viewModel.activeTabId

        HStack(spacing: 4) {
            if tab.isLoading {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary.opacity(0.5))
            }

            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: 120)
                .foregroundColor(isSelected ? .primary : .secondary)

            if viewModel.tabs.count > 1 {
                Button(action: { viewModel.closeTab(tab.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .opacity(isSelected ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected
                      ? Color(nsColor: .controlBackgroundColor)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected
                        ? Color(nsColor: .separatorColor).opacity(0.3)
                        : Color.clear,
                        lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.activeTabId = tab.id
        }
    }

    // MARK: - Helpers

    private func syncUrlBar() {
        if let tab = viewModel.activeTab {
            urlBarText = tab.currentURL
        }
    }

    private func takeScreenshot() {
        guard let webView = viewModel.activeTab?.webView else { return }
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image else {
                print("BrowserView: screenshot failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            saveScreenshot(image)
        }
    }

    private func saveScreenshot(_ image: NSImage) {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Context/browser-screenshots", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = dir.appendingPathComponent(fileName)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        try? png.write(to: fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
        print("BrowserView: screenshot saved to \(fileURL.path) (path copied to clipboard)")
    }
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build fails — `BrowserViewModel` not found yet. That's expected; it's Task 4a.

---

## Task 4a: Create BrowserViewModel

**Files:**
- Create: `Context/Sources/Context/Views/Browser/BrowserViewModel.swift`

**Step 1: Write BrowserViewModel.swift**

```swift
import Foundation
import Combine

class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?

    private var cancellables = Set<AnyCancellable>()

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabId }
    }

    func newTab() {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabId = tab.id

        // Forward tab property changes to trigger view updates
        tab.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeTabId == id {
            activeTabId = tabs.last?.id
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build succeeds (with the non-exhaustive switch warning in GUIPanelView).

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Browser/
git commit -m "feat(browser): add BrowserView, BrowserViewModel, BrowserTab, WebViewWrapper"
```

---

## Task 5: Wire browser tab into GUIPanelView

**Files:**
- Modify: `Context/Sources/Context/Views/GUIPanelView.swift:80-155`

**Step 1: Add a `@StateObject` for BrowserView persistence**

At the top of `GUIPanelView`, add a `@StateObject` to keep the browser alive across tab switches:

```swift
struct GUIPanelView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var mcpMonitor = MCPConnectionMonitor()
    @StateObject private var browserViewModel = BrowserViewModel()
```

**Step 2: Modify the tab content section for persistence**

Replace the current `Group { switch ... }` block (lines 131-148) with a `ZStack` that keeps the browser alive:

```swift
                // Tab content — browser persists via ZStack, others switch normally
                ZStack {
                    // Browser always exists in the ZStack (hidden when not selected)
                    BrowserView(viewModel: browserViewModel)
                        .opacity(appState.selectedTab == .browser ? 1 : 0)
                        .allowsHitTesting(appState.selectedTab == .browser)

                    // Other tabs render on demand
                    if appState.selectedTab != .browser {
                        Group {
                            switch appState.selectedTab {
                            case .dashboard:
                                DashboardView()
                            case .sessions:
                                SessionListView()
                            case .tasks:
                                KanbanBoard()
                            case .notes:
                                NoteListView()
                            case .memory:
                                MemoryEditorView()
                            case .rules:
                                ClaudeMdEditorView()
                            case .visualize:
                                VisualizerView()
                            case .browser:
                                EmptyView() // Handled above
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

**Step 3: Update BrowserView to accept external viewModel**

This requires a small change to `BrowserView.swift` — change from `@StateObject private var viewModel = BrowserViewModel()` to accepting it as a parameter:

In `BrowserView.swift`, change the property:

```swift
struct BrowserView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @State private var urlBarText: String = ""
    @State private var isUrlBarFocused: Bool = false
```

**Step 4: Also add `.browser` case to the HomeView path**

In the `if appState.isHomeView` branch, the browser tab won't be in the tab bar — but the user might navigate from a project browser tab to home. The browser should also be accessible from home mode. Add a browser button to the home header, or simply make the browser tab available in home mode too.

The simplest approach: when in home mode and the user was previously on the browser tab, show the browser instead of HomeView. Add to the `if appState.isHomeView` block:

```swift
            if appState.isHomeView {
                if appState.selectedTab == .browser {
                    // Browser persists even in home mode
                    BrowserView(viewModel: browserViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // existing home view header + HomeView content...
                }
            }
```

**Step 5: Build to verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build succeeds with no warnings about non-exhaustive switch.

**Step 6: Commit**

```bash
git add Context/Sources/Context/Views/GUIPanelView.swift Context/Sources/Context/Views/Browser/BrowserView.swift
git commit -m "feat(browser): wire browser tab into GUIPanelView with ZStack persistence"
```

---

## Task 6: Add keyboard shortcuts

**Files:**
- Modify: `Context/Sources/Context/Views/Browser/BrowserView.swift`

**Step 1: Add keyboard shortcut handlers**

Add `.onKeyPress` or use SwiftUI keyboard shortcuts on the BrowserView body. Since these are standard shortcuts (Cmd+T, Cmd+W, etc.), use `.keyboardShortcut` on hidden buttons or `.onCommand`:

Add this to the `BrowserView` body, after the `.onAppear` modifier:

```swift
        .background {
            // Hidden buttons for keyboard shortcuts
            Group {
                Button("") { viewModel.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("") {
                    if let id = viewModel.activeTabId {
                        viewModel.closeTab(id)
                    }
                }
                    .keyboardShortcut("w", modifiers: .command)
                Button("") { viewModel.activeTab?.webView.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
```

Note: Cmd+L (focus URL bar) requires `@FocusState` on the text field. Add to BrowserView:

```swift
@FocusState private var isUrlBarFocused: Bool
```

Then on the URL TextField:
```swift
.focused($isUrlBarFocused)
```

And add another hidden button:
```swift
Button("") { isUrlBarFocused = true }
    .keyboardShortcut("l", modifiers: .command)
```

**Step 2: Build and verify**

Run: `cd Context && swift build 2>&1 | tail -5`

Expected: Build succeeds.

**Step 3: Commit**

```bash
git add Context/Sources/Context/Views/Browser/BrowserView.swift
git commit -m "feat(browser): add keyboard shortcuts (Cmd+T/W/R/L)"
```

---

## Task 7: Package, test manually, and final commit

**Step 1: Build release**

Run: `cd Context && swift build -c release 2>&1 | tail -5`

Expected: Build complete with no errors.

**Step 2: Package the app**

Run: `bash scripts/package-app.sh`

Expected: `build/Scope.app` is packaged successfully.

**Step 3: Manual verification checklist**

Launch the app and verify:

- [ ] Browser tab appears in project tab bar (globe icon)
- [ ] Clicking Browser tab shows blank browser with URL bar
- [ ] Typing a URL and pressing Enter loads the page
- [ ] `localhost:3000` (or similar) loads a local dev server
- [ ] Back/Forward/Reload buttons work correctly
- [ ] "+" button creates a new browser tab
- [ ] Browser tabs show page title
- [ ] Close button (X) removes a tab
- [ ] Switching to Tasks tab and back preserves the browser page (no reload)
- [ ] Screenshot button captures and saves a PNG
- [ ] Cmd+T opens new tab, Cmd+W closes current tab
- [ ] Cmd+L focuses the URL bar

**Step 4: Final commit if any fixups needed**

```bash
git add -A
git commit -m "feat(browser): embedded WKWebView browser with multi-tab support"
```

---

## Summary of all files

### Created (4 files)
| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `Views/Browser/BrowserTab.swift` | ~70 | Tab model with KVO observation |
| `Views/Browser/BrowserViewModel.swift` | ~35 | Tab management |
| `Views/Browser/BrowserView.swift` | ~250 | Main view: nav bar, tab strip, web content |
| `Views/Browser/WebViewWrapper.swift` | ~40 | NSViewRepresentable + localhost cert handling |

### Modified (2 files)
| File | Change |
|------|--------|
| `ViewModels/AppState.swift` | Add `.browser` enum case |
| `Views/GUIPanelView.swift` | ZStack persistence + browser case in switch |

### Total estimated: ~400 lines of new code, ~20 lines modified
