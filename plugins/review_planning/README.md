# Review plan

Owns the retired `review_plan` workflow step and the legacy `review_plan:`
`.syrus.yml` key. Review planning once posted a plan comment on the pull request
after `pr_open`; that was retired, and no new workflow materializes the step.

## What It Adds

- The `review_plan` step kind (`fail_policy: advance`, not agentic) so workflows
  persisted before the retirement still execute: the handler records a skip and
  the workflow advances.
- The legacy boolean `review_plan:` key (also `plugins: { review_planning.config }`),
  parsed and ignored.

## Disableable

Yes. The step is retired and advisory, nothing downstream reads it, and the
standard plugin guard refuses a disable while a non-terminal workflow still
contains a `review_plan` step. Recorded steps and artifacts are never removed.
