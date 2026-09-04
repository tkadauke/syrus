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

### Anchor staleness and version-scoped history

Accepting a suggestion can overwrite raw Markdown that other anchors' hidden
markers were sitting in — a full-document suggestion is the extreme case,
since its replaced range is the entire document. `DesignDocs::ReviewSuggestion`
reconciles every other `active` anchor around every acceptance (both the
normal range-replace path and the marker-less autosave full-document path):
an anchor whose marker survived untouched just gets its cached offsets
refreshed; an anchor whose marker disappeared gets re-projected onto the new
text when its exact previous excerpt still exists exactly once elsewhere in
the document, and is otherwise marked `status: "stale"` immediately (with
`stale_as_of_version` set to the version the acceptance produced) along with
any of its still-`pending` suggestions. A `stale` anchor's offsets are frozen
at their last known position — the anchor is never silently re-derived from
numeric offsets once it can no longer be trusted. The pre-existing path where
a suggestion's own anchor text has drifted since it was authored (checked
against `suggestion.original_markdown` before any replacement happens) also
stamps `stale_as_of_version`, pinned to the design doc's current version
since that path never creates a new one — every code path that flips an
anchor to `stale` keeps the same version-window invariant.

The current-document editor and Threads rail only render anchors with
`status: "active"` (`buildAnchorHighlights`'s highlight filter and
`ThreadPanel`'s current-view filters in `DesignDocsSurface.tsx`), so stale
threads/suggestions disappear from the live view without being deleted.
`GET /api/v1/app/design_docs/:id/versions/:version_id/threads` (backed by
`DesignDocAnchor.active_as_of(version_number)`, using each anchor's birth
`design_doc_version` and `stale_as_of_version`) returns the threads and
suggestions that were active as of a specific historical version, so a stale
comment remains inspectable when viewing the version where its anchor
existed. The version dropdown in the editor title bar fetches this endpoint
and renders those results read-only (no reply, resolve, or accept/reject
controls) while a non-current version is selected.

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

Pending suggestions appear inline at their anchored range in both editor modes
where practical: the original Markdown range is struck through in the active
theme warning color and the proposed replacement appears next to it in the
active theme success color. The default Terracotta theme uses terracotta for
warning and green for success. This inline diff is display-only. Rich Text
conversion keeps the original anchored text in the draft, and canonical
Markdown is not changed until the owner accepts a suggestion.

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
