# Design Docs

First-party Syrus plugin scaffold for collaborative Markdown design documents.

The database-backed authoring models live in the host app because design docs
are core Syrus records, not attachment-oriented `Document` rows.
