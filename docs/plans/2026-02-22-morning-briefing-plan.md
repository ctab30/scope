# Morning Briefing Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an AI-powered daily intelligence briefing that fetches dev/AI news from free public APIs, synthesizes it with Claude, and presents a ranked digest in a side drawer with notification bell.

**Architecture:** Swift fetches raw items from HN Algolia, Reddit JSON, and RSS feeds in parallel. Items are deduplicated and sent to Claude CLI (`claude -p`) for synthesis/ranking. Results saved to GRDB database and displayed in a side drawer toggled by a bell icon in the GUI panel header.

**Tech Stack:** Swift, SwiftUI, GRDB, Foundation (URLSession + XMLParser), Claude CLI

**Design Doc:** `docs/plans/2026-02-22-morning-briefing-design.md`

---

### Task 1: Database Migration — Briefing Tables

**Files:**
- Modify: `Sources/Context/Services/DatabaseService.swift` (add migration after line ~300, the v15 block)

**Context:**
- Migrations are sequential: currently at `v15_createContextEngine`
- Pattern: `migrator.registerMigration("v16_name") { db in ... }`
- Uses GRDB's `db.create(table:)` API

**Step 1: Add v16 migration for briefingDigests and briefingItems tables**

Add after the `v15_createContextEngine` migration block:

```swift
migrator.registerMigration("v16_createBriefing") { db in
    try db.create(table: "briefingDigests") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("generatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("itemCount", .integer).notNull().defaults(to: 0)
        t.column("status", .text).notNull().defaults(to: "generating")
    }

    try db.create(table: "briefingItems") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("digestId", .integer).notNull()
            .references("briefingDigests", onDelete: .cascade)
        t.column("title", .text).notNull()
        t.column("summary", .text).notNull()
        t.column("category", .text).notNull()
        t.column("sourceUrl", .text).notNull()
        t.column("sourceName", .text).notNull()
        t.column("publishedAt", .datetime)
        t.column("relevanceScore", .integer).notNull().defaults(to: 5)
        t.column("isSaved", .boolean).notNull().defaults(to: false)
        t.column("isRead", .boolean).notNull().defaults(to: false)
    }
}
```

**Step 2: Build to verify migration compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Services/DatabaseService.swift
git commit -m "feat(briefing): add v16 migration for briefingDigests and briefingItems tables"
```

---

### Task 2: GRDB Models — BriefingDigest and BriefingItem

**Files:**
- Create: `Sources/Context/Models/BriefingModels.swift`

**Context:**
- Follow `TaskItem.swift` pattern: `Codable, Identifiable, FetchableRecord, MutablePersistableRecord`
- Use `didInsert(_ inserted: InsertionSuccess)` for auto-increment IDs
- `static let databaseTableName` maps to table name

**Step 1: Create BriefingModels.swift with both structs**

```swift
import Foundation
import GRDB

struct BriefingDigest: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var generatedAt: Date
    var itemCount: Int
    var status: String // "generating", "ready", "failed"

    static let databaseTableName = "briefingDigests"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let items = hasMany(BriefingItem.self, using: BriefingItem.digestForeignKey)
}

struct BriefingItem: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var digestId: Int64
    var title: String
    var summary: String
    var category: String
    var sourceUrl: String
    var sourceName: String
    var publishedAt: Date?
    var relevanceScore: Int
    var isSaved: Bool
    var isRead: Bool

    static let databaseTableName = "briefingItems"
    static let digestForeignKey = ForeignKey(["digestId"])

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

**Step 2: Build to verify models compile**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Models/BriefingModels.swift
git commit -m "feat(briefing): add BriefingDigest and BriefingItem GRDB models"
```

---

### Task 3: NewsFetcher — Raw Item Fetching from HN, Reddit, RSS

**Files:**
- Create: `Sources/Context/Services/Briefing/NewsFetcher.swift`

**Context:**
- All APIs are free, no keys needed
- HN Algolia: `https://hn.algolia.com/api/v1/search_by_date?tags=story&hitsPerPage=30`
- Reddit: Append `.json` to subreddit URL, e.g. `https://www.reddit.com/r/programming/top/.json?t=day&limit=25`
- RSS: Standard XML, parse with Foundation's `XMLParser`
- Use `URLSession.shared.data(from:)` for all fetches
- Use `TaskGroup` to fetch all sources in parallel

**Step 1: Create the NewsFetcher enum with RawNewsItem struct and parallel fetch**

The file should contain:

1. `RawNewsItem` struct with: `title`, `url`, `sourceName`, `snippet` (optional), `publishedAt` (optional)

2. `NewsFetcher` enum with static methods:
   - `fetchAll(rssFeeds:subreddits:)` — orchestrates parallel fetch via TaskGroup, returns `[RawNewsItem]`
   - `fetchHackerNews()` — calls HN Algolia API, parses JSON, returns `[RawNewsItem]`
   - `fetchReddit(subreddits:)` — calls Reddit JSON API for each subreddit, returns `[RawNewsItem]`
   - `fetchRSSFeeds(urls:)` — parses each RSS feed URL, returns `[RawNewsItem]`
   - `deduplicateAndCap(_:limit:)` — deduplicates by URL, caps at limit (default 80)

3. Private `RSSParser: NSObject, XMLParserDelegate` class for RSS/Atom parsing

**Key implementation details:**

For HN Algolia, the JSON response shape is:
```json
{ "hits": [{ "title": "...", "url": "...", "story_text": "...", "created_at": "..." }] }
```
Items without a `url` should use `https://news.ycombinator.com/item?id=\(objectID)`.

For Reddit, the JSON response shape is:
```json
{ "data": { "children": [{ "data": { "title": "...", "url": "...", "selftext": "...", "created_utc": 123 } }] } }
```
Set User-Agent to `"Context/1.0"` to avoid Reddit 429s.

For RSS, parse `<item>` (RSS 2.0) or `<entry>` (Atom) elements. Extract `<title>`, `<link>`, `<description>`/`<summary>`, `<pubDate>`/`<updated>`.

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Services/Briefing/NewsFetcher.swift
git commit -m "feat(briefing): add NewsFetcher with HN, Reddit, and RSS fetching"
```

---

### Task 4: AppSettings — Briefing Configuration Properties

**Files:**
- Modify: `Sources/Context/Services/AppSettings.swift`

**Context:**
- Follow existing pattern: `@Published var x { didSet { UserDefaults.standard.set(...) } }`
- Init reads from `UserDefaults.standard` with fallback defaults
- Keep alphabetical grouping or add at end

**Step 1: Add briefing settings properties**

Add these published properties to `AppSettings`:

```swift
// Briefing
@Published var briefingStalenessHours: Double {
    didSet { UserDefaults.standard.set(briefingStalenessHours, forKey: "briefingStalenessHours") }
}
@Published var briefingRSSFeeds: [String] {
    didSet {
        if let data = try? JSONEncoder().encode(briefingRSSFeeds) {
            UserDefaults.standard.set(data, forKey: "briefingRSSFeeds")
        }
    }
}
@Published var briefingSubreddits: [String] {
    didSet {
        if let data = try? JSONEncoder().encode(briefingSubreddits) {
            UserDefaults.standard.set(data, forKey: "briefingSubreddits")
        }
    }
}
```

Add to `init()`:

```swift
self.briefingStalenessHours = defaults.object(forKey: "briefingStalenessHours") as? Double ?? 6.0

if let feedData = defaults.data(forKey: "briefingRSSFeeds"),
   let feeds = try? JSONDecoder().decode([String].self, from: feedData) {
    self.briefingRSSFeeds = feeds
} else {
    self.briefingRSSFeeds = [
        "https://www.anthropic.com/feed",
        "https://openai.com/blog/rss.xml",
        "https://blog.google/technology/ai/rss/",
        "https://simonwillison.net/atom/everything/",
        "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml",
        "https://techcrunch.com/category/artificial-intelligence/feed/",
        "https://blog.langchain.dev/rss/",
        "https://huggingface.co/blog/feed.xml",
    ]
}

if let subData = defaults.data(forKey: "briefingSubreddits"),
   let subs = try? JSONDecoder().decode([String].self, from: subData) {
    self.briefingSubreddits = subs
} else {
    self.briefingSubreddits = ["programming", "MachineLearning", "LocalLLaMA"]
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Services/AppSettings.swift
git commit -m "feat(briefing): add briefing configuration to AppSettings"
```

---

### Task 5: BriefingService — Orchestrator with Claude Synthesis

**Files:**
- Create: `Sources/Context/Services/Briefing/BriefingService.swift`

**Context:**
- Follow `GmailPoller.swift` pattern: `@MainActor class BriefingService: ObservableObject`
- Claude CLI call follows `EmailTriageService.swift` pattern: `Process()` with `claude -p --output-format text`, pipe prompt via stdin
- Reuse the same `findClaudeBinary()` logic from `EmailTriageService.swift` (copy the helper — it's a private static method there)
- Service needs access to `AppSettings` for staleness threshold and feed config

**Step 1: Create BriefingService.swift**

The service should contain:

1. Published state:
   ```swift
   @Published var isGenerating = false
   @Published var latestDigest: BriefingDigest?
   @Published var unreadCount: Int = 0
   ```

2. `checkAndGenerate(settings:)` — called on app launch:
   - Query latest digest from DB
   - If none exists or `generatedAt` is older than `settings.briefingStalenessHours`, call `generateNow(settings:)`
   - Otherwise, load it and update `unreadCount`

3. `generateNow(settings:) async` — manual refresh:
   - Set `isGenerating = true`
   - Create a `BriefingDigest` with status "generating", save to DB
   - Call `NewsFetcher.fetchAll(rssFeeds:subreddits:)` (pass settings values)
   - Call `synthesizeWithClaude(_:)` on the raw items
   - Parse Claude's JSON response into `[BriefingItem]`
   - Save items to DB, update digest status to "ready" and itemCount
   - Update `latestDigest` and `unreadCount`
   - Set `isGenerating = false`

4. `synthesizeWithClaude(_: [RawNewsItem]) -> [BriefingItem]` (private):
   - Build a prompt with all headlines + snippets
   - Prompt asks Claude to: rank by relevance to a dev agency owner, pick top 15, write 2-sentence summaries, categorize each, return JSON
   - Expected JSON format per item: `{ "title", "summary", "category", "sourceUrl", "sourceName", "relevanceScore" }`
   - Call `claude -p --output-format text` via `Process()`, pipe prompt via stdin
   - Parse JSON response, return `[BriefingItem]`
   - If Claude fails, return empty array and set digest status to "failed"

5. `loadLatestDigest()` — reads from DB, updates published state

6. `markAsRead(itemId:)` — sets `isRead = true` in DB, decrements `unreadCount`

7. `toggleSaved(itemId:)` — toggles `isSaved` in DB

8. Private `findClaudeBinary() -> String?` — same implementation as `EmailTriageService.findClaudeBinary()`

**Claude prompt template:**
```
You are curating a daily tech briefing for a developer/agency owner.

Here are today's raw news items:

[ITEMS]

Instructions:
1. Select the top 15 most relevant items for someone who runs a dev agency and cares about AI, dev tools, and programming innovation.
2. For each selected item, write a 2-sentence summary.
3. Categorize each into one of: "AI Tools", "Agentic", "Dev Tools", "Programming", "Industry", "Open Source"
4. Rank by relevance (10 = must-read, 1 = nice-to-know)

Return ONLY a JSON array. Each object:
{
  "title": "string",
  "summary": "string",
  "category": "string",
  "sourceUrl": "string",
  "sourceName": "string",
  "relevanceScore": number
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Services/Briefing/BriefingService.swift
git commit -m "feat(briefing): add BriefingService orchestrator with Claude synthesis"
```

---

### Task 6: BriefingBellView — Notification Bell Icon

**Files:**
- Create: `Sources/Context/Views/Briefing/BriefingBellView.swift`

**Context:**
- This is a small SwiftUI view: bell icon with an unread count badge
- Clicking it toggles a `Binding<Bool>` that controls the drawer
- Orange badge when unread > 0, gray otherwise
- Goes in the GUIPanelView header HStack (integrated in Task 8)

**Step 1: Create BriefingBellView.swift**

```swift
import SwiftUI

struct BriefingBellView: View {
    @EnvironmentObject var briefingService: BriefingService
    @Binding var showDrawer: Bool

    var body: some View {
        Button {
            showDrawer.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14))
                    .foregroundColor(showDrawer ? .accentColor : .secondary)

                if briefingService.unreadCount > 0 {
                    Text("\(min(briefingService.unreadCount, 99))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Morning Briefing")
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Views/Briefing/BriefingBellView.swift
git commit -m "feat(briefing): add BriefingBellView notification bell with badge"
```

---

### Task 7: BriefingDrawerView — Side Drawer with Item Cards

**Files:**
- Create: `Sources/Context/Views/Briefing/BriefingDrawerView.swift`

**Context:**
- Side panel that slides from the right, ~400px wide
- Items grouped by category
- Each item card: title, 2-sentence summary, source badge, relative time, "Open" and "Save" buttons
- Refresh button in header triggers `briefingService.generateNow()`
- Past briefings section at bottom (collapsible)
- "Generating..." state with ProgressView when isGenerating

**Step 1: Create BriefingDrawerView.swift**

The view should contain:

1. **Header**: "Morning Briefing" title, relative timestamp ("Generated 45m ago"), item count, refresh button (calls `briefingService.generateNow(settings:)`)

2. **Generating state**: If `briefingService.isGenerating`, show a ProgressView with "Generating briefing..." text

3. **Item list**: Group items by `category`. For each category, show a section header with category name and count. For each item:
   - Title (bold, 13pt)
   - Summary (regular, 11pt, secondary color)
   - Bottom row: source name badge, relative time, "Open" button (opens URL in browser via `NSWorkspace.shared.open()`), star/save button (toggles `isSaved`)
   - Tap on item marks it as read

4. **Past briefings**: Section at bottom showing previous digests (date + item count), tappable to load

5. **Empty state**: If no digest exists, show prompt to generate first briefing

Query items from DB: `BriefingItem.filter(Column("digestId") == digestId).order(Column("relevanceScore").desc).fetchAll(db)`

Query past digests: `BriefingDigest.filter(Column("status") == "ready").order(Column("generatedAt").desc).limit(10).fetchAll(db)`

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/Context/Views/Briefing/BriefingDrawerView.swift
git commit -m "feat(briefing): add BriefingDrawerView side panel with categorized items"
```

---

### Task 8: Integration — Wire Everything Together

**Files:**
- Modify: `Sources/Context/ContextApp.swift` (add BriefingService StateObject + environmentObject + launch trigger)
- Modify: `Sources/Context/Views/GUIPanelView.swift` (add bell icon to header + drawer overlay)
- Modify: `Sources/Context/Views/SettingsView.swift` (add Briefing tab)

**Context:**
- `ContextApp.swift`: Add `@StateObject private var briefingService = BriefingService()`, pass via `.environmentObject()`, trigger `briefingService.checkAndGenerate(settings:)` in `.onAppear`
- `GUIPanelView.swift`: Add `@State private var showBriefingDrawer = false`, add `BriefingBellView(showDrawer: $showBriefingDrawer)` in the header HStack (line 113, next to `chatButton`), add drawer overlay with `.overlay(alignment: .trailing)` containing `BriefingDrawerView` when `showBriefingDrawer` is true
- `SettingsView.swift`: Add a "Briefing" tab with staleness slider, RSS feed list (toggle + add custom), subreddit list

**Step 1: Add BriefingService to ContextApp.swift**

At line 61 (after `contextEngine`), add:
```swift
@StateObject private var briefingService = BriefingService()
```

At line 123 (after `.environmentObject(contextEngine)`), add:
```swift
.environmentObject(briefingService)
```

In the `.onAppear` block (around line 127), add after the gmail polling check:
```swift
Task {
    await briefingService.checkAndGenerate(settings: appSettings)
}
```

**Step 2: Add bell icon and drawer to GUIPanelView.swift**

Add `@EnvironmentObject var briefingService: BriefingService` and `@State private var showBriefingDrawer = false` to GUIPanelView.

In the home view header HStack (line 113), add before `chatButton`:
```swift
BriefingBellView(showDrawer: $showBriefingDrawer)
```

Wrap the main VStack content in a ZStack and add the drawer overlay:
```swift
.overlay(alignment: .trailing) {
    if showBriefingDrawer {
        BriefingDrawerView(showDrawer: $showBriefingDrawer)
            .frame(width: 400)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .trailing))
    }
}
```

Also add the bell to the project view header (the non-home header in GUIPanelView, so the bell is always accessible).

**Step 3: Add Briefing tab to SettingsView.swift**

Add a new tab after the Gmail tab:
```swift
BriefingSettingsView()
    .tabItem {
        Label("Briefing", systemImage: "bell.badge")
    }
```

Create a simple `BriefingSettingsView` (can be in the same file or a new `Views/Briefing/BriefingSettingsView.swift`):
- Staleness threshold slider (1–24 hours)
- RSS feeds list with toggle to enable/disable and "Add Feed" button
- Subreddits list with add/remove

**Step 4: Build to verify everything compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 5: Commit**

```bash
git add Sources/Context/ContextApp.swift Sources/Context/Views/GUIPanelView.swift Sources/Context/Views/SettingsView.swift
git add Sources/Context/Views/Briefing/BriefingSettingsView.swift  # if created separately
git commit -m "feat(briefing): integrate BriefingService, bell icon, drawer, and settings tab"
```

---

### Task 9: Package, Launch, and Smoke Test

**Files:**
- No new files — verification only

**Step 1: Build and package the app**

Run: `cd /Users/connor/Documents/claude-code-projects/scope && bash scripts/package-app.sh`
Expected: Build succeeded, .app bundle created

**Step 2: Launch the app**

Run: `open /Users/connor/Documents/claude-code-projects/scope/build/Scope.app`

**Step 3: Verify visually**

Check:
- [ ] Bell icon appears in the GUI panel header
- [ ] Clicking bell opens the side drawer
- [ ] Drawer shows "generating" state or empty state on first launch
- [ ] Settings > Briefing tab shows feed configuration
- [ ] Refresh button in drawer triggers generation
- [ ] After generation completes, items appear grouped by category
- [ ] "Open" button launches URL in browser
- [ ] "Save" button toggles bookmark state
- [ ] Badge count updates when new briefing is ready

**Step 4: Commit any fixes needed**

If any adjustments are needed after visual verification, fix and commit.

---

## File Summary

| File | Action | Task |
|------|--------|------|
| `Services/DatabaseService.swift` | Modify (add v16 migration) | 1 |
| `Models/BriefingModels.swift` | Create | 2 |
| `Services/Briefing/NewsFetcher.swift` | Create | 3 |
| `Services/AppSettings.swift` | Modify (add briefing settings) | 4 |
| `Services/Briefing/BriefingService.swift` | Create | 5 |
| `Views/Briefing/BriefingBellView.swift` | Create | 6 |
| `Views/Briefing/BriefingDrawerView.swift` | Create | 7 |
| `Views/Briefing/BriefingSettingsView.swift` | Create | 8 |
| `ContextApp.swift` | Modify (add StateObject + trigger) | 8 |
| `Views/GUIPanelView.swift` | Modify (add bell + drawer overlay) | 8 |
| `Views/SettingsView.swift` | Modify (add Briefing tab) | 8 |
