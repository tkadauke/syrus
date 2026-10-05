# Review Notes

Review Notes is a bundled, disabled-by-default plugin that owns review-note
generation for changed diff ranges.

When enabled, the plugin contributes three providers:

- `post_implementation_review_provider` appends the generic
  post-implementation review step to implementation-style workflows.
- `mcp_tool_set` exposes `submit_review_notes` only to that review
  step.
- `diff_review_annotation_provider` projects submitted notes into the Job
  review tab.

Disabling the plugin hides the workflow provider, MCP tool set, API routes, and
review-tab annotations. It does not delete review note rows that were already
submitted, and re-enabling the plugin makes those records visible again when
their diff version is selected.

## Operator Behavior

After an implementation workflow finishes its final diff, Syrus starts a
review-note pass when the plugin is enabled and the workflow kind is an
implementation or feedback kind. The pass asks the agent to flag only ranges
that deserve operator attention: risky behavior, subtle coupling, missing
verification, migration or data concerns, or other review guidance.

If there are no such ranges, the agent must still call
`submit_review_notes` with an empty `notes` array. Providers that request this
step must expose their required submission tools in the same run MCP context.
If a provider declares required tools and the agent run completes without
calling them, the review step fails instead of reporting a clean success. The
plugin records an empty submission as durable evidence for the diff version; a
diff version with no notes and no submission marker is treated as "no
review-note result yet," not as no debt.

Submitted notes are durable plugin-owned records scoped to the Job, Workflow,
Run, and DiffReviewVersion that produced them. A note anchors to a repository
path plus an old-side or new-side range; the initial version prioritizes
changed new-code ranges. Repeated submissions from the same review Run are
idempotent for the same diff version and range/title/reason-code identity.

Open notes count as unresolved PR-level review-note debt. Acknowledging a note,
adding discussion, or adding an operator diff comment to a covered range marks
that range handled. Dismissed notes are tracked in the rollup separately from
handled notes. Unflagged changed lines do not create PR-level review-note debt.
The legacy `submit_cognitive_review_notes` tool name and
`/cognitive_review_notes` routes remain accepted for compatibility, but new
callers should use the review-note names.

In the Job review tab, non-dismissed notes render as diff ranges for the
displayed diff version, compact review-note markers in the diff gutter, and a
full agent-authored review-note card inline at the end of the covered range.
Open notes use warning styling. Acknowledged, discussed, and user-commented
notes remain visible but switch to a subdued handled style and no longer
contribute to the red review-note risk metric. The same notes also appear in
the unified Review conversation side panel. The side panel shows the open-note
count across review versions, interleaves review notes with user comments by
version and code position, shows total flagged ranges, open/unhandled notes,
handled notes, dismissed notes, and the zero-note state for the selected
DiffReviewVersion. The zero-note state appears only when the review pass
submitted an explicit empty result. Hovering or focusing a note card highlights
its covered line range in the displayed diff when that version is selected.
The side panel lets operators jump to flagged ranges and offers `Acknowledge`
and `Discuss` actions. `Acknowledge` marks an open note handled without adding
a reply. `Discuss` opens the Job discussion chat with Review Note context and
marks the note discussed; it is for talking with the agent about the note, not
for submitting review feedback. To leave feedback for the implementation,
operators use the note card's feedback reply action. That action creates a
normal diff review comment anchored to the note's diff version, path, side, and
range, with structured Review Note provenance in the comment context. The
comment handles the open note, appears in the unified Review conversation, and
is submitted through the regular diff-review feedback flow. Submitted feedback
marks those comments as Review Note-derived in the chat feedback body and
includes the Review Note metadata in the structured `diff_comments` artifact.
Older discussion-entry rows, if present, are displayed as read-only note
history. An operator's regular diff comment also handles an open note when the
comment is anchored to the same diff version, path, side, and line range; the
comment remains a normal review-tab comment for sidebar and feedback behavior.

This rollup is intentionally scoped to PR review. It answers: "Did this
implementation diff receive plugin-authored notes, and have the flagged ranges
been handled?" It does not measure repository-wide cognitive coverage, codebase
cognitive debt, historical risk, or the percentage of changed lines inspected.
Those broader metrics can consume these note states later, but that is a
separate integration.

## API

When the plugin is enabled, these app API routes are available under the same
Job permissions used by the review tab:

- `GET /api/v1/app/jobs/:job_id/review_notes`
- `GET /api/v1/app/jobs/:job_id/review_notes/:id`
- `POST /api/v1/app/jobs/:job_id/review_notes/:id/acknowledge`
- `POST /api/v1/app/jobs/:job_id/review_notes/:id/start_discussion`
- `POST /api/v1/app/jobs/:job_id/review_notes/:id/discussion_entries`

The older `/cognitive_review_notes` routes remain accepted as aliases.

Read-tier repository members can list and read notes. Acknowledgement, starting
agent discussion, and writing legacy discussion entries require the Job owner,
a write-tier repository member, or an admin. Disabled plugin routes return the
standard `plugin_disabled` error.

## Configuration

Enable or disable the plugin from Admin -> Plugins. There is no repository
configuration key, settings row, or `.syrus.yml` option for Review Notes.
The Admin -> Plugins entry lists the plugin category, icon, optional Agent
Memory dependency, extension points, API routes, and the enable/disable state.

Agent Memory is optional. When the Agent Memory plugin is enabled, its normal
workflow context can inform the review pass. When memory is disabled or
unavailable, Review Notes relies on the Job, repository, and diff context.
