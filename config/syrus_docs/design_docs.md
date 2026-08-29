# Design Docs

The `design_docs` plugin (`plugins/design_docs/`) is default-enabled first-party
Syrus functionality for collaborative Markdown design documents.

Design docs are separate from attachment-oriented `Document` records. The
plugin registers the operator-visible capability as `design_docs`, owns the
`DesignDocs::` domain models, JSON API controller, policy, serializer, and
create/update services, anchor marker parsing, comment/thread services,
suggestion review services, and specs under `plugins/design_docs/app/`. The
host app applies only the small associations needed on `User`, `Repository`,
and `ChatSession`.

## Schema

- `design_docs` stores the canonical current Markdown body, title, owner,
  visibility, state, optional origin chat session, and optional current version.
  `DesignDocs::DesignDoc#display_id` renders user-facing references as
  `DOC-<id>`.
- `design_doc_repositories` is the n:m join between design docs and
  repositories, with a unique `(design_doc_id, repository_id)` index.
- `design_doc_collaborators` records explicit private-doc collaborators for v1.
- `design_doc_versions` is append-only at the model layer and stores Markdown,
  version number, actor user/kind, optional polymorphic provenance, change
  summary, metadata, and timestamps.
- `design_doc_anchors`, `design_doc_threads`, `design_doc_comments`, and
  `design_doc_suggestions` provide the base inline discussion and
  owner-reviewed suggestion model. Anchors are stored in canonical Markdown as
  hidden HTML comments: point anchors use `<!-- syrus:anchor id="..." -->`,
  and range anchors use paired `<!-- syrus:range-start id="..." -->` /
  `<!-- syrus:range-end id="..." -->` markers. Rendered Markdown strips these
  comments; database rows remain authoritative for marker ids, base version,
  selected text, prefix/suffix context, last known offsets, provenance, state,
  and permissions. Suggestions are v1 range replacements (`change_type:
  replace`) reviewed explicitly by the design doc owner.

`DesignDocs::DesignDoc.visible_to(user)` implements the v1 visibility rule:
owners can see their docs, explicit collaborators can see private docs, and
public docs are visible to users who can access at least one associated
repository.

The plugin owns its migration under `plugins/design_docs/db/migrate`. The host
app adds bundled plugin migration paths at boot, and the shared Rails schema
dump remains in `db/schema.rb`.
