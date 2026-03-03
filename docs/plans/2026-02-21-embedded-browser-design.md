# Embedded Browser — Design Document

## Summary

Add a WKWebView-based browser as a tab in the right GUI panel. Supports multi-tab browsing, persistent state across tab switches, localhost dev server preview, and screenshot capture to task attachments.

## Motivation

The Context app's right panel provides project-level views (Tasks, Dashboard, Notes, etc.) but lacks a way to preview local dev servers, test web apps, or reference documentation without leaving the app. An embedded browser fills this gap with zero new dependencies.

## Approach

**WKWebView** (Apple's native web engine) wrapped in `NSViewRepresentable`. Chosen over CEF/Chromium (100MB+ dependency, C++ bridge complexity) and Electron sidecar (separate process, IPC overhead). WKWebView covers all stated use cases — localhost preview, web app testing, reference browsing — with no additional dependencies.

Chrome extension support is out of scope. If needed later, a CEF migration path exists.

## Architecture

### New Tab: `.browser`

Add `case browser = "Browser"` to `AppState.GUITab` with a `globe` icon. Appears in the tab bar alongside Tasks, Dashboard, etc. Available in both project mode and planner/home mode.

### Components

```
BrowserView          — Top-level view: nav bar + tab strip + web content
BrowserViewModel     — ObservableObject managing tab array and active tab
BrowserTab           — Model: id, WKWebView instance, title, URL, isLoading
WebViewWrapper       — NSViewRepresentable bridging WKWebView to SwiftUI
```

### BrowserTab Model

```swift
class BrowserTab: Identifiable, ObservableObject {
    let id = UUID()
    let webView: WKWebView
    @Published var title: String = "New Tab"
    @Published var url: URL?
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
}
```

Each tab owns a `WKWebView` instance. The view model holds an array of tabs and an `activeTabId`.

### BrowserViewModel

```swift
class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?

    func newTab()               // Create blank tab, set active
    func closeTab(_ id: UUID)   // Remove tab, select adjacent
    func navigate(to url: URL)  // Load URL in active tab
    func goBack()
    func goForward()
    func reload()
    func takeScreenshot() async -> NSImage?
}
```

### Persistence Strategy

WKWebView instances persist in memory using the **ZStack opacity pattern** (same approach the app uses for terminal persistence). When switching GUI tabs away from Browser, the WKWebViews remain alive — no reload on return.

Within the browser tab, switching between browser tabs also uses ZStack opacity so all pages stay loaded.

### UI Layout

```
┌─────────────────────────────────────────┐
│ [<] [>] [↻]  [ URL bar .............. ] │  ← Nav bar
├─────────────────────────────────────────┤
│ [Tab 1] [Tab 2] [Tab 3]            [+] │  ← Tab strip
├─────────────────────────────────────────┤
│                                         │
│              WKWebView                  │  ← Web content
│            (active tab)                 │
│                                         │
└─────────────────────────────────────────┘
```

**Nav bar:**
- Back / Forward / Reload buttons (disabled when not applicable)
- URL text field — shows current URL, editable, Enter navigates
- Screenshot button (camera icon) — captures page to temp file

**Tab strip:**
- Horizontal scroll of tab chips: page title (truncated) + close (X) button
- "+" button to open a new tab
- Active tab highlighted with accent color

**Web content:**
- ZStack of all WKWebViews, active tab at opacity 1, others at 0

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+T | New tab |
| Cmd+W | Close current tab |
| Cmd+L | Focus URL bar |
| Cmd+R | Reload |
| Cmd+[ | Back |
| Cmd+] | Forward |

### Screenshot Capture

WKWebView provides `takeSnapshot(with:completionHandler:)`. The screenshot flow:

1. User clicks camera icon in nav bar
2. `webView.takeSnapshot()` returns an `NSImage`
3. Save as PNG to `~/Library/Application Support/Context/browser-screenshots/`
4. File path is available to attach to a task via the existing attachments system

### Localhost / Self-Signed Cert Handling

Implement `WKNavigationDelegate.webView(_:didReceive:completionHandler:)` to accept self-signed certificates for `localhost` and `127.0.0.1` origins. This is essential for local dev servers using HTTPS.

### New Tab Default

Opens blank with URL bar focused. No start page, no bookmarks grid (can add later).

## Files to Create

| File | Purpose |
|------|---------|
| `Views/Browser/BrowserView.swift` | Main browser view with nav bar, tab strip, content |
| `Views/Browser/WebViewWrapper.swift` | NSViewRepresentable for WKWebView |
| `ViewModels/BrowserViewModel.swift` | Tab management, navigation, screenshots |

## Files to Modify

| File | Change |
|------|--------|
| `ViewModels/AppState.swift` | Add `.browser` case to `GUITab` |
| `Views/GUIPanelView.swift` | Add `.browser` case to tab content switch, persist BrowserView |

## Dependencies

None. `WebKit` is a system framework — just `import WebKit`.

## Future Enhancements (Out of Scope for v1)

- Per-project URL bookmarks
- "Open in Browser" button on tasks with URLs
- JavaScript console log viewer
- Network activity monitor
- Chrome extension support via CEF migration
