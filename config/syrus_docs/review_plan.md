# Review Plan

Review plan is an optional self-review pass: after a PR is opened, the same
agent that implemented the change (resumed from its `implement` session)
looks back over its own diff and posts a structured "pay attention to X
because Y" comment on the PR, pointing at specific `file:line` locations.
It's a second, independent pass over the same context the implementing agent
already has — not a fresh reviewer, and not a substitute for
[`adversarial_review`](adversarial_review.md) or human review.

## Feature flag

There is no instance-wide flag. Review plan is opt-in per repository via
`.syrus.yml`:

```yaml
review_plan: true
```

A bare boolean — not a nested block, unlike `adversarial_review` or
`coverage`. Omitting the key (or setting it to `false`) leaves the step a
no-op: `Steps::ReviewPlan` still runs but returns immediately without
invoking the agent or posting anything. See [`syrus_yml.md`](syrus_yml.md).

## How it works

The `review_plan` step is inserted immediately after `pr_open` in workflows
that end with `initial_pr_finish_steps` (`initial`, `retry`, and a few
maintenance/handoff chains that share that terminal sequence) — it needs the
PR to already exist so it has something to comment on.

1. Reads `.syrus.yml` from the already-cloned workspace. If `review_plan` is
   not `true`, the step logs and returns without doing anything.
2. If a `review_plan` workflow artifact already exists (e.g. because a prior
   step called `submit_review_plan`), the step skips the agent call
   entirely, the same short-circuit `test_plan` uses.
3. Otherwise, resumes the agent from the last successful `implement` Run's
   session (falling back to a fresh session if none is available) and asks
   it to call the `submit_review_plan` MCP tool with 2-6 specific,
   high-signal review points — each with a `file`, an optional `line`, and a
   `note` explaining *why* a reviewer should look closely there — plus an
   optional overall `summary`. The agent is told to submit an empty list
   rather than pad it when nothing stands out.
4. On a successful submission, the step formats the artifact into markdown
   and posts (or updates) a PR comment marked with an HTML comment so later
   runs upsert instead of duplicating. If the agent submitted zero items, no
   comment is posted — silence is preferred over a "nothing to see here"
   comment.

## Best-effort, never blocking

`review_plan` must never fail the parent Job or Workflow. Anything that goes
wrong — the agent errors, exhausts its turn budget without calling
`submit_review_plan`, the MCP sidecar is unavailable, or the GitHub API call
to post the comment fails — is logged and swallowed inside the step. The
`review_plan` Step::Kind entry also declares `fail_policy: :advance` as a
declarative backstop, so even if something raises past the handler's own
rescue, the workflow still advances (and, since `review_plan` is the last
step in these chains, that just means the workflow finishes) rather than
failing.

## Out of scope (for now)

- `review_plan` is not wired into `pr_comment` or `chat_feedback` follow-up
  workflows — only the terminal chains that already end in
  `initial_pr_finish_steps`.
- There is no UI surface for review-plan items beyond the PR comment; they
  are not rendered anywhere on the Job detail page.
