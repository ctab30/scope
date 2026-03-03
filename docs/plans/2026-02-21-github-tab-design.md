# GitHub Tab Design

## Overview

Add a GitHub tab to the GUI panel that shows open PRs, recent commits on the default branch, CI/Actions status, and assigned issues for the current project's repository. Targets repos the user owns or collaborates on, using the `gh` CLI for all API access.

## Architecture

### GitHubService

`GitHubService: ObservableObject` — polls every 60 seconds via `Process()` calls to `gh` CLI.

On project selection, detects the GitHub repo by running `gh repo view --json owner,name` in the project directory. If detection fails (no remote, `gh` not installed, not authenticated), sets `isAvailable = false` and the tab shows an empty state.

Four polling calls per cycle:

1. `gh pr list --state open --json number,title,author,headRefName,isDraft,reviewDecision,statusCheckRollup,createdAt,updatedAt,additions,deletions`
2. `gh api repos/{owner}/{repo}/commits?sha={default_branch}&per_page=15`
3. `gh run list --limit 10 --json name,status,conclusion,headBranch,event,createdAt,url`
4. `gh issue list --assignee @me --state open --json number,title,assignees,labels,state,createdAt,updatedAt`

Each call runs on a background thread. Results are decoded into structured Swift models and published to the UI.

### Data Models

```
GitHubRepo      — owner, name, defaultBranch
GitHubPR        — number, title, author, branch, isDraft, reviewDecision,
                  checksStatus, createdAt, updatedAt, additions, deletions
GitHubCommit    — sha, message, author, date
GitHubWorkflow  — name, status, conclusion, branch, event, createdAt, url
GitHubIssue     — number, title, assignees, labels, state, createdAt, updatedAt
```

### Tab Layout

Scrollable single-column view with four collapsible sections:

**Pull Requests** — sorted by most recently updated. Each row: PR number, title, author initials, branch name, review status badge (approved/changes requested/pending), CI checks badge (pass/fail/running), draft indicator, +/- line counts. Click opens PR in browser.

**CI / Actions** — recent workflow runs. Each row: workflow name, branch, status icon, conclusion, trigger event, relative time. Click opens run in browser.

**Recent Commits** — commits on default branch. Compact list: short SHA, message (truncated), author, relative time. Flat list, no graph.

**Issues** — assigned open issues. Each row: issue number, title, labels as colored capsules, relative time. Click opens in browser.

Section headers show count badges for at-a-glance status. Refresh button in the tab header triggers immediate poll.

## Integration

- New `case github = "GitHub"` in `AppState.GUITab` with icon `arrow.triangle.branch`
- `GitHubService` as `@StateObject` in `ContextApp` and `ProjectWindowView`
- Injected via `.environmentObject()`
- Starts polling on project selection, stops on window close
- No new dependencies — pure `Process()` + `JSONDecoder`

## Files

**New (2):**
- `Context/Sources/Context/Services/GitHubService.swift`
- `Context/Sources/Context/Views/GitHub/GitHubTabView.swift`

**Modified (4):**
- `Context/Sources/Context/ViewModels/AppState.swift` — add tab case
- `Context/Sources/Context/Views/GUIPanelView.swift` — render new tab
- `Context/Sources/Context/ContextApp.swift` — add @StateObject
- `Context/Sources/Context/Views/ProjectWindowView.swift` — add @StateObject
