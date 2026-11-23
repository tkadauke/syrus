# Review plan

An optional self-review pass: after the pull request opens, the implementing
agent posts one comment pointing reviewers at the spots in its own diff worth a
closer look.

## What It Adds

- The `review_plan` step, contributed at `workflow:post_pr` (once, after `pr_open`)
  for repositories that set `review_plan: true` in `.syrus.yml`.
- The workflow-only `submit_review_plan` MCP tool, offered to that step only.
- The prompt, the PR-comment formatter, and the `review_plan:` configuration key
  (also `plugins: { review_planning.config }`).

## Disableable

Yes. The review is advisory (`fail_policy: advance`) and nothing downstream reads
it, so new workflows simply omit the step. The standard plugin guard refuses a
disable while a non-terminal workflow still contains the step. Recorded
`review_plan` artifacts are kept.

See `docs/syrus_docs/review_planning.md` for the user-facing reference.
