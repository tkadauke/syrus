# Rebuild Search Database

Type: repeatable index rebuild.

This task prepares the local SQLite full-text search database and backfills searchable rows for chats, jobs, epics, operational logs, browser errors, and plugin-provided search sources.

The task is useful after enabling Global Search, adding a plugin with a search source, replacing the search database file, or deploying a schema change that adds an index table.

What it does:

- Creates missing FTS tables and repairs tables with rebuild hooks.
- Backfills chat messages in batches.
- Reindexes jobs and epics when the Global Search plugin is installed.
- Reindexes operational logs when instance logging is configured.

Expected load: mostly local SQLite writes plus primary database reads. It is resumable and can be paused if search indexing is competing with foreground work.
