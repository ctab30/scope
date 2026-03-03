# Browser MCP Tools — Phase 1 Design

**Date:** 2026-02-22
**Status:** Approved
**Scope:** Read-only browser control via MCP tools

## Overview

Add 9 read-only browser MCP tools to the existing ScopeMCP binary, enabling Claude Code to navigate, read, and inspect pages in Context's built-in WKWebView browser. No clicking, form filling, or page interaction — Claude can research and read but not act.

This is Phase 1 of a multi-phase plan:
- **Phase 1 (this):** Read-only browser tools via MCP
- **Phase 2:** Basic interaction (click, fill, select) with permission gates
- **Phase 3:** Agentic task mode with 4-tier permission system
- **Phase 4:** Multi-service workflows

## Architecture

### Data Flow

```
Claude Code (CLI)
    ↕  stdio JSON-RPC
ScopeMCP (existing binary, expanded)
    │
    ├── Task/Note tools → read/write taskItems, notes tables (existing)
    │
    └── Browser tools → write to `browserCommands` table (NEW)
                              ↓
                    GRDB ValueObservation (NEW)
                              ↓
                    Scope.app GUI process
                         BrowserCommandExecutor (NEW service)
                              ↓
                         callAsyncJavaScript (in .defaultClient content world)
                              ↓
                         WKWebView (existing)
                              ↓
                         Result written to browserCommands.result column
                              ↓
                    ScopeMCP polls for result (50ms interval, 15s timeout)
                              ↓
                    Returns result to Claude Code
```

### IPC Mechanism: Shared SQLite

Both processes already share `~/Library/Application Support/Context/context.db`. Browser commands use the same pattern: ScopeMCP writes a command row, the GUI app observes it via GRDB `ValueObservation`, executes it, and writes the result back to the same row.

**Trade-offs accepted:**
- ~100-500ms latency per round-trip (acceptable for read-only tools)
- Polling required on ScopeMCP side (50ms intervals, negligible CPU)
- Zero new dependencies, matches existing architecture

## Database Schema

### New Table: `browserCommands`

```sql
CREATE TABLE browserCommands (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tool TEXT NOT NULL,
    args TEXT,                -- JSON string
    status TEXT NOT NULL,     -- pending, executing, completed, error
    result TEXT,              -- JSON string
    createdAt DATETIME NOT NULL,
    completedAt DATETIME
);
```

### Row Lifecycle

1. ScopeMCP inserts: `status = "pending"`, `tool`, `args`, `createdAt`
2. GUI sets: `status = "executing"`
3. GUI sets: `status = "completed"` or `"error"`, `result`, `completedAt`
4. ScopeMCP reads result and returns to Claude
5. Cleanup job deletes completed rows older than 1 hour

### Model

```swift
struct BrowserCommand: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var tool: String
    var args: String?       // JSON
    var status: String      // pending, executing, completed, error
    var result: String?     // JSON
    var createdAt: Date
    var completedAt: Date?
    static let databaseTableName = "browserCommands"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

## MCP Tool Definitions

All tools added to existing ScopeMCP binary. `tools/list` returns all 26 tools (17 existing + 9 new).

### 1. `browser_navigate`

Navigate the active tab to a URL. Opens a new tab if none exist.

```json
{
    "name": "browser_navigate",
    "description": "Navigate the browser to a URL. Opens a new tab if none are open. Waits for page load to complete.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "url": { "type": "string", "description": "URL to navigate to" }
        },
        "required": ["url"]
    }
}
```

**Returns:** `{ "url": "https://...", "title": "Page Title", "status": "loaded" }`
**Timeout:** 15 seconds (pages can be slow)
**GUI handler:** Calls `BrowserTab.navigate(to:)`, waits for `WKNavigationDelegate.didFinish`

### 2. `browser_snapshot`

Get a compact accessibility tree representation of the current page. This is the primary way Claude "sees" page structure.

```json
{
    "name": "browser_snapshot",
    "description": "Get the accessibility tree of the current page as compact structured text. Returns ARIA roles, labels, and interactive element refs. This is the primary tool for understanding page content and structure.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "tab_id": { "type": "string", "description": "Tab ID (defaults to active tab)" }
        }
    }
}
```

**Returns:** YAML-like accessibility tree string, e.g.:
```
- document
  - banner
    - heading "My App" [level=1]
    - navigation
      - link "Home" [ref=e1]
      - link "About" [ref=e2]
  - main
    - region "Search"
      - textbox "Search query" [ref=e3] [focused]
      - button "Submit" [ref=e4]
```

**GUI handler:** Injects accessibility tree serializer JS via `callAsyncJavaScript` in `.defaultClient` content world. Refs are stamped as `data-ax-ref` attributes on interactive elements (useful for Phase 2 click-by-ref).

### 3. `browser_extract`

Extract text content from a specific element by CSS selector.

```json
{
    "name": "browser_extract",
    "description": "Extract text content from a page element using a CSS selector. Returns the text content of the matched element.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "selector": { "type": "string", "description": "CSS selector to find the element" },
            "tab_id": { "type": "string", "description": "Tab ID (defaults to active tab)" }
        },
        "required": ["selector"]
    }
}
```

**Returns:** `{ "text": "...", "found": true }` or `{ "found": false, "error": "No element matches selector" }`
**GUI handler:** `callAsyncJavaScript("return document.querySelector(selector)?.textContent", arguments: ["selector": selector])`

### 4. `browser_list_tabs`

List all open browser tabs with their current state.

```json
{
    "name": "browser_list_tabs",
    "description": "List all open browser tabs with their URLs, titles, and loading state.",
    "inputSchema": {
        "type": "object",
        "properties": {}
    }
}
```

**Returns:** `[{ "id": "uuid", "title": "...", "url": "...", "isActive": true, "isLoading": false }]`

### 5. `browser_console_logs`

Get console log entries from a tab.

```json
{
    "name": "browser_console_logs",
    "description": "Get JavaScript console log entries (log, warn, error, info) from a browser tab. Useful for debugging web applications.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "tab_id": { "type": "string", "description": "Tab ID (defaults to active tab)" },
            "level": { "type": "string", "description": "Filter by level: log, warn, error, info", "enum": ["log", "warn", "error", "info"] }
        }
    }
}
```

**Returns:** `[{ "level": "error", "message": "...", "timestamp": "..." }]`

### 6. `browser_screenshot`

Take a screenshot of the current page.

```json
{
    "name": "browser_screenshot",
    "description": "Take a screenshot of the current page and save it as a PNG file. Returns the file path so you can read the image.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "tab_id": { "type": "string", "description": "Tab ID (defaults to active tab)" }
        }
    }
}
```

**Returns:** `{ "path": "/Users/.../browser-screenshots/screenshot-2026-02-22.png", "width": 1920, "height": 1080 }`
**GUI handler:** Calls `WKWebView.takeSnapshot()` (existing pattern from `BrowserView.swift`), saves PNG, records in `browserScreenshots` table.

### 7. `browser_tab_open`

Open a new browser tab, optionally navigating to a URL.

```json
{
    "name": "browser_tab_open",
    "description": "Open a new browser tab. Optionally navigate to a URL.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "url": { "type": "string", "description": "URL to navigate to (optional)" }
        }
    }
}
```

**Returns:** `{ "tab_id": "uuid", "url": "...", "title": "..." }`

### 8. `browser_tab_close`

Close a browser tab by ID.

```json
{
    "name": "browser_tab_close",
    "description": "Close a browser tab by its ID.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "tab_id": { "type": "string", "description": "ID of the tab to close" }
        },
        "required": ["tab_id"]
    }
}
```

**Returns:** `{ "closed": true, "remaining_tabs": 2 }`

### 9. `browser_tab_switch`

Switch the active browser tab.

```json
{
    "name": "browser_tab_switch",
    "description": "Switch the active browser tab to the specified tab.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "tab_id": { "type": "string", "description": "ID of the tab to switch to" }
        },
        "required": ["tab_id"]
    }
}
```

**Returns:** `{ "active_tab": "uuid", "title": "...", "url": "..." }`

## New Components

### 1. BrowserCommandExecutor (NEW service)

**File:** `Sources/Context/Services/BrowserCommandExecutor.swift`

Responsibilities:
- Observes `browserCommands` table for `status = "pending"` rows via GRDB `ValueObservation`
- Dispatches each command to the appropriate handler method
- Executes JavaScript on WKWebView via `callAsyncJavaScript` in `.defaultClient` content world
- Writes results back to the same row
- Runs cleanup of completed rows older than 1 hour

Requires reference to `BrowserViewModel` (for tab access and WKWebView instances).

**Initialization:** Created during window setup, alongside `BrowserViewModel`. Starts observation immediately.

### 2. Accessibility Tree Serializer (JS constant)

**Location:** String constant in `BrowserCommandExecutor.swift` or a dedicated `BrowserAutomationJS.swift` file.

~80 lines of JavaScript that:
- Walks the DOM tree
- Maps HTML tags to implicit ARIA roles
- Reads explicit ARIA attributes (role, label, labelledby, expanded, checked, etc.)
- Identifies interactive elements (links, buttons, inputs, selects) and stamps them with `data-ax-ref` attributes
- Identifies structural landmarks (nav, main, header, footer, regions, lists, headings)
- Skips hidden elements (display:none, visibility:hidden, aria-hidden)
- Pierces open shadow DOM roots
- Returns a compact YAML-like string

Runs in `.defaultClient` content world — invisible to page scripts, bypasses CSP.

### 3. ScopeMCP Browser Command Helper

**Location:** Added to `Sources/ScopeMCP/main.swift`

Shared helper used by all 9 browser tools:

```swift
func executeBrowserCommand(tool: String, args: [String: Any],
                           timeout: TimeInterval = 5.0) throws -> String {
    // 1. Insert row with status = "pending"
    // 2. Poll every 50ms for status change
    // 3. Return result or throw on timeout/error
}
```

Navigation commands use a 15s timeout. All others use 5s.

**Edge case — GUI not running:** If the command stays `pending` past the timeout, return: `"Error: Scope.app is not running or the browser tab is not available. Open Scope.app to use browser tools."`

## Modified Files

| File | Change | ~Lines |
|------|--------|--------|
| `Sources/ScopeMCP/main.swift` | Add 9 tool definitions, 9 handlers, `executeBrowserCommand` helper, `BrowserCommand` model | +200 |
| `Sources/Context/Services/DatabaseService.swift` | Add `browserCommands` table migration | +15 |
| `Sources/Context/Services/BrowserCommandExecutor.swift` | **NEW** — command observer, dispatcher, JS execution | +250 |
| `Sources/Context/Views/Browser/BrowserTab.swift` | Add `snapshotAccessibilityTree()` and `extractText(selector:)` async methods | +30 |
| `Sources/Context/Views/Browser/BrowserViewModel.swift` | Add `tab(byId:)`, expose tab management for external callers | +20 |
| `Sources/Context/Views/Browser/BrowserView.swift` | Initialize `BrowserCommandExecutor` on appear | +10 |

**Total: ~525 lines of new code, 5 modified files, 1 new file.**

## ScopeMCP Polling Design

ScopeMCP runs a synchronous `readLine()` loop. When a browser tool is called:

```
1. INSERT INTO browserCommands (tool, args, status, createdAt) VALUES (...)
2. Get the inserted row ID
3. Loop:
   a. Thread.sleep(forTimeInterval: 0.05)  // 50ms
   b. SELECT status, result FROM browserCommands WHERE id = ?
   c. If status == "completed" → parse result JSON, return to Claude
   d. If status == "error" → return error message to Claude
   e. If elapsed > timeout → return timeout error
4. DELETE FROM browserCommands WHERE id = ?  // cleanup after reading
```

50ms polling × 15s timeout = max 300 iterations. Each is a trivial SQLite read. No meaningful CPU impact.

## Security Considerations

### Phase 1 is read-only — minimal risk

- No form filling, clicking, or page modification
- No credentials or authentication handling
- The accessibility tree serializer runs in `.defaultClient` content world (page JS cannot see or interfere with it)
- CSP on target pages does not affect injected scripts
- Console log capture already exists and is proven safe

### Forward-looking (Phase 2+)

Phase 1 sets up the `data-ax-ref` stamping mechanism that Phase 2 will use for click-by-ref. The accessibility tree serializer intentionally stamps interactive elements now so the infrastructure is ready.

The `browserCommands` table design supports future action types without schema changes — just new `tool` values and corresponding handlers.

## Example Sessions After Implementation

### Inspecting a staging site
```
User: "What's on the homepage of my staging site?"

Claude: [calls browser_navigate("https://staging.myapp.com")]
        [calls browser_snapshot()]

"Your staging site shows a login form with email and password fields,
 a 'Sign up' link in the nav, and the page title is 'MyApp - Staging'."

User: "Any errors?"

Claude: [calls browser_console_logs()]

"3 console errors:
 1. Failed to fetch /api/v2/config - 404
 2. TypeError: Cannot read property 'user' of undefined
 3. CORS policy blocked request to analytics.myapp.com"
```

### Researching documentation
```
User: "Look up the Stripe API for creating payment intents"

Claude: [calls browser_tab_open("https://stripe.com/docs/api/payment_intents/create")]
        [calls browser_snapshot()]
        [calls browser_extract(".method-area")]

"Here's what the Stripe docs say about PaymentIntent.create: ..."
```

### Multi-tab research
```
User: "Compare the pricing pages of Vercel and Netlify"

Claude: [calls browser_tab_open("https://vercel.com/pricing")]
        [calls browser_snapshot()]
        [calls browser_tab_open("https://netlify.com/pricing")]
        [calls browser_snapshot()]

"Here's a comparison:
 Vercel: Pro plan $20/user/month, ...
 Netlify: Pro plan $19/user/month, ..."
```

## Out of Scope (Phase 2+)

- Clicking / form interaction (`browser_click`, `browser_fill`, `browser_select`)
- Permission tier system (4-tier confirmation gates)
- Prompt injection defenses (content sanitization, alignment critic)
- Session isolation per agent task
- Domain allowlisting
- Agentic task orchestration mode
- Persistent login sessions
