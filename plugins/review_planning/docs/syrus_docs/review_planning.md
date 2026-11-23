# Review Plan (retired)

The `review_planning` plugin owns what is left of the retired review-plan feature.
No new workflow contains a `review_plan` step, and there is no
`submit_review_plan` tool.

## What it keeps working

- **Persisted workflows.** A workflow created before the retirement may still
  hold a `review_plan` step after `pr_open`. The step is non-agentic and advisory
  (`fail_policy: advance`): it records `skipped: true` with
  `skip_reason: review_plan_retired` and the workflow advances. It cannot fail the
  workflow.
- **Legacy configuration.** The bare boolean `review_plan: true` in `.syrus.yml`
  is parsed and ignored (it is also accepted as `plugins: { review_planning.config }`).
  The block is ignored without an error while the plugin is disabled.

## Disabling the plugin

The plugin is disableable. Because no new workflow materializes the step,
disabling it is a clean no-op, except that Syrus refuses the disable while a
non-terminal workflow still contains a `review_plan` step. Previously recorded
steps and artifacts are never removed.
