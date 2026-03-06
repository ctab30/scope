<!-- Scope managed section -->
# Scope — Project Task & Session Manager
This project is managed by Scope. You MUST use the Scope MCP tools (prefixed `mcp__scope__`)
for ALL task operations. Never use built-in skills, TodoWrite, or other task systems.

## Task Workflow
1. Check tasks: `mcp__scope__list_tasks`
2. Start a task: `mcp__scope__update_task` with `status: "in_progress"`
3. Log progress: `mcp__scope__add_task_note`
4. Complete: `mcp__scope__update_task` with `status: "done"`
5. Create new: `mcp__scope__create_task`

When asked about tasks, todos, or work items — always call `mcp__scope__list_tasks` first.
<!-- End Scope section -->
