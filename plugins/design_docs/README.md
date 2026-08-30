# Design Docs

First-party Syrus plugin for collaborative Markdown design documents.

Design Docs are internally authored Markdown documents with auditable versions,
inline comments, owner-reviewed suggestions, repository associations, and chat
workspace visibility. They complement the host app's attachment-oriented
`Document` model rather than replacing it.

## Data Model

The plugin owns these tables through `plugins/design_docs/db/migrate`:

- `design_docs`: canonical doc row. Stores `title`, Markdown content,
  `visibility` (`private` or `public`), lifecycle `state`, owner, optional
  origin chat session, and the current version pointer.
- `design_doc_versions`: append-only version history for canonical Markdown
  snapshots. Records actor kind/user, summary, and metadata.
- `design_doc_repositories`: n:m association between docs and repositories.
- `design_doc_collaborators`: explicit private-doc collaborators.
- `design_doc_anchors`: authoritative inline range/point anchors.
- `design_doc_threads` and `design_doc_comments`: inline discussion state.
- `design_doc_suggestions`: one pending suggestion per anchored range in v1.

Hidden Syrus HTML comments are inserted into Markdown to keep anchors stable
across edits. The database records remain authoritative for provenance, state,
review status, and permissions; API serializers expose both `markdown` and
`rendered_markdown`, where `rendered_markdown` strips hidden anchor markers.

## References

User-facing references use canonical `DOC-<id>` identifiers. Chat Markdown and
system-message text autolink these identifiers to `/design_docs/<id>`, matching
the existing `JOB-<id>` and `EPIC-<id>` behavior.

The chat workspace tab provider exposes optional tab `data` containing:

- `design_doc_ids`
- `originated_design_doc_ids`
- `attached_design_doc_ids`
- `design_docs` summary payloads

Originated docs are those created from that chat. Attached docs are visible docs
referenced in chat history with `DOC-<id>`; they are surfaced in the same
workspace tab without adding a direct Design Doc to Job/Epic generation path.

## Permissions

`DesignDoc.visible_to(user)` grants access when the user is:

- the owner,
- an explicit collaborator, or
- able to access at least one repository associated with a `public` doc.

Owners can update canonical Markdown and metadata. Non-owner human edits become
pending suggestions. Agent edits are always suggestion-only, enforced by the
backend from authenticated server context rather than trusting request params.
Only owners can resolve threads and accept/reject suggestions.

## APIs And UI

Plugin-owned backend files live under `plugins/design_docs/app/`, including the
JSON API controller, policy, serializer, and create/update/review services. The
host app loads bundled plugin migration paths and keeps the shared Rails schema
dump.

The plugin registers:

- top-level sidebar page: `/design_docs`
- repository tab: `/repositories/:id/plugin/design_docs`
- chat workspace tab: `design_docs.chat`
- JSON API routes under `/api/v1/app/design_docs`
- repository-scoped API route under `/api/v1/app/repositories/:id/design_docs`

## Agent Tools

Chat agents receive deferred Design Docs tools:

- `list_design_docs`
- `read_design_doc`
- `propose_design_doc`
- `comment_on_design_doc`
- `suggest_design_doc_change`

Workflow agents receive read-only tools:

- `list_design_docs`
- `read_design_doc`

Workflow access is additionally scoped to the run repository. Agents should use
`DOC-<id>` references returned by `list_design_docs` and `propose_design_doc`.
For existing docs, content changes must go through
`suggest_design_doc_change`; the tool and service layer never mutate canonical
Markdown directly for agent actors.
