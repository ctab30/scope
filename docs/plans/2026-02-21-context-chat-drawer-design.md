# Context Chat Drawer

## Problem

Users need a way to ask questions about their projects, tasks, sessions, and notes without leaving the app. The embedded browser and terminal are great for doing work, but there's no conversational interface for querying project context, getting summaries, or turning insights into action (tasks, notes, terminal commands).

## Solution

A slide-out chat drawer accessible from the top-right of the app. Uses `claude -p` (CLI print mode) with the user's existing Max plan auth. Non-streaming — shows a loading state then the full response. Context-aware: assembles relevant project data (tasks, sessions, notes) into a system preamble before each API call.

## Data Model

### ChatConversation (DB table)
- `id`: Int64 (autoincrement PK)
- `projectId`: String? (null = global/home scope)
- `title`: String (auto-generated from first message)
- `createdAt`: Date
- `updatedAt`: Date

### ChatMessage (DB table)
- `id`: Int64 (autoincrement PK)
- `conversationId`: Int64 (FK → chatConversations, cascade delete)
- `role`: String ("user" | "assistant")
- `content`: String
- `createdAt`: Date

Conversations persist across sessions. Most recent conversation auto-loads when drawer opens. "New Chat" starts a fresh conversation.

## Context Assembly

`ContextAssembler` gathers data from DB and formats as text preamble (~8K char cap).

**Project scope** includes:
- Project name + path
- Active tasks (todo + in_progress) with priority, status, labels
- Recent session summaries (last 5)
- Pinned notes (full content, priority)
- Recent note titles (last 10)

**Global scope** includes:
- All projects with task counts + last active dates
- Global tasks
- Global pinned notes

Priority order when approaching cap: pinned notes > tasks > sessions > recent notes.

## Chat Service

Extends `ClaudeService` with:

```swift
func chat(messages: [(role: String, content: String)], context: String) async -> String?
```

Builds a single prompt with context + conversation history (last N messages, capped at ~25K chars total), sends via `claude -p --output-format text`.

## UI

### Chat icon (GUIPanelView header)
- `bubble.right.fill` system image, top-right of project/home header
- Toggles `showChatDrawer` state

### ChatDrawerView (overlay panel)
- Slides in from right edge, ~380px wide
- Semi-transparent backdrop, tap to dismiss
- Header: context label ("website-butlers" or "All Projects") + conversation picker + "New Chat"
- Message list: ScrollView with user/assistant bubbles
- Input bar: TextField + send button at bottom
- Loading indicator during API call

### ChatMessageView (message bubble)
- User messages: right-aligned, accent color background
- Assistant messages: left-aligned, subtle background, with action buttons below:
  - **Create Task** — pre-fills task form with message as description, source: "chat"
  - **Add to Notes** — saves as project note, auto-titled
  - **Copy** — clipboard
  - **Send to Terminal** — pastes text into active terminal via new `.pasteToTerminal` notification

## Files

**New (5):**
- `Context/Sources/Context/Models/ChatConversation.swift`
- `Context/Sources/Context/Models/ChatMessage.swift`
- `Context/Sources/Context/Services/ContextAssembler.swift`
- `Context/Sources/Context/Views/Chat/ChatDrawerView.swift`
- `Context/Sources/Context/Views/Chat/ChatMessageView.swift`

**Modified (3):**
- `Context/Sources/Context/Services/DatabaseService.swift` — v12 migration
- `Context/Sources/Context/Services/ClaudeService.swift` — add chat() method
- `Context/Sources/Context/Views/GUIPanelView.swift` — chat icon + drawer overlay

## Implementation Order

1. DB models + migration (ChatConversation, ChatMessage, v12)
2. ContextAssembler service
3. ClaudeService.chat() method
4. ChatMessageView (message bubble + action buttons)
5. ChatDrawerView (full drawer UI)
6. GUIPanelView wiring (icon + overlay)
7. Terminal paste notification (FocusableTerminalView listener)
8. Build + test
