# Diff Review Comments

Syrus-owned diff review comments are persisted in `DiffReviewComment`, not
`PrReviewComment`. `PrReviewComment` remains the GitHub PR comment ingestion
audit model; local review UI comments use the generic table so the job review
workspace, source-browser diff mode, and run artifact diff panels can share the
same storage contract.

Each comment belongs to a Job and authoring User, and can optionally point at
the Workflow and Run that produced the diff under review. Anchors store the
review surface, base/head refs, file path, side, old/new line coordinate, a
diff hunk snapshot, and a free-form JSON context hash for nearby symbols or
future re-anchoring metadata. State is one of `draft`, `submitted`,
`resolved`, or `superseded`.

`anchor_kind` is `"line"` (the default) for a comment tied to a specific
file/side/line, or `"review"` for a whole-review comment that critiques the
change as a whole rather than one line. Whole-review comments carry no
`path`/`side`/`old_line`/`new_line`/`diff_hunk` — the model clears those
fields on save regardless of what the client sends — and their `anchor_key`
is always the literal string `"review"`. They submit through the same
`chat_feedback` path as line-anchored comments and are grouped in `by_path`
under the reserved `"__review__"` path key.

API endpoints live under the user-scoped app API:

- `GET /api/v1/app/jobs/:job_id/diff_review_comments`
- `POST /api/v1/app/jobs/:job_id/diff_review_comments`
- `POST /api/v1/app/jobs/:job_id/diff_review_comments/submit`
- `PATCH /api/v1/app/jobs/:job_id/diff_review_comments/:id`
- `DELETE /api/v1/app/jobs/:job_id/diff_review_comments/:id`
- `POST /api/v1/app/jobs/:job_id/diff_review_comments/:id/resolve`

Listing follows normal Job visibility. Mutations use the existing Job write
policy: the job owner, a global admin, or a write-tier-or-higher repository
member. The list endpoint accepts `surface`, `base_ref`, `head_ref`, `path`,
`state`, `workflow_id`, and `run_id` filters and returns both a flat
`comments` array and `by_path`, keyed as `by_path[path][anchor_key]`, where
anchor keys are `side:old:new` with blank coordinates left empty.

`DELETE` hard-deletes a comment (no `deleted`/`superseded` state, a real row
removal) and only accepts comments still in `draft` — once a comment has been
`submitted`, `resolved`, or `superseded` it is part of the review history and
the endpoint responds `422 unprocessable_content` instead. On success it
returns `{ job_id, deleted_id }` rather than the usual comments payload, since
the deleted comment no longer exists to serialize.

Current UI surfaces use these `surface` values:

- `job_review_workspace` — continuous post-implementation review diff.
- `job_source_diff` — source-browser diff mode; comments are enabled only when
  base/head refs are available and feedback is actionable for the Job.
- `run_agent_diff` — full Run artifact diff; comments are enabled only when
  the artifact payload has Job, Workflow, Run, base, and head context.
- `run_step_agent_diff` — step-scoped Run artifact diff with the same context
  requirements as `run_agent_diff`.

Run artifact comments should be listed with `workflow_id` and `run_id` so
comments from one attempt do not appear beside a different Run that happened to
share the same base/head pair. The model validates that optional Workflow and
Run links belong to the comment's Job, and that a supplied Run belongs to the
supplied Workflow.

The submit endpoint accepts `comment_ids` and sends selected unresolved
comments through the normal `chat_feedback` workflow path. The workflow stores
a readable `chat_feedback` body plus structured `diff_comments` artifacts with
the durable anchor data: path, side, old/new line coordinates, base/head refs,
diff hunk snapshot, context, author, and comment body. Once the feedback
workflow is accepted, selected comments are marked `submitted` and linked to
that workflow. Duplicate active submissions are rejected by the same active
`chat_feedback` guard used by chat-submitted feedback.

## Review workspace layout

`app/frontend/routes/jobDetail/ReviewWorkspace.tsx` is the `job_review_workspace`
surface. The diff grows to its natural height (page scroll, not an internal
scroll box); a per-file sticky header exposes a "Files" button that opens an
on-demand popup listing every changed file with additions/deletions/comment
counts, selecting one scrolls the page to that file's section. The "Review
artifacts" panel starts collapsed (summary stays visible) and expands on
demand. The right-hand "Diff comments" sidebar is a sticky, viewport-height
column: it scrolls with the page until its top reaches the top of the
viewport, then pins there with its own internal scroll, and lists every
comment for the surface (line-anchored and whole-review). A "Comment on this
review" button starts a whole-review comment. Line-anchored (code) comments
are only editable inline, at their anchor in the diff (a "View in diff" sidebar
button scrolls to it) — the sidebar no longer offers an inline-comment Edit
control for those, only Resolve; whole-review comments remain editable from
the sidebar since they have no code anchor to edit at. Draft comments (both
whole-review, from the sidebar, and line-anchored, inline in the diff) also
get a "Delete" action next to Edit; it opens a shared confirmation dialog
(`useConfirm`) before hard-deleting, since the action cannot be undone. A
comment that has already been submitted, resolved, or superseded has no
Delete affordance — the record is review history at that point, not a draft.

`ReviewableDiff` (`app/frontend/components/diff/ReviewableDiff.tsx`) is the
shared diff renderer behind the review workspace, source-browser diff mode,
and run artifact diff panels; the natural-height/popup/inline-edit behaviors
above are opt-in via its `scroll`, `changedFilesPopup`, and
`onStartEditThread`/`editingThreadId`/`onDeleteThread` props so the other
surfaces keep their existing bounded-height, permanent file list,
sidebar-only-edit behavior unless they explicitly opt in. The add-comment
affordance is a small "+" in the left gutter beside the line number, shown on
row hover (GitHub-style), not a right-edge column.
