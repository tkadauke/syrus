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
or ad hoc Job that uses the standard issue-to-PR path. Steps:
`prepare -> implement -> summarize -> pr_open`. The agent makes and commits
the change during `implement`, `summarize` collects PR copy via MCP and
amends the commit message, and `pr_open` pushes the branch and opens the
pull request. A successful Initial workflow leaves the Job open with a PR
number attached.

### PrFeedback

Trigger: new review feedback or PR comments on an existing Syrus PR. Steps:
`prepare -> respond -> summarize_amend -> push`. The agent receives the new
comments plus PR context, commits follow-up changes on the existing branch,
then `summarize_amend` rewrites the follow-up commit message. A successful
workflow pushes to the already-open PR.

### Rebase

Trigger: polling finds a PR branch we control that GitHub reports as
unmergeable. Steps: `auto_rebase -> agent_rebase -> force_push`. Syrus first
tries a deterministic `git rebase`. If that succeeds, it cancels
`agent_rebase` and proceeds to `force_push`; if conflicts remain, the agent
resolves them. A successful workflow force-pushes the rebased branch and
does not open or rewrite PR copy.

### Retry

Trigger: an operator retries a failed or completed Job. Steps:
`prepare -> implement -> summarize -> pr_open`. It has the same shape as
Initial, but runs on the existing Job and branch. `pr_open` is idempotent:
if a PR already exists, it pushes the new commits instead of opening a
second PR.

### Manual

Trigger: an operator starts a free-form run. Steps: `manual`. The operator's
prompt is passed directly to the configured agent provider. Manual
workflows capture transcript and diff information, but they do not push or
open a PR by themselves.

### Resume

Trigger: an operator clicks Resume on a failed or cancelled Run that has a
captured Claude session. Steps: `manual`. The Run carries the prior session
ID so the provider can resume the agent conversation. In v1 this is a
single continuation step; future DAG work can resume from the failed node
and continue downstream.

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
| `implement` | Yes | Make the requested code change for Initial, Retry, cron, and ad hoc work |
| `respond` | Yes | Address PR review feedback on an existing branch |
| `analyze_and_fix` | Yes | Diagnose failed CI checks and commit a fix |
| `summarize` | Yes | Resume the implementation session and collect PR title/body/summary through MCP |
| `summarize_amend` | Yes | Produce follow-up commit copy for PR feedback and CI-failure workflows |
| `pr_open` | No | Push the branch and open the pull request if one does not already exist |
| `push` | No | Push commits to an existing PR branch and update the cost footer |
| `auto_rebase` | No | Try a deterministic rebase before involving an agent |
| `agent_rebase` | Yes | Resolve rebase conflicts with the agent |
| `force_push` | No | Force-push a rebased branch |
| `manual` | Yes | Run an operator-supplied prompt |

Planned Step kinds include
[`apply_suggestions`](https://github.com/tkadauke/syrus/issues/191) for
structured GitHub suggestion application and
[`triage`](https://github.com/tkadauke/syrus/issues/176) for a short
readiness check before an expensive implementation run. Those are roadmap
items, not current template steps.

## Template Selection

Syrus chooses the template from the trigger kind:

| Trigger kind | Template |
| --- | --- |
| `initial` | `Workflows::Initial` |
| `pr_comment` | `Workflows::PrFeedback` |
| `ci_failure` | `Workflows::CiFailure` |
| `rebase` | `Workflows::Rebase` |
| `retry` | `Workflows::Retry` |
| `manual` | `Workflows::Manual` |
| `resume` | `Workflows::Resume` |
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
