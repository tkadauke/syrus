# Design Docs

The `design_docs` plugin (`plugins/design_docs/`) is default-enabled first-party
Syrus functionality for collaborative Markdown design documents.

Design docs are separate from attachment-oriented `Document` records. The
plugin registers the operator-visible capability as `design_docs`; the backing
models live in the main Rails app so later API, navigation, repository-tab, chat
workspace, and MCP surfaces can share one core schema.

## Schema

- `design_docs` stores the canonical current Markdown body, title, owner,
  visibility, state, optional origin chat session, and optional current version.
  `DesignDoc#display_id` renders user-facing references as `DOC-<id>`.
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

`DesignDoc.visible_to(user)` implements the v1 visibility rule: owners can see
their docs, explicit collaborators can see private docs, and public docs are
visible to users who can access at least one associated repository.

## Agent MCP tools

The `design_docs` plugin contributes MCP tools on both chat and workflow
surfaces. All protocol-visible document references are canonical `DOC-<id>`
strings, though the read tools also accept the raw integer id for convenience.

Chat agents receive:

- `list_design_docs(repository_id: nil)` — lists design docs visible to the
  chat user, optionally narrowed to an accessible repository. An inaccessible
  `repository_id` is rejected instead of widening the result set.
- `read_design_doc(doc_ref:)` — reads one visible design doc by `DOC-<id>` or
  integer id, including canonical Markdown, rendered Markdown, comments,
  anchors, and suggestions.
- `propose_design_doc(title:, markdown:, ...)` — creates a new draft design doc
  proposal owned by the chat user and linked to the chat as its origin. The
  initial version records `actor_kind: agent`.
- `comment_on_design_doc(doc_ref:, body:, start_offset:, end_offset:, ...)` —
  creates an agent-authored inline comment anchored against rendered Markdown.
- `suggest_design_doc_change(doc_ref:, proposed_markdown:, start_offset:,
  end_offset:, ...)` — creates exactly one pending, agent-authored suggestion
  for one rendered-Markdown range.

Agent content mutation is suggestion-only for existing docs. The chat MCP
surface has no direct canonical update tool, and `DesignDocs::Update` also
enforces the backend rule by treating `actor_kind: agent` as a suggestion path
even when the agent/user owns the document. Suggestions and comments may insert
hidden Syrus anchor markers into stored Markdown so ranges survive rendering,
but the canonical prose remains unchanged until an owner accepts a suggestion.

Workflow agents receive only `list_design_docs` and `read_design_doc`. Their
scope is always the run's user plus repository: readable design docs must pass
`DesignDoc.visible_to(run.job.user)` and be associated with
`run.job.repository`. Worker environment snapshots and prompt injection list
nearby readable `DOC-<id>` references so agents can opt into `read_design_doc`
when a design doc may affect the task, without granting comment or suggestion
tools to worker runs.
