---
title: Workflows
description: Built-in Syrus execution chains for issues, feedback, retries, rebases, landing, chats, and scheduled work.
---

# Workflows

A Workflow template is a named chain of Steps tied to a trigger kind. Syrus
creates a Workflow when a labeled issue is ingested, PR feedback arrives, a
retry is requested, CI fails, a rebase is needed, coding work is handed off,
or an approved Job enters the landing queue.

The templates are deterministic around the agent: Syrus prepares the
workspace, invokes the agent only in agentic Steps, runs graders, captures
artifacts, pushes branches, and opens or updates PRs.

## Initial

Trigger: a GitHub issue with the repository trigger label, a scheduled task
fire, a direct Job, or another source that needs a new issue-to-PR attempt.

```text
prepare -> retry_until(implement -> grader_fanout -> grader_collect) -> coverage_analyze -> summarize -> test_plan -> pr_open
```

The agent commits the change during `implement`. Required grader failures
feed bounded repair iterations. `summarize` stores PR title/body copy,
`test_plan` stores reviewer-facing checks, and `pr_open` pushes the branch
and opens or updates the PR. If adversarial review rounds are configured,
Syrus inserts an implement/review loop before the normal grader loop.

## PR Feedback

Trigger: new review feedback or PR comments on an existing Syrus PR.

```text
prepare -> retry_until(respond -> grader_fanout -> grader_collect) -> coverage_analyze -> coverage_pr_comment -> summarize_amend -> try(push)
```

The agent receives the new comments plus PR context and commits follow-up
changes on the existing branch. Successful workflows mark the newest
addressed comment so the poller does not reprocess old feedback.

If the remote PR branch advanced before push, Syrus fetches it and tries a
mechanical rebase. If that conflicts, the `try(push)` branch inserts
agentic push-rebase recovery, graders, and a final push.

## Chat Feedback

Trigger: operator-confirmed feedback proposed from chat, or app-submitted
feedback on an implemented or failed Job.

```text
prepare -> retry_until(respond -> grader_fanout -> grader_collect) -> coverage_analyze -> coverage_pr_comment -> summarize_amend -> try(push)
```

The chain matches PR feedback, but the feedback source is a structured chat
or app artifact. Feedback on an approved Job unapproves it so the updated PR
returns to review before landing.

## CI Failure

Trigger: polling sees failed CI checks on an existing Syrus PR.

```text
prepare -> analyze_and_fix -> summarize_amend -> try(push)
```

The agent receives the failing check payload, diagnoses the failure, commits
a fix, and pushes the updated branch. A rolling cap prevents endless repair
loops on the same Job.

## Retry

Trigger: an operator retries a failed or completed Job.

```text
prepare -> retry_until(implement -> grader_fanout -> grader_collect) -> coverage_analyze -> summarize -> test_plan -> pr_open
```

Retry uses the same shape as Initial on the existing Job and branch.
`pr_open` is idempotent: if a PR already exists, Syrus pushes new commits
instead of opening a second PR.

## Rebase

Trigger: GitHub reports a controlled PR branch as unmergeable.

```text
auto_rebase -> agent_rebase -> force_push
```

Syrus first tries a deterministic `git rebase`. If it succeeds,
`agent_rebase` is cancelled and the branch is force-pushed with an explicit
`--force-with-lease` against the observed remote SHA. If conflicts remain,
the agent resolves them before the same guarded push.

Stacked branches use `stack_rebase`: Syrus walks the stack from root to leaf,
rebases each branch, and falls back to the agent for conflicts.

## Auto-Merge

Trigger: an approved Job reaches the landing queue.

```text
mergeability_preflight -> prepare -> retry_until(grader_fanout -> grader_collect, repair: landing_fix) -> coverage_analyze -> push -> auto_merge
```

The final gate verifies mergeability, runs required graders on the exact PR
branch Syrus is about to merge, lets the agent commit bounded `landing_fix`
repairs when graders fail, pushes any final fixes, and re-checks GitHub
approval, mergeability, branch state, and repository policy before calling
the merge API.

Syrus can reuse a prior green grader result for the same head/base pair, and
repositories can choose to trust clean rebases when the operator accepts that
trade-off.

## Epic Merge-Train

Trigger: an Epic whose open child Jobs are all approved, when merge-train is
enabled.

```text
merge_train_assemble -> merge_train_build -> prepare -> retry_until(grader_fanout -> grader_collect, repair: landing_fix) -> coverage_analyze -> merge_train_land
```

The train builds one integration branch from the Epic's children in
dependency order, runs graders once on the combined tree, lets the agent
commit reconciliation fixes if needed, and lands the whole Epic as one
atomic merge. If the base branch moves during landing, Syrus tries an
incremental `merge_train_rebase`, re-runs graders, and then lands after the
rebase. If the train cannot be repaired, no child PR lands.

## Coding Handoff And Local Mode Handoff

Coding Mode and Local Mode are gated product surfaces. They let a chat or
local daemon commit implementation work before handing the branch back to
Syrus automation.

New PR handoff:

```text
prepare -> grader_fanout -> grader_collect -> summarize -> test_plan -> pr_open
```

Existing PR handoff:

```text
prepare -> grader_fanout -> grader_collect -> summarize_amend -> try(push)
```

Coding-handoff grader failures can return the Job to coding mode so the
operator and agent can fix the branch and hand it off again.

## Main Branch Grader

Trigger: polling detects a new default-branch HEAD and repository main
health checks are enabled.

```text
prepare -> grader_fanout -> grader_collect
```

This hidden anchor Job checks whether main is already broken before active
Jobs rebase onto it. The result updates repository health and can suppress
misleading repair work when failures come from main rather than the PR.

## Prepare, Graders, Coverage, And PR Copy

`prepare` runs explicit `.syrus.yml` setup commands or conservative
auto-detected commands from lockfiles. Explicit commands hard-fail when they
fail; guessed commands soft-fail so the agent can still add or fix setup.

`grader_fanout` reads `.syrus.yml` and creates one immutable grader Step per
configured grader. `grader_collect` aggregates required failures and drives
bounded retry loops. Coverage artifacts are parsed by `coverage_analyze`;
when configured, Syrus can post or update a coverage PR comment.

`summarize`, `summarize_amend`, and `test_plan` are short agentic Steps that
store PR copy and reviewer checks through the MCP sidecar. If a previous
agentic Step already stored the needed artifact, Syrus skips the extra agent
call and promotes the artifact directly.

Next: [Features](/docs/features) explains where operators see and control
these workflows.
