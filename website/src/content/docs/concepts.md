---
title: Concepts
description: Core Syrus objects, states, trigger kinds, and ownership model.
---

# Concepts

Syrus turns repository work into a tracked sequence of database records,
workspace state, agent transcripts, grader results, and GitHub updates. The
names show up throughout the app, CLI, logs, and PR copy.

## Repository

A Repository is a GitHub repository known to Syrus. It stores the GitHub
slug, default branch, trigger label, polling state, prepare behavior,
provider overrides, approval behavior, and landing settings. Repository
pollers are outbound-only: Syrus periodically asks GitHub what changed
instead of receiving webhooks.

## Job

A Job is the operator-visible thread of work. It can come from a GitHub
issue, a scheduled task fire, a direct prompt, a chat proposal, coding mode,
or local mode. The Job carries source context, repository, branch, PR
numbers, dependency gates, credential mode, agent provider, priority, state,
logs, attachments, and links to its Workflows.

Primary Job kinds:

| Kind | Meaning |
| --- | --- |
| `issue` | Work ingested from a labeled GitHub issue. |
| `cron` | Work created by a scheduled task. |
| `direct` | Work created from an operator prompt without a GitHub issue. |

Jobs are long-lived. A single Job can have an initial implementation
Workflow, multiple PR-feedback Workflows, retries, rebases, CI repairs, and
landing attempts.

## Workflow

A Workflow is one attempt to advance a Job for a specific trigger kind. It
owns a chain of Steps and one shared workspace under
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`. The workspace is cleaned up
after the Workflow reaches a terminal state, not after every Step.

Common trigger kinds include `initial`, `pr_comment`, `chat_feedback`,
`ci_failure`, `retry`, `rebase`, `stack_rebase`, `auto_merge`,
`merge_train`, `coding_handoff`, `local_mode_handoff`, and `main_grader`.
See [Workflows](/docs/workflows) for the built-in chains.

## Step

A Step is one node inside a Workflow chain. Some Steps are deterministic
service work, such as `prepare`, `grader_fanout`, `grader_collect`, `push`,
`pr_open`, and `auto_merge`. Others invoke the configured agent, such as
`implement`, `respond`, `analyze_and_fix`, `landing_fix`, and
`agent_rebase`.

Step chains can expand while running. For example, `grader_fanout` reads
`.syrus.yml` and materializes one `grader` Step per configured grader, and
`try(push)` can insert an agentic rebase recovery branch if the remote PR
branch advanced.

## Run

A Run is an attempt to execute one Step. Runs carry prompt text, provider,
session metadata, transcript, spawned process data, diagnostics, diff, cost,
and outcome. Retrying a failed Step creates another Run and preserves the
old transcript for audit.

## States

Jobs represent product progress. Workflows, Steps, and Runs represent
execution progress.

```text
Job:       open <-> closed
Workflow:  queued -> running -> succeeded | failed | cancelled
Step:      queued -> running -> succeeded | failed | cancelled
Run:       queued -> running -> succeeded | failed | cancelled
```

Jobs also have product states such as queued, running, implemented,
approved, landing, failed, coding, closed, and needs-triage states. Closed
Jobs record why they closed, including merged PR, externally merged PR,
closed PR, or no changes.

## Dependencies

Jobs and Epics can depend on other Jobs and Epics. Issue-body dependency
markers create parsed dependency records; operators can add manual
dependencies in the app. Syrus blocks Workflow dispatch until dependencies
reach successful terminal outcomes. Same-Epic dependencies can be satisfied
by approval while the Epic landing queue handles final merge ordering.

## Epics

An Epic groups related Jobs inside one repository. Epics have board states,
child Jobs, dependencies, history, and optional merge-train landing. They do
not run agent work by themselves; starting an Epic dispatches ready child
Jobs, and dependent children follow when blockers clear.

## Credentials

Jobs persist the credential mode chosen at creation time. GitHub App
installation tokens are preferred when available; PAT fallback is used when
an installation is not available. Agent provider selection is separate and
comes from user defaults, repository overrides, membership overrides, or an
explicit command choice.

Next: [Features](/docs/features) maps these objects to user-facing product
surfaces, and [Workflows](/docs/workflows) explains the execution chains.
