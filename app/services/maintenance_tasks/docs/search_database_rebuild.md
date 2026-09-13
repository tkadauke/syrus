# Rebuild Search Database

Type: repeatable index rebuild.

This task prepares the local SQLite full-text search database and backfills core-owned searchable rows for chats and operational logs.

The task is useful after enabling Global Search, replacing the search database file, or deploying a schema change that adds a core index table.

What it does:

- Creates missing FTS tables and repairs tables with rebuild hooks.
- Backfills chat messages in batches.
- Reindexes operational logs when instance logging is configured.

Expected load: mostly local SQLite writes plus primary database reads. It is resumable and can be paused if search indexing is competing with foreground work.
