---
title: Concepts
description: Job, Workflow, Step, Run — the four moving parts of Syrus and how they fit together.
---

# Concepts

Syrus has four moving parts: **Job**, **Workflow**, **Step**,
**Run**. Each maps to a database row; each has its own state
machine.

This page is the skimmable version. The canonical, maintainer-level
reference is
[`ARCHITECTURE.md`](https://github.com/tkadauke/syrus/blob/main/ARCHITECTURE.md).

## Job

A Job is the source-of-truth thread. There is one Job for each GitHub
issue, scheduled task fire, or ad-hoc prompt that Syrus decides to
handle.

The Job owns the long-lived identifiers:

- repository and user
- issue number, when the source is a GitHub issue
- fork review PR number — the staging PR on the fork (feature branch → fork
  default branch) opened when the job targets a different upstream repository;
  closed after approval
- PR number, once Syrus opens one (on the upstream when cross-fork)
- PR repository — the repository where the PR lives; differs from the working
  repository when Syrus opens a cross-fork PR against an upstream
- branch name, reused by follow-up attempts
- closure reason, when the thread ends

Issue Jobs usually start from a labeled GitHub issue. Scheduled Jobs
start from a recurring or one-shot task. Direct Jobs start from an
operator prompt.

:::note
Think of a Job as the conversation thread. It survives retries,
review feedback, CI-failure follow-ups, and rebases.
:::

## Workflow

A Workflow is one attempt to move a Job forward. It is the top-level
execution unit for a specific trigger.

Common trigger kinds are:

| Trigger kind | What it means |
| --- | --- |
| `initial` | First attempt for a Job. Creates the branch and opens the PR. |
| `pr_comment` | Follow-up after review or conversation feedback on the PR. |
| `chat_feedback` | Follow-up submitted from Syrus Chat after operator agreement. |
| `ci_failure` | Follow-up after failing checks on the PR head SHA. |
| `rebase` | Maintenance attempt that rebases a controlled branch onto the base branch. |
| `retry` | Operator asks Syrus to run the normal attempt again. |
| `manual` | Operator supplies an explicit manual prompt. |

Each trigger kind maps to a Workflow template: a sequence of Steps.
For the template-and-DAG view, continue to [Workflows](/docs/workflows).

## Step

A Step is one stage inside a Workflow. Each `Step.kind` has its own
handler under `app/services/steps/`.

Examples include:

- `prepare`, which installs dependencies from configured setup commands
- `implement`, `respond`, and `analyze_and_fix`, which invoke the agent
- `summarize` and `summarize_amend`, which collect PR copy
- `pr_open`, `push`, `auto_rebase`, and `force_push`, which perform
  deterministic service work

Steps keep the Workflow readable. The agentic parts and the boring
GitHub plumbing are explicit stages instead of one large worker method.

## Run

A Run is one attempt at executing a Step.

It carries per-attempt state:

- prompt
- agent provider metadata
- transcript-derived metadata, such as turns and outcome
- captured diff
- head SHA
- PR title, PR body, and operator-facing summary

If a Step is retried, the new attempt is represented by a new Run rather
than mutating history.

## State Machines

Workflows, Steps, and Runs use the same core lifecycle:

<svg role="img" aria-labelledby="run-state-title" viewBox="0 0 760 170" width="100%" xmlns="http://www.w3.org/2000/svg">
  <title id="run-state-title">Run and Workflow state machine</title>
  <defs>
    <marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">
      <path d="M0,0 L0,6 L9,3 z" fill="currentColor" />
    </marker>
  </defs>
  <g fill="none" stroke="currentColor" stroke-width="2" marker-end="url(#arrow)">
    <path d="M150 85 H280" />
    <path d="M430 55 H560" />
    <path d="M430 85 H560" />
    <path d="M430 115 H560" />
  </g>
  <g fill="var(--sl-color-bg, #fff)" stroke="currentColor" stroke-width="2">
    <rect x="35" y="55" width="115" height="60" rx="8" />
    <rect x="280" y="55" width="150" height="60" rx="8" />
    <rect x="560" y="25" width="150" height="45" rx="8" />
    <rect x="560" y="78" width="150" height="45" rx="8" />
    <rect x="560" y="131" width="150" height="45" rx="8" />
  </g>
  <g fill="currentColor" font-family="system-ui, sans-serif" font-size="18" text-anchor="middle">
    <text x="92.5" y="92">queued</text>
    <text x="355" y="92">running</text>
    <text x="635" y="55">succeeded</text>
    <text x="635" y="108">failed</text>
    <text x="635" y="161">cancelled</text>
  </g>
</svg>

In AASM terms:

```text
queued -> running -> succeeded
                  -> failed
                  -> cancelled
```

Runs can also fail or cancel directly from `queued` when Syrus detects
that the work should not start.

:::tip
Job state is intentionally simpler: `open` or `closed`. The Job is the
thread; Workflows and Runs are the attempts.
:::

## MCP Sidecar

Agent processes talk back to Syrus through a small MCP sidecar. The
sidecar runs next to the agent over stdio, boots the Syrus Rails app,
and writes structured results onto the current Workflow or Run.

That pattern gives the agent a narrow set of explicit signals instead
of asking Syrus to scrape prose from the transcript. The important
signals are:

| Signal | Purpose |
| --- | --- |
| `submit_summary` | Provide PR title, PR body, and a short run summary. |
| `submit_test_plan` | Provide reviewer-facing test steps and optional notes. |

`submit_summary` is the core PR-copy path: the PR opener reads the
structured title and body first, then falls back to generated or
templated copy only if the agent did not provide them. `submit_test_plan`
adds a structured `Test Plan` section to Initial PR bodies when the plan is
available. The section starts with a copy-pasteable
`syrus checkout JOB-<id>` command.

## The Shape Of A Normal Issue

The common path looks like this:

```text
GitHub issue with label
  -> Job
  -> initial Workflow
  -> prepare Step / Run
  -> implement Step / Run
  -> summarize Step / Run
  -> pr_open Step / Run
  -> GitHub pull request
```

Follow-up comments, failing CI, retries, and rebases create new Workflows
on the same Job instead of creating a second thread.

Next: [Workflows](/docs/workflows) explains how those templates map
to stages and future DAG-shaped execution.
