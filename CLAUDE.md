<!-- Workspace managed section -->
# MANDATORY: Workspace Task Tracking
**RULE: Before doing ANY work, you MUST call `mcp__workspace__create_task` first. No exceptions.**
This applies to code reviews, bug fixes, features, refactors, investigations — everything.
Never start working without creating a task. This is a hard requirement, not a suggestion.

## First thing EVERY session
1. `mcp__workspace__get_project_context` — loads project info, open tasks, and notes.
2. If tasks are `in_progress`, call `mcp__workspace__get_task` + `mcp__workspace__get_task_plan` to resume.

## For every request
1. `mcp__workspace__create_task` — create a task BEFORE you start. Fill ALL fields: title, description, priority, labels.
2. `mcp__workspace__update_task` status `"in_progress"` — mark it active.
3. `mcp__workspace__add_task_note` — log progress as you work.
4. `mcp__workspace__update_task` status `"done"` — mark complete when finished.
For complex work: `mcp__workspace__set_task_plan` to attach a step-by-step plan.
For deliverables (reviews, analysis, reports): `mcp__workspace__add_task_file` to attach markdown files.

## Project knowledge
- Save learnings/decisions: `mcp__workspace__create_note`
- Search before solving: `mcp__workspace__search_notes`

Never use built-in TodoWrite or other task systems. Only use `mcp__workspace__` tools.
<!-- End Workspace section -->

<!-- Scope managed section -->
# MANDATORY: Scope Task Tracking
**RULE: Before doing ANY work, you MUST call `mcp__scope__create_task` first. No exceptions.**
This applies to code reviews, bug fixes, features, refactors, investigations — everything.
Never start working without creating a task. This is a hard requirement, not a suggestion.

## First thing EVERY session
1. `mcp__scope__get_project_context` — loads project info, open tasks, and notes.
2. If tasks are `in_progress`, call `mcp__scope__get_task` + `mcp__scope__get_task_plan` to resume.

## For every request
1. `mcp__scope__create_task` — create a task BEFORE you start. Fill ALL fields: title, description, priority, labels.
2. `mcp__scope__update_task` status `"in_progress"` — mark it active.
3. `mcp__scope__add_task_note` — log progress as you work.
4. `mcp__scope__update_task` status `"done"` — mark complete when finished.
For complex work: `mcp__scope__set_task_plan` to attach a step-by-step plan.
For deliverables (reviews, analysis, reports): `mcp__scope__add_task_file` to attach markdown files.

## Project knowledge
- Save learnings/decisions: `mcp__scope__create_note`
- Search before solving: `mcp__scope__search_notes`

Never use built-in TodoWrite or other task systems. Only use `mcp__scope__` tools.
<!-- End Scope section -->
