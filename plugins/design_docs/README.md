# Design Docs

First-party Syrus plugin scaffold for collaborative Markdown design documents.

The database-backed authoring models live in this plugin under `app/models`,
with the migration under `db/migrate`. The host app loads bundled plugin
migration paths and keeps the shared Rails schema dump.
