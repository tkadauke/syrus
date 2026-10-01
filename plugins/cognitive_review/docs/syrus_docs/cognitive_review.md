# Cognitive Review

Cognitive Review is a bundled, disabled-by-default plugin that owns review-note
generation for changed diff ranges.

When enabled, the plugin contributes three providers:

- `post_implementation_review_provider` appends the generic best-effort
  post-implementation review step to implementation-style workflows.
- `mcp_tool_set` exposes `submit_cognitive_review_notes` only to that review
  step.
- `diff_review_annotation_provider` projects submitted notes into the Job
  review tab.

Disabling the plugin hides the workflow provider, MCP tool set, and review-tab
annotations. It does not delete notes already submitted into workflow artifacts.

## Operator Behavior

After an implementation workflow finishes its final diff, Syrus starts a
best-effort review-note pass when the plugin is enabled and the workflow kind
is an implementation or feedback kind. The pass asks the agent to flag only
ranges that deserve operator attention: risky behavior, subtle coupling,
missing verification, migration or data concerns, or other attention debt.

If there are no such ranges, the agent must still call
`submit_cognitive_review_notes` with an empty `notes` array. The host step is
best-effort: provider or agent failures are logged but do not fail the parent
workflow.

## Configuration

Enable or disable the plugin from Admin -> Plugins. There is no repository
configuration key for the first scaffold.

Agent Memory is optional. When the Agent Memory plugin is enabled, its normal
workflow context can inform the review pass. When memory is disabled or
unavailable, Cognitive Review relies on the Job, repository, and diff context.
