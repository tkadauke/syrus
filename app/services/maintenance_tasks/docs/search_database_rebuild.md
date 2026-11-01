# Rebuild Search Database

Type: repeatable index rebuild.

This task prepares the local SQLite full-text search database and selectively backfills stale searchable entities.

The task is useful after enabling Global Search, replacing the search database file, or deploying a schema change that adds a core index table.

What it does:

- Records an operator-readable plan that distinguishes missing schema, content-version changes, and row-integrity repairs.
- Rebuilds only the chats, jobs, epics, operational logs, or plugin-provided sources selected by that plan.
- Marks each entity's content version only after its rebuild succeeds, so pause, interruption, and resume are safe.

Expected load: mostly local SQLite writes plus primary database reads. It is resumable and can be paused if search indexing is competing with foreground work.
