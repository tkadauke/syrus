---
title: Workflows
description: Templates that define what an agent does for each trigger kind.
---

# Workflows

A Workflow template is a named sequence of Steps tied to a trigger kind.
When something happens, such as a labelled issue, PR feedback, a retry
click, or an unmergeable branch, Syrus creates a Workflow from the matching
template and starts its first Step.

In v1, templates are linear chains:

```text
Workflow(trigger_kind) -> Step -> Step -> Step
```

Each Step owns one or more Runs. A Run is an attempt to execute that Step.
Retries create new Runs without erasing the old transcript.

## Built-In Templates

### Initial

Trigger: a GitHub issue with the repository's trigger label, or a new cron
or direct Job that uses the standard issue-to-PR path. Steps:
`prepare -> retry_until(implement -> grader_fanout -> grader_collect) -> summarize -> test_plan -> pr_open`.
The agent makes and commits the change during `implement`, graders run from
the repository's `grade:` configuration, and failed required graders feed
the next bounded repair iteration. `summarize` collects PR copy via MCP and
amends the commit message. `test_plan` stores reviewer-facing checks, which
`pr_open` appends as a `Testing` section before pushing the branch and
opening the pull request. For GitHub issue Jobs, the implement prompt includes the
original issue title and body plus subsequent issue comments in
chronological order, so clarifications added before the Run starts are part
of the agent context. A successful Initial workflow leaves the Job open
with a PR number attached.

### PrFeedback

Trigger: new review feedback or PR comments on an existing Syrus PR. Steps:
`prepare -> retry_until(respond -> grader_fanout -> grader_collect) -> summarize_amend -> push`.
The agent receives the new comments plus PR context, commits follow-up
changes on the existing branch, and graders can force another bounded
response iteration before `summarize_amend` rewrites the follow-up commit
message. A successful workflow pushes to the already-open PR.

### Rebase

Trigger: polling finds a PR branch we control that GitHub reports as
unmergeable. Steps: `auto_rebase -> agent_rebase -> force_push`. Syrus first
tries a deterministic `git rebase`. If that succeeds, it cancels
`agent_rebase` and proceeds to `force_push`; if conflicts remain, the agent
resolves them. A successful workflow force-pushes the rebased branch and
does not open or rewrite PR copy. The push uses an explicit
`git push --force-with-lease=<branch>:<observed_sha>` lease so Syrus does
not overwrite an unexpected remote update.

When the unmergeable PR has stack children, Syrus uses `StackRebase` instead
of opening one rebase workflow per Job. Steps:
`stack_auto_rebase -> stack_agent_rebase -> stack_force_push`. The workflow
walks the stack root-first, tries deterministic rebases for each branch, and
falls back to one agent run for the first conflicted branch and everything
below it. After pushing, Syrus refreshes PR bases and re-checks approved Jobs
for landing.

### Retry

Trigger: an operator retries a failed or completed Job. Steps:
`prepare -> retry_until(implement -> grader_fanout -> grader_collect) -> summarize -> pr_open`.
It has the same shape as Initial, but runs on the existing Job and branch.
`pr_open` is idempotent: if a PR already exists, it pushes the new commits
instead of opening a second PR.

### AutoMerge

Trigger: an approved Job reaches the landing queue. Steps:
`retry_until(grader_fanout -> grader_collect, repair: landing_fix) -> push -> auto_merge`.
The final gate first runs graders on the exact PR branch Syrus is about to
merge, after any last rebase. If required graders fail, the agent receives
the grader output and gets a bounded `landing_fix` repair iteration before
the graders run again. `push` publishes any final fix commits, and
`auto_merge` re-checks GitHub approval,
mergeability, branch state, and repository policy immediately before
calling the merge API. Because GitHub recomputes mergeability
asynchronously after a push, `auto_merge` briefly polls for a transient
`unknown` state to settle before deferring, so a completed green grade is
not thrown away just because GitHub had not finished recomputing yet.

Landing attempts reuse a prior green grading result when the exact same
head SHA has already passed required graders, so an unchanged PR does not
spend another full grade cycle at merge time. Repositories can also opt
into **Trust clean rebases** (`trust_clean_rebase_grade`) to carry a
green result across a conflict-free rebase, trading a small
logical-conflict risk for landing throughput.

### MergeTrain (Epic merge-train)

Trigger: an Epic whose every open child is approved, when the merge-train
is enabled (`AppSetting.merge_train_enabled`, default off). Steps:
`merge_train_assemble -> merge_train_build -> prepare ->
retry_until(grader_fanout -> grader_collect, repair: landing_fix) ->
merge_train_land`.

Instead of landing an Epic's PRs one at a time (each rebased onto the
previous merge and graded again), the train integrates all of the Epic's
children — topologically sorted by dependency — into a single integration
branch, runs the graders **once** on the combined tree, lets the agent
commit reconciliation fixes if needed, and then lands the whole branch in
a **single atomic merge**. The child PRs are closed with a back-link to
the integration merge and their Jobs marked merged. If a retry rebuilds
the same integration SHA that already passed required graders, Syrus
reuses that signal and proceeds directly to landing.

The guarantee is **Epic consistency**: an Epic advances as a whole,
green, dependency-closed set or not at all — there are never half-merged
Epics on the base branch. If the grade-and-fix loop can't make the
integrated tree green (or a child won't integrate), the whole attempt
fails and nothing lands; the children revert to needing re-approval, and
re-approving them re-dispatches a fresh train. While the flag is on, Epic
children land only via the train, never individually.

### Manual

Trigger: an operator starts a free-form run. Steps: `manual`. The operator's
prompt is passed directly to the configured agent provider. Manual
workflows capture transcript and diff information, but they do not push or
open a PR by themselves.

### LocalDev

Trigger: `bin/syrus dev` against a local checkout. Steps:
`prepare -> implement`. It uses the same preparation and implementation
handlers as GitHub-driven work, then stops before summary and PR creation.
The CLI returns the produced diff to the local caller.

### CiFailure

Trigger: polling sees failed CI checks on an existing Syrus PR. Steps:
`prepare -> analyze_and_fix -> summarize_amend -> push`. The agent receives
the failing check payload, diagnoses the failure, commits a fix, and pushes
the updated branch. A rolling cap prevents endless CI-failure loops on the
same Job.

## Step Kinds

| Step | Agentic | Purpose |
| --- | --- | --- |
| `prepare` | No | Run deterministic setup from `.syrus.yml` or auto-detected lockfiles |
| `implement` | Yes | Make the requested code change for Initial, Retry, cron, and direct work |
| `respond` | Yes | Address PR review feedback on an existing branch |
| `analyze_and_fix` | Yes | Diagnose failed CI checks and commit a fix |
| `landing_fix` | Yes | Make final merge-gate fixes before the landing graders run |
| `summarize` | Yes | Collect PR title/body/summary through MCP |
| `summarize_amend` | Yes | Produce follow-up commit copy for PR feedback and CI-failure workflows |
| `test_plan` | Yes | Collect reviewer-facing test steps for Initial PR bodies |
| `pr_open` | No | Push the branch and open the pull request if one does not already exist |
| `push` | No | Push commits to an existing PR branch and update the cost footer |
| `grader_fanout` | No | Materialize one grader Step per configured repo grader |
| `grader_collect` | No | Aggregate grader results and decide whether retry_until continues |
| `auto_rebase` | No | Try a deterministic rebase before involving an agent |
| `agent_rebase` | Yes | Resolve rebase conflicts with the agent |
| `force_push` | No | Force-push a rebased branch with an explicit `--force-with-lease` lease |
| `auto_merge` | No | Re-check GitHub merge gates and merge the approved PR |
| `merge_train_assemble` | No | Validate an Epic train's locked members |
| `merge_train_build` | No | Merge the Epic's members into one integration branch |
| `merge_train_land` | No | Atomically merge the integration branch and close member PRs |
| `manual` | Yes | Run an operator-supplied prompt |

Planned Step kinds include
[`triage`](https://github.com/tkadauke/syrus/issues/176) for a short
readiness check before an expensive implementation run. That is a roadmap
item, not a current template step.

## Template Selection

Syrus chooses the template from the trigger kind:

| Trigger kind | Template |
| --- | --- |
| `initial` | `Workflows::Initial` |
| `pr_comment` | `Workflows::PrFeedback` |
| `chat_feedback` | `Workflows::ChatFeedback` |
| `ci_failure` | `Workflows::CiFailure` |
| `rebase` | `Workflows::Rebase` |
| `stack_rebase` | `Workflows::StackRebase` |
| `auto_merge` | `Workflows::AutoMerge` |
| `merge_train` | `Workflows::MergeTrain` |
| `retry` | `Workflows::Retry` |
| `manual` | `Workflows::Manual` |
| `local_dev` | `Workflows::LocalDev` |

The template creates a Workflow row, creates each Step row in order, and
wires `next_step_id` from each Step to its successor. The dispatcher starts
the first Run, then advances the chain as Steps succeed.

## Next: DAG Workflows

Today's linear chain is the v1 implementation of a broader DAG model. The
roadmap keeps v2/v3 focused on explicit parallel branches and
agent-authored edges via MCP, where the template becomes the minimum graph
and the agent can append test plans, graders, or review steps as it learns
what the change needs.

Read the canonical roadmap entry:
[Job as execution DAG](https://github.com/tkadauke/syrus/blob/main/ROADMAP.md#job-as-execution-dag-phased-agent-execution).
