# Morning Briefing Agent Design

**Date:** 2026-02-22
**Status:** Approved

## Goal

Add an AI-powered daily intelligence briefing that fetches dev/AI news from free public APIs, synthesizes it with Claude (via the user's Max plan), and presents a ranked, categorized digest in a side drawer accessible from a notification bell in the top bar.

## Architecture: Claude-Synthesized Digest

Swift fetches raw items from free APIs in parallel. Claude synthesizes, ranks, and summarizes. Each does what it's good at — Swift handles fast I/O, Claude handles judgment.

### Data Flow

```
App Launch
    ↓
BriefingService checks: latest briefing > 6 hours old?
    ↓ yes
Fetch raw items in parallel:
    ├─ Hacker News Algolia API (top 30 stories)
    ├─ RSS feeds (10-15 blogs, parsed in Swift)
    └─ Reddit JSON API (3 subreddits, top 25 each)
    ↓
Deduplicate by URL, cap at ~80 raw items
    ↓
Send headlines + snippets to Claude CLI (-p)
    "Rank these by relevance to a dev agency owner.
     Pick top 15. Write 2-sentence summaries.
     Categorize each. Return JSON."
    ↓
Parse structured JSON response
    ↓
Save BriefingDigest + BriefingItems to database
    ↓
Post notification → badge appears on bell icon
```

## Database Model

```sql
CREATE TABLE IF NOT EXISTS briefingDigests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    generatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    itemCount INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'generating'
);

CREATE TABLE IF NOT EXISTS briefingItems (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    digestId INTEGER NOT NULL REFERENCES briefingDigests(id),
    title TEXT NOT NULL,
    summary TEXT NOT NULL,
    category TEXT NOT NULL,
    sourceUrl TEXT NOT NULL,
    sourceName TEXT NOT NULL,
    publishedAt DATETIME,
    relevanceScore INTEGER NOT NULL DEFAULT 5,
    isSaved INTEGER NOT NULL DEFAULT 0,
    isRead INTEGER NOT NULL DEFAULT 0
);
```

## News Sources

All free, no API keys required.

| Source | API | What we fetch |
|--------|-----|---------------|
| Hacker News | Algolia `search_by_date` | Top 30 stories, last 24h |
| Reddit | `/.json` suffix on URLs | Top 25 from r/programming, r/MachineLearning, r/LocalLLaMA |
| RSS Feeds | Standard XML parsing | Latest 10 items per feed |

### Default RSS Feeds (user-configurable)

- Anthropic Blog
- OpenAI Blog
- Google AI Blog
- Simon Willison's Weblog
- The Verge AI
- TechCrunch AI
- LangChain Blog
- Hugging Face Blog

Users can toggle feeds on/off and add custom RSS URLs in Settings > Briefing.

## UI Design

### Notification Bell (Top Bar)

```
[Context Logo]  [Home] [Projects] [Terminal]  ...  [🔔 3] [⚙️]
```

- Bell icon with unread count badge
- Orange badge when new briefing ready, gray after opened
- Click toggles a side drawer (slides from right, ~400px wide)

### Side Drawer

```
┌──────────────────────────────────┐
│  📋 Morning Briefing    [↻]     │
│  Generated 45m ago  •  15 items  │
├──────────────────────────────────┤
│                                  │
│  AI TOOLS (4)                    │
│  ┌────────────────────────────┐  │
│  │ Anthropic Ships Agent SDK  │  │
│  │ New SDK adds native tool…  │  │
│  │ [Open ↗]  [⭐ Save]  45m  │  │
│  └────────────────────────────┘  │
│                                  │
│  AGENTIC (3)                     │
│  ┌────────────────────────────┐  │
│  │ ...                        │  │
│  └────────────────────────────┘  │
│                                  │
│  ── Past Briefings ──            │
│  Yesterday • 14 items            │
│  Feb 20 • 12 items               │
└──────────────────────────────────┘
```

- Items grouped by category
- Each item: title, 2-sentence summary, source badge, relative time
- "Open" launches URL in default browser
- "Save" bookmarks the item (persists via isSaved flag)
- Past briefings collapsible at bottom
- Refresh button triggers immediate generation

## Service Architecture

```swift
@MainActor
class BriefingService: ObservableObject {
    @Published var isGenerating = false
    @Published var latestDigest: BriefingDigest?
    @Published var unreadCount: Int = 0

    func checkAndGenerate()        // Called on app launch
    func generateNow() async       // Manual refresh
}
```

Follows same pattern as GmailPoller — `@StateObject` in ContextApp, passed via `.environmentObject()`.

### Pipeline Steps

1. `fetchHackerNews()` → `[RawNewsItem]`
2. `fetchReddit(subreddits:)` → `[RawNewsItem]`
3. `fetchRSSFeeds(urls:)` → `[RawNewsItem]`
4. `deduplicateAndCap(_:limit:)` → `[RawNewsItem]`
5. `synthesizeWithClaude(_:)` → `[BriefingItem]` (calls `claude -p`)
6. `saveToDatabase(_:items:)` → persists digest + items

## Settings

New **Briefing** tab in Settings:

- Staleness threshold (default: 6 hours) — how old before auto-regenerating
- Toggle individual RSS feeds on/off
- Add/remove custom RSS feed URLs
- No API keys needed (all sources are free/public)

API keys for future agent features (X.com, Slack, etc.) go in a centralized **API Keys** section in Settings.

## Files Changed

| File | Change |
|------|--------|
| **New:** `Models/BriefingDigest.swift` | GRDB models for digest + items |
| **New:** `Services/BriefingService.swift` | Fetch, synthesize, store pipeline |
| **New:** `Services/NewsFetcher.swift` | HN, Reddit, RSS fetching logic |
| **New:** `Views/BriefingDrawerView.swift` | Side drawer UI with item cards |
| **New:** `Views/BriefingBellView.swift` | Notification bell for top bar |
| **Modified:** `ContextApp.swift` | Add BriefingService StateObject, trigger on launch |
| **Modified:** `MainSplitView.swift` | Add bell icon to toolbar/top bar |
| **Modified:** `SettingsView.swift` | Add Briefing tab with source config |
| **Modified:** `DatabaseService.swift` | Create briefingDigests + briefingItems tables |
| **Modified:** `AppSettings.swift` | Briefing staleness + source preferences |

## What Doesn't Change

- ScopeMCP binary (no MCP involvement)
- Existing email/task/terminal features
- Database schema for other tables
- ClaudeService.swift (BriefingService has its own Claude call logic, same pattern)

## Key Design Decisions

1. **Fetch in Swift, synthesize in Claude** — Keeps API calls fast and free; Claude only does the expensive thinking
2. **No API keys needed** — HN, Reddit, RSS are all free public APIs
3. **Side drawer, not a dashboard panel** — Keeps Home view uncluttered
4. **Auto-generate on app launch** — No background daemon needed; simple staleness check
5. **Configurable RSS feeds** — Power users can add niche blogs; defaults cover mainstream dev/AI
6. **Past briefings persist** — Scroll back through history; items you saved are always findable
