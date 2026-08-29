# Design Docs

First-party Syrus plugin for collaborative Markdown design documents.

The database-backed authoring models live in this plugin under `app/models`,
with the migration under `db/migrate`. The host app loads bundled plugin
migration paths and keeps the shared Rails schema dump.
Plugin-owned backend files live under `plugins/design_docs/app/`, including the
JSON API controller, policy, serializer, and create/update services.
