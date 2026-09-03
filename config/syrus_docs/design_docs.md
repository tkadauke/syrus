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
- `design_doc_agent_runs` records lightweight `@syrus` thread turns. Each run
  belongs to a doc, thread, triggering comment, requesting user, and base
  version; stores provider/status/timestamps, a prompt context snapshot, output
  payload, result summary, and error message; and links generated
  comments/suggestions back to the run for provenance.

`DesignDocs::DesignDoc.visible_to(user)` implements the v1 visibility rule:
owners can see their docs, explicit collaborators can see private docs, and
public docs are visible to users who can access at least one associated
repository.

## Editor UI

The plugin-owned editor uses a full-width document title bar above the document
surface. The title bar contains the editable title, canonical `DOC-<id>`
identity, visibility and state indicators, repository associations with a `+`
picker, a `Share` popover for visibility and explicit collaborators, and a
far-right version dropdown. The body editor uses `Rich Text` and `Markdown`
tabs over the same canonical Markdown working state instead of an adjacent
edit/preview split. `Rich Text` is selected by default; `Markdown` remains
available as the alternate source-editing mode. Owner edits autosave into the
`design_docs.markdown` working copy so reloads and navigation preserve
in-flight edits before an explicit checkpoint. Selecting a version from the
title-bar dropdown loads that version's Markdown into the current working copy;
it is autosaved like any other edit, while `Save` creates a new auditable
version/checkpoint from the current persisted working copy.

Pending suggestions are classified before rendering. Inline-safe suggestions
appear inline at their anchored range in both editor modes where practical: the
original Markdown range is struck through in the active theme warning color and
the proposed replacement appears next to it in the active theme success color.
Block-level suggestions, including multiline replacements and replacements that
begin with Markdown block markers such as headings, lists, blockquotes, or code
fences, render as an anchor mark in the document body and as a structured
Current/Proposed block diff in the Threads column. Proposed block Markdown is
never injected as inline text inside an existing heading, paragraph, or list
item. The default Terracotta theme uses terracotta for warning and green for
success. Suggestion previews are display-only. Rich Text conversion keeps the
original anchored text in the draft, and canonical Markdown is not changed
until the owner accepts a suggestion. New pending suggestions cannot overlap an
existing pending suggestion, and selections that cut through partial Markdown
block syntax are rejected with a validation error.

The document detail API includes editor permission flags:
`can_write_canonical`, `can_suggest`, and `can_review_suggestions`. Owners see
an `Edit` / `Suggest` selector in the editor toolbar. `Edit` is selected by
default for owners and continuously persists canonical Markdown working state;
clicking `Save` reveals an optional change summary field and the next `Save`
creates an append-only checkpoint/version with actor metadata. Switching to
`Suggest` persists the draft as an owner-authored pending suggestion for later
review. Owners also see metadata, sharing, repository, resolve, and suggestion
review controls. Non-owners with access are forced into `Suggest` mode: the
toolbar does not offer `Edit`, their in-flight edits autosave as pending
suggestions, the save action is labeled as suggestion creation, and
accept/reject controls render as pending owner review.

## Thread Mentions

Users who can comment/suggest on a Design Doc can invoke a lightweight Design
Docs agent turn by mentioning `@syrus` in a newly created comment/reply or in an
edit that newly introduces the mention. Matching is case-insensitive and ignores
mentions in quoted text, inline code, and fenced code blocks to avoid triggering
from pasted historical content or examples.

Mention turns are scoped to the thread instead of materializing normal Syrus
Jobs. The queued run captures `DOC-<id>`, the current version and Markdown, the
thread anchor, the full thread discussion, pending thread suggestions, doc
visibility/repository/collaborator metadata, and a small origin-chat excerpt
when one is available. The agent may create a pending suggestion on that thread
or post an agent-authored reply such as a clarifying question or an explanation
that no safe suggestion can be made. It must not directly mutate canonical
Markdown. Requests for repository implementation or file work should be
answered with a redirect to the chat Job/Epic proposal flow.

The Design Docs surface shows thread-level status for the latest agent run:
queued/running displays `Syrus is drafting...`, success shows the run summary,
failure shows the failure reason, and cancellation shows a canceled state.
Duplicate saves of the same triggering comment reuse the existing run, and only
one queued/running agent run is active for a given thread at a time.

## Chat Workspace Tabs

The Design Docs chat workspace surface is document-focused, not the top-level
index. In chat mode it must not infer a design doc id from the chat route's
`:id` param, because that value is the `ChatSession` id. It resolves the
selected document only from plugin tab payload data produced by
`DesignDocs::WorkspaceTabs`.

When a chat has one visible originated or referenced design doc, the plugin
declares the legacy `design_docs.chat` tab with `design_doc_ids` and
`design_docs` summary data. The frontend selects the first explicit
`design_doc_ids` entry and loads `/api/v1/app/design_docs/:id` for that doc.
When a chat has multiple visible docs, the plugin declares one tab per document
(`design_docs.chat.<doc_id>`) and includes `design_doc_id` in each tab's data,
so tab identity and document identity stay aligned. Chat mode hides index chrome:
no FilterBar, smart-folder navigation, repository/owner/state filters, or
document list. It keeps the document title bar, editor/review UI, comments,
suggestions, sharing metadata, repository metadata, and version controls.

If a chat Design Docs tab is rendered without an explicit document id, the
surface shows an empty state instead of guessing `DOC-<chat_session_id>` or any
other derived id.

The plugin owns its migration under `plugins/design_docs/db/migrate`. The host
app adds bundled plugin migration paths at boot, and the shared Rails schema
dump remains in `db/schema.rb`.

## Agent Tooling

Chat agents can suggest edits with `suggest_design_doc_change`. The tool
requires `base_version_number`, copied from the `current_version_number` field
returned by the `read_design_doc` call used to compute `start_offset` and
`end_offset`. A successful suggestion inserts anchor markers and creates a new
document version, so agents must re-read the Design Doc before creating another
offset-based suggestion. Stale version submissions are rejected before exact
selected-text matching or marker insertion.
