# Dev Tools Enhancement — Design Document

Date: 2026-02-26

## Overview

Expand the Context app's developer tool capabilities with three Tier 1 features: a full code editor upgrade, a browser DevTools panel, and a project services hub. Tier 2 and 3 features are documented for future work.

## User Pain Points Addressed

1. **Staging URLs** — Constantly switching to browser/bookmarks to open Firebase Console, Supabase Dashboard, Vercel
2. **Quick edits** — Seeing a file in the viewer and needing to switch to a full IDE for small changes
3. **Git diffs** — No inline diff viewing for uncommitted changes
4. **Infrastructure management** — No visibility into project service status from Context

## Approved Feature Set

### Tier 1 (First Implementation Batch)

#### Feature 1: Code Editor Upgrade

**Current state:** Read-only `ScrollView` + `Text` file viewer with syntax highlighting via a regex-based highlighter.

**Target state:** Full `NSTextView`-based editor with editing, diffing, and navigation.

**Architecture:**

- Replace the existing `FileContentView` read-only text display with a new `CodeEditorView` wrapping `NSTextView` via `NSViewRepresentable`
- Use `NSTextView` (not a SwiftUI `TextEditor`) for proper monospace rendering, line numbers, and performance on large files
- Add a toggle button in the file viewer toolbar to switch between read-only and edit mode (default: read-only to prevent accidental edits)
- Save via Cmd+S keyboard shortcut, writing directly to the file on disk

**Sub-features:**

1. **Editable text with syntax highlighting** — Carry forward the existing `SyntaxHighlighter` logic, applied as `NSAttributedString` attributes on the `NSTextStorage`
2. **Line numbers gutter** — Custom `NSRulerView` subclass showing line numbers in the gutter
3. **Git diff view** — Toggle to show inline diff (insertions in green, deletions in red) by running `git diff <file>` and parsing the unified diff output. Render as colored background highlights on the relevant lines
4. **Find & Replace** — Cmd+F opens a find bar overlay. Uses `NSTextView`'s built-in find functionality (`performTextFinderAction`)
5. **Bracket matching** — On cursor placement next to a bracket, highlight the matching bracket with a subtle background color

**Files to create/modify:**
- `Views/Files/CodeEditorView.swift` — NEW: `NSViewRepresentable` wrapping `NSTextView`
- `Views/Files/CodeEditorCoordinator.swift` — NEW: `NSTextViewDelegate` coordinator handling edits, highlighting, bracket matching
- `Views/Files/DiffHighlighter.swift` — NEW: Parses `git diff` output and maps to line ranges
- `Views/Files/FileContentView.swift` — MODIFY: Add edit/view mode toggle, integrate `CodeEditorView`
- `Views/Files/LineNumberRulerView.swift` — NEW: `NSRulerView` subclass for gutter

**Data flow:**
```
FileContentView (toolbar: mode toggle, diff toggle)
  ├── Read mode: existing Text-based viewer (unchanged)
  └── Edit mode: CodeEditorView (NSTextView)
       ├── SyntaxHighlighter (existing, adapted for NSAttributedString)
       ├── LineNumberRulerView (gutter)
       ├── DiffHighlighter (optional overlay)
       └── Cmd+S → write to disk
```

**Trade-offs:**
- NSTextView adds AppKit bridging complexity but is the only viable option for a real editor on macOS
- Read-only default prevents accidental edits
- No LSP integration (that's IDE territory) — just syntax highlighting and basic navigation

---

#### Feature 2: Browser DevTools Panel

**Current state:** Browser has tab management, screenshot capture, console log popover, and accessibility tree snapshot (used by MCP). No DOM inspection UI.

**Target state:** Collapsible bottom panel with DOM inspector, computed styles, and element picker.

**Architecture:**

- Add a resizable bottom panel to `BrowserView` (similar to Chrome DevTools docking)
- Panel has tabs: Elements, Styles, Box Model
- Element picker mode: inject JS to highlight hovered elements and capture selection
- Selected element details fetched via `evaluateJavaScript` on the active `WKWebView`

**Sub-features:**

1. **Elements tab** — Tree view of the DOM around the selected element. Uses JS injection (`document.querySelector` + tree walking) to fetch a subtree. Shows tag name, id, classes, key attributes. Clicking a node in the tree updates selection.
2. **Styles tab** — `window.getComputedStyle()` results for the selected element. Grouped by category (typography, layout, colors, spacing). Searchable.
3. **Box Model visualization** — Classic box model diagram showing margin/border/padding/content dimensions. Rendered as a SwiftUI view with nested colored rectangles.
4. **Element picker** — Toggle button that injects a JS overlay into the page. On hover, highlights elements with a blue outline. On click, captures the element's CSS selector and fetches its details. Uses `WKScriptMessageHandler` to communicate selection back to Swift.
5. **ax-ref integration** — When an element is selected in DevTools, show its `data-ax-ref` attribute (from the accessibility tree snapshot) so users can reference it in MCP commands.

**Files to create/modify:**
- `Views/Browser/DevToolsPanel.swift` — NEW: Main panel container with tab switching
- `Views/Browser/DevToolsElementsTab.swift` — NEW: DOM tree view
- `Views/Browser/DevToolsStylesTab.swift` — NEW: Computed styles list
- `Views/Browser/DevToolsBoxModel.swift` — NEW: Box model diagram
- `Views/Browser/ElementPicker.swift` — NEW: JS injection + message handler for element picking
- `Views/Browser/BrowserView.swift` — MODIFY: Add collapsible bottom panel
- `Views/Browser/BrowserTab.swift` — MODIFY: Add JS evaluation helpers for DevTools queries

**JS injection approach:**
```javascript
// Element picker overlay (injected into WKWebView)
// Highlights hovered elements, sends selection back via messageHandler
document.addEventListener('mouseover', (e) => {
    // highlight logic
    window.webkit.messageHandlers.devtools.postMessage({
        type: 'hover',
        selector: getCSSSelector(e.target),
        rect: e.target.getBoundingClientRect()
    });
});
```

**Data flow:**
```
BrowserView
  ├── WebViewWrapper (existing)
  └── DevToolsPanel (collapsible, resizable)
       ├── Elements tab ←→ JS injection (DOM tree)
       ├── Styles tab ←→ getComputedStyle() via JS
       ├── Box Model ←→ getBoundingClientRect() via JS
       └── Element Picker toggle → injects overlay JS
            └── WKScriptMessageHandler → updates selection
```

**Trade-offs:**
- JS injection can break on sites with strict CSP — acceptable since these are dev tools for dev sites
- No network tab in this tier (deferred to Tier 2)
- Read-only inspection only — no live CSS editing (would add significant complexity)

---

#### Feature 3: Project Services Hub

**Current state:** No awareness of external services. Users manually open Firebase Console, Supabase Dashboard, Vercel, etc.

**Target state:** Auto-detected service panel with deep links, status indicators, and environment variable viewing.

**Architecture:**

- New tab/section in the GUI panel (alongside existing GitHub, Sessions, etc.)
- On project load, scan for config files that indicate connected services
- Display detected services with one-click deep links to their dashboards
- Show environment variables from `.env` files (masked by default)

**Service detection rules:**

| Service | Detection | Deep Link |
|---------|-----------|-----------|
| Firebase | `firebase.json` or `.firebaserc` | `https://console.firebase.google.com/project/{projectId}` |
| Supabase | `supabase/config.toml` or `.env` with `SUPABASE_URL` | Extract project ref from URL → `https://supabase.com/dashboard/project/{ref}` |
| Vercel | `vercel.json` or `.vercel/project.json` | `https://vercel.com/{org}/{project}` |
| Netlify | `netlify.toml` | `https://app.netlify.com` (generic, or parse site ID) |
| AWS Amplify | `amplify/` directory | `https://console.aws.amazon.com/amplify` |
| Docker | `docker-compose.yml` or `Dockerfile` | Show compose services status |
| Railway | `railway.toml` | `https://railway.app/dashboard` |

**Sub-features:**

1. **Auto-detection** — Scan project root for config files on project load. Cache results, re-scan on file system changes.
2. **Service cards** — Each detected service shows: icon, name, project ID (if extractable), and "Open Dashboard" button that opens in the embedded browser or system browser.
3. **Environment viewer** — Parse `.env`, `.env.local`, `.env.development`, etc. Show key-value pairs with values masked by default. Click to reveal. Grouped by file.
4. **Quick actions** — Per-service contextual actions: "Open Console", "View Logs", "Deploy" (where applicable via CLI detection).

**Files to create/modify:**
- `Services/ProjectServicesDetector.swift` — NEW: Scans project directory for service configs
- `Models/DetectedService.swift` — NEW: Model for detected services (name, type, config, deepLink URL)
- `Views/Services/ProjectServicesView.swift` — NEW: Main services hub view
- `Views/Services/ServiceCard.swift` — NEW: Individual service card component
- `Views/Services/EnvironmentViewer.swift` — NEW: .env file viewer with masking
- `Views/GUIPanelView.swift` — MODIFY: Add Services tab

**Data flow:**
```
ProjectWindowView.loadProject()
  → ProjectServicesDetector.scan(projectPath:)
     → reads firebase.json, supabase/config.toml, .env, etc.
     → returns [DetectedService]

ProjectServicesView
  ├── ServiceCard (Firebase) → "Open Dashboard" → NSWorkspace.open(deepLink)
  ├── ServiceCard (Supabase) → "Open Dashboard" → embedded browser
  ├── ...
  └── EnvironmentViewer
       ├── .env (key=•••••, click to reveal)
       ├── .env.local
       └── .env.development
```

**Trade-offs:**
- Deep links depend on extractable project IDs from config files — some services may only get generic dashboard links
- Environment viewer shows secrets on click — acceptable for a local dev tool, but values are masked by default
- No write capability for env vars (read-only viewer)

---

### Tier 2 (Future)

#### Feature 4: Git Changes Overview
Working tree status panel showing modified/staged/untracked files. Inline diffs per file. Stage/unstage individual files. Commit message composer. Uses `git` CLI under the hood.

#### Feature 5: Network Inspector
Intercept `fetch()` and `XMLHttpRequest` calls in the browser via JS injection. Show request method, URL, status, timing, headers, and response body. Filter by type (XHR, fetch, WS). Pairs with DevTools panel.

#### Feature 6: Environment Builder
Template-based `.env` file generation. Define required variables per environment (dev, staging, production). Secret management with encrypted local storage. One-click environment switching.

### Tier 3 (Future)

#### Feature 7: Terminal Output Parser
Parse terminal output for structured data: test results (pass/fail counts), build errors (file:line clickable links), deployment URLs. Show summary badges in the terminal tab header.

#### Feature 8: Snippet Library
Project-scoped code snippets. Save/retrieve/search. Tag-based organization. Quick insert into terminal as Claude context. Stored in SQLite alongside other project data.

## Implementation Priority

**Recommended order within Tier 1:**
1. **Code Editor Upgrade** — Most self-contained, touches the file viewer only
2. **Project Services Hub** — New feature, minimal coupling to existing code
3. **Browser DevTools Panel** — Most complex, benefits from having the editor and services done first

Each feature is independently shippable — no cross-dependencies between the three.

## Verification

1. **Code Editor:** Open a file → toggle edit mode → make changes → Cmd+S → verify file saved. Toggle diff view → see highlighted changes. Cmd+F → find text.
2. **DevTools:** Open browser → load a page → toggle DevTools panel → click element picker → hover/click elements → verify DOM tree, styles, and box model update.
3. **Services Hub:** Open a project with `firebase.json` → verify Firebase detected → click "Open Dashboard" → verify correct URL opens. Check `.env` viewer shows masked values.
