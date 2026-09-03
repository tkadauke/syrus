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
- `design_doc_agent_runs`: lightweight, comment-scoped `@syrus` agent turns
  requested from a design doc thread. Each run records the triggering comment,
  requesting user, doc/thread/version scope, provider, status, context snapshot,
  result summary, and output payload.

Hidden Syrus HTML comments are inserted into Markdown to keep anchors stable
across edits. The database records remain authoritative for provenance, state,
review status, and permissions; API serializers expose both `markdown` and
`rendered_markdown`, where `rendered_markdown` strips hidden anchor markers.

## References

User-facing references use canonical `DOC-<id>` identifiers. Chat Markdown and
system-message text autolink these identifiers to `/design_docs/<id>`, matching
the existing `JOB-<id>` and `EPIC-<id>` behavior.

The chat workspace tab provider exposes optional tab `data` containing:

- `design_doc_id` for a specific document tab when multiple docs are visible
- `design_doc_ids`
- `originated_design_doc_ids`
- `attached_design_doc_ids`
- `design_docs` summary payloads

Originated docs are those created from that chat. Attached docs are visible docs
referenced in chat history with `DOC-<id>`; they are surfaced in the same
workspace surface without adding a direct Design Doc to Job/Epic generation
path. With one visible doc the provider keeps the legacy `design_docs.chat` tab.
With multiple visible docs it declares one explicit `design_docs.chat.<doc_id>`
tab per doc so the frontend never derives a document id from the chat id.

## Permissions

`DesignDoc.visible_to(user)` grants access when the user is:

- the owner,
- an explicit collaborator, or
- able to access at least one repository associated with a `public` doc.

Owners can update canonical Markdown and metadata. Non-owner human edits become
pending suggestions. Agent edits are always suggestion-only, enforced by the
backend from authenticated server context rather than trusting request params.
Only owners can resolve threads and accept/reject suggestions.

Users who can suggest/comment on a Design Doc can mention `@syrus` in a newly
created or newly edited thread comment to request a lightweight agent turn. The
mention detector matches case-insensitively and ignores mentions in quoted text,
inline code, and fenced code blocks. The agent turn is scoped to the design doc
thread, includes the full thread discussion plus pending thread suggestions,
and never creates a normal Syrus Job or directly mutates canonical Markdown.
Generated output is either an agent-authored reply or a pending suggestion on
the same thread; both link back to the durable run and triggering comment.

The detail API serializes explicit permission booleans for the editor:
`can_write_canonical`, `can_suggest`, and `can_review_suggestions`. The UI uses
those values to keep owner-only metadata and accept/reject controls out of
review-only flows.

## APIs And UI

Plugin-owned backend files live under `plugins/design_docs/app/`, including the
JSON API controller, policy, serializer, and create/update/review services. The
host app loads bundled plugin migration paths and keeps the shared Rails schema
dump.

The plugin registers:

- top-level sidebar page: `/design_docs`
- repository tab: `/repositories/:id/plugin/design_docs`
- chat workspace tab: `design_docs.chat` for one doc, or
  `design_docs.chat.<doc_id>` per doc when multiple docs are visible
- JSON API routes under `/api/v1/app/design_docs`
- repository-scoped API route under `/api/v1/app/repositories/:id/design_docs`

Pending suggestions are classified before rendering. Inline-safe suggestions
render inline in the document body at their anchored range in both Rich Text and
Markdown editor tabs: the original range is struck through with the active
theme's warning token, and the proposed replacement is shown beside it with the
active theme's success token. Block-level suggestions, including multiline
replacements and replacements that begin with Markdown block markers such as
headings, lists, blockquotes, or code fences, render as an anchor mark in the
document body and as a structured Current/Proposed block diff in the Threads
column. Proposed block Markdown is never injected inline into the surrounding
heading, paragraph, or list item. Suggestion previews are display-only: hidden
anchor comments and proposed replacement previews are not written into
canonical Markdown until the owner accepts the suggestion. New pending
suggestions cannot overlap an existing pending suggestion, and selections that
cut through partial Markdown block syntax are rejected with a validation error.

Thread cards also surface lightweight agent-run state. While a run is queued or
running, the thread shows `Syrus is drafting...`; terminal states show a success
summary, failure reason, or cancellation notice. Duplicate saves of the same
triggering comment reuse the existing run, and a thread has at most one queued
or running mention turn at a time.

### Markdown Command Set

Design Docs v1 stores canonical Markdown and supports a GitHub-ish safe subset
that matches Syrus' shared React Markdown renderer and the plugin Rich Text
preview:

- headings `#` through `####`
- blockquotes with `>`
- fenced code blocks with triple backticks
- pipe tables with a header delimiter row
- ordered lists, unordered lists, and indented nested lists
- horizontal rules with `---` or `***`
- inline code with backticks
- bold with `**text**`
- italic with `*text*`
- links with `[label](https://example.test)`, root-relative paths, anchors,
  and `mailto:` URLs
- strikethrough with `~~text~~`
- Syrus slug autolinks such as `DOC-1`, `JOB-1`, and `EPIC-1` wherever the
  shared renderer is used

Raw HTML is intentionally excluded from the v1 command set. User-entered HTML is
rendered as inert text unless a future Job adds an explicit sanitization plan for
safe raw HTML.

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
Markdown directly for agent actors. Offset-based suggestions must include the
`current_version_number` returned by the `read_design_doc` call used to compute
the offsets as `base_version_number`. Creating a suggestion inserts anchor
markers and creates a new document version, so agents must re-read the Design Doc
before sending another offset-based suggestion.
