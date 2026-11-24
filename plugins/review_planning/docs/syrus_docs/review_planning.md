# Review Plan

Review plan is the `review_planning` plugin (display name "Review plan"). It is
on by default and optional per repository: after a PR is opened, the same agent
that implemented the change (resumed from its `implement` session) looks back
over its own diff and posts a structured "pay attention to X because Y" comment
on the PR, pointing at specific `file:line` locations. It is a second pass over
context the implementing agent already has, not a fresh reviewer, and not a
substitute for [`adversarial_review`](adversarial_review.md) or human review.

## Opting in

```yaml
review_plan: true
```

A bare boolean (also accepted as `plugins: { review_planning.config }`). Omitting
the key or setting it to `false` means no `review_plan` step is created at all.
While the plugin is disabled the key is ignored without an error.

## Where it runs

The plugin contributes the `review_plan` step to the `workflow:post_pr` anchor:
once, after `pr_open`, only for opted-in repositories. The chain is persisted
when the workflow is created, so an in-flight workflow keeps its shape. Workflows
that push to an existing PR instead of opening one (feedback chains) record a skip.

1. The step re-reads `.syrus.yml` from the cloned workspace; if the key is not
   `true` there either, it does nothing.
2. If a `review_plan` workflow artifact already exists, the agent call is skipped.
3. Otherwise the agent is resumed from the last successful `implement` run and
   calls `submit_review_plan` with 2-6 high-signal items (`file`, optional `line`,
   `note`) and an optional `summary`; it submits an empty list rather than pad.
4. A non-empty artifact is rendered to markdown and posted, or updated in place
   (matched by an HTML marker), as a PR comment. No items means no comment.

The `submit_review_plan` tool is offered only to the `review_plan` step.

## Best-effort, never blocking

The step never fails the parent Job or Workflow. Agent errors, running out of
turns without submitting, an unavailable MCP sidecar, or a failed GitHub call are
logged and swallowed, and the step kind declares `fail_policy: advance` as a
backstop.

## Disabling the plugin

The plugin is disableable because the review is advisory and nothing downstream
depends on it. Disabling removes the step from new workflows and retires the
`review_plan:` key, but Syrus refuses the disable while a non-terminal workflow
still contains a `review_plan` step. Previously produced `review_plan` artifacts
are never removed.
