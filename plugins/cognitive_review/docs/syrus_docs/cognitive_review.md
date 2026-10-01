# Review Notes

Review Notes is a bundled, disabled-by-default plugin that owns review-note
generation for changed diff ranges.

When enabled, the plugin contributes three providers:

- `post_implementation_review_provider` appends the generic best-effort
  post-implementation review step to implementation-style workflows.
- `mcp_tool_set` exposes `submit_review_notes` only to that review
  step.
- `diff_review_annotation_provider` projects submitted notes into the Job
  review tab.

Disabling the plugin hides the workflow provider, MCP tool set, and review-tab
annotations. It does not delete review-note rows that were already
submitted.

## Operator Behavior

After an implementation workflow finishes its final diff, Syrus starts a
best-effort review-note pass when the plugin is enabled and the workflow kind
is an implementation or feedback kind. The pass asks the agent to flag only
ranges that deserve operator attention: risky behavior, subtle coupling,
missing verification, migration or data concerns, or other review guidance.

If there are no such ranges, the agent must still call
`submit_review_notes` with an empty `notes` array. The host step is
best-effort: provider or agent failures are logged but do not fail the parent
workflow.

Submitted notes are durable plugin-owned records scoped to the Job, Workflow,
Run, and DiffReviewVersion that produced them. A note anchors to a repository
path plus an old-side or new-side range; the initial version prioritizes
changed new-code ranges. Repeated submissions from the same review Run are
idempotent for the same diff version and range/title/reason-code identity.

Open notes count as unresolved PR-level review-note debt. Acknowledged notes,
discussed notes, and user-commented note ranges count as handled; unflagged
changed lines do not create debt. The legacy `submit_cognitive_review_notes`
tool name and `/cognitive_review_notes` routes remain accepted for
compatibility, but new callers should use the review-note names.

In the Job review tab, open notes render as warning-tinted diff ranges for the
displayed diff version, compact review-note markers in the diff gutter, and a
full agent-authored review-note card inline at the first line of the covered
range. The same note also appears in the unified Review conversation side
panel. The side panel shows the open-note count across review versions,
interleaves review notes with user comments by version and code position, and
offers `Acknowledge` and `Discuss` actions. Hovering or focusing a note card
highlights its covered line range in the displayed diff when that version is
selected. `Acknowledge` marks the note handled without adding a reply; `Discuss`
stores an operator discussion entry and marks the note handled once that
discussion exists.

In the Job review tab, open notes render as warning-tinted diff ranges and as
agent-authored cognitive-note cards in the review side panel. The side panel
shows the open-note count, lets operators jump to the flagged range, and
offers `Acknowledge` and `Discuss` actions. `Acknowledge` marks the note
handled without adding a reply; `Discuss` stores an operator discussion entry
and marks the note handled once that discussion exists.

## API

When the plugin is enabled, these app API routes are available under the same
Job permissions used by the review tab:

- `GET /api/v1/app/jobs/:job_id/review_notes`
- `GET /api/v1/app/jobs/:job_id/review_notes/:id`
- `POST /api/v1/app/jobs/:job_id/review_notes/:id/acknowledge`
- `POST /api/v1/app/jobs/:job_id/review_notes/:id/discussion_entries`

Read-tier repository members can list and read notes. Acknowledgement and
discussion require the Job owner, a write-tier repository member, or an admin.
Disabled plugin routes return the standard `plugin_disabled` error.

## Configuration

Enable or disable the plugin from Admin -> Plugins. There is no repository
configuration key.

Agent Memory is optional. When the Agent Memory plugin is enabled, its normal
workflow context can inform the review pass. When memory is disabled or
unavailable, Review Notes relies on the Job, repository, and diff context.
