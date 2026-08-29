# Design Docs

First-party Syrus plugin for collaborative Markdown design documents.

Plugin-owned backend files live under `plugins/design_docs/app/`, including the
JSON API controller, policy, serializer, and create/update services.

The database-backed Active Record models currently remain in the host app
because Syrus' plugin model namespace contract requires plugin model classes and
tables to share a plugin namespace/table prefix. Design Docs was introduced with
top-level `DesignDoc*` model constants and `design_doc*` tables, so moving those
models into the plugin would require a broader compatibility migration. Host
integration also owns the shared schema migration and core associations from
`User`, `Repository`, and `ChatSession`.
