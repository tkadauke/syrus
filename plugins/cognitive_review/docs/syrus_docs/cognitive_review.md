# Review Notes

Review Notes is a bundled, disabled-by-default plugin that owns agent-authored
review guidance for changed diff ranges.

When enabled, the plugin contributes three providers:

- `post_implementation_review_provider` appends the generic best-effort
  post-implementation review step to implementation-style workflows.
- `mcp_tool_set` exposes `submit_review_notes` only to that review
  step.
- `diff_review_annotation_provider` projects submitted notes into the Job
  review tab.

Disabling the plugin hides the workflow provider, MCP tool set, and review-tab
annotations. It does not delete review-note rows that were already submitted.

## Operator Behavior

After an implementation workflow finishes its final diff, Syrus starts a
best-effort review-note pass when the plugin is enabled and the workflow kind
is an implementation or feedback kind. The pass asks the agent to flag only
ranges that deserve operator attention: risky behavior, subtle coupling,
missing verification, migration or data concerns, or other attention debt.

If there are no such ranges, the agent must still call
`submit_review_notes` with an empty `notes` array. The host step is
best-effort: provider or agent failures are logged but do not fail the parent
workflow.

Submitted notes are durable plugin-owned records scoped to the Job, Workflow,
Run, and DiffReviewVersion that produced them. A note anchors to a repository
path plus an old-side or new-side range; the initial version prioritizes
changed new-code ranges. Repeated submissions from the same review Run are
idempotent for the same diff version and range/title/reason-code identity.

Open notes count as unresolved PR-level review attention debt. Acknowledging a
note or adding discussion marks it handled; unflagged changed lines do not
create debt.

## API

When the plugin is enabled, these app API routes are available under the same
Job permissions used by the review tab:

- `GET /api/v1/app/jobs/:job_id/cognitive_review_notes`
- `GET /api/v1/app/jobs/:job_id/cognitive_review_notes/:id`
- `POST /api/v1/app/jobs/:job_id/cognitive_review_notes/:id/acknowledge`
- `POST /api/v1/app/jobs/:job_id/cognitive_review_notes/:id/discussion_entries`

Read-tier repository members can list and read notes. Acknowledgement and
discussion require the Job owner, a write-tier repository member, or an admin.
Disabled plugin routes return the standard `plugin_disabled` error.

## Configuration

Enable or disable the plugin from Admin -> Plugins. There is no repository
configuration key.

Agent Memory is optional. When the Agent Memory plugin is enabled, its normal
workflow context can inform the review pass. When memory is disabled or
unavailable, Review Notes relies on the Job, repository, and diff context.
