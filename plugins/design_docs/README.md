# Design Docs

First-party Syrus plugin scaffold for collaborative Markdown design documents.

The database-backed authoring models live in this plugin under `app/models`.
The host app keeps the shared database migration and schema artifacts because
Syrus loads migrations from the main Rails application.
