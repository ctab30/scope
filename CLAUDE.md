<!-- Workspace managed section -->
# Workspace Task Tracking
Use `mcp__workspace__` tools for task management. Do NOT use TodoWrite.

## Session start
`mcp__workspace__get_project_context` — see open tasks and project state.
If tasks are `in_progress`, resume them with `mcp__workspace__get_task`.

## Workflow
- **Start work**: `mcp__workspace__create_task` with `status: "in_progress"` (one call to create + start). Title is required; description, priority, labels are optional. Duplicate detection is automatic.
- **Log progress**: `mcp__workspace__add_task_note` for key decisions or progress.
- **Finish**: `mcp__workspace__complete_task` with a summary of what was done.
- **Notes**: `mcp__workspace__create_note` to save project knowledge.

For quick questions or read-only tasks, creating a task is optional.
<!-- End Workspace section -->
