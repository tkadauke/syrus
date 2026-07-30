---
title: What is Syrus?
description: The product model behind Syrus and the issue-to-PR loop it automates.
---

# What is Syrus?

Syrus is a self-hosted, multi-user harness for coding agents. It turns
structured software intent into pull requests while keeping the
deterministic plumbing outside the model.

The common GitHub issue loop is:

```text
GitHub issue
  -> Syrus poller
  -> Job
  -> Workflow
  -> agent Run
  -> commit
  -> pull request
```

Syrus does not try to be the coding model. It runs providers such as
Claude Code or Codex, gives them a repository workspace and a bounded
prompt, records what happened, and handles the surrounding lifecycle:
clones, branches, setup commands, transcripts, diffs, retries, rebases,
PR creation, follow-up feedback, and cleanup.

## The 30-Second Version

You register a GitHub repository in Syrus and choose a trigger label,
usually `syrus`. When an issue gets that label, Syrus creates a Job,
checks out the repo in a worker-managed workspace, runs preparation
commands, invokes the configured agent, captures the resulting diff, asks
for PR copy, pushes a branch, and opens a pull request.

After the PR exists, Syrus keeps watching it. New human review feedback
creates a follow-up Workflow on the same branch; automated comments from
the Syrus GitHub App bot are ignored. Failing checks can create a CI
repair Workflow. If the branch becomes unmergeable, Syrus can run its
rebase workflow. Operators can also retry, cancel, run direct Jobs, or
schedule recurring prompts.

## Ways Work Starts

Syrus has one execution model with several entry points:

| Entry point | What creates the Job | Typical use |
| --- | --- | --- |
| GitHub issue | A repository issue with the trigger label, or an issue delegated from Syrus. | Normal issue-to-PR work that should stay visible in GitHub planning. |
| PR feedback | A human comment or review on a Syrus-owned PR. | Follow-up commits on the same branch after review. |
| CI failure | A failing check on a Syrus-owned PR. | Bounded repair attempts without asking a human to re-prompt the agent. |
| Direct Job | An operator prompt in Syrus, not backed by a GitHub issue. | Private context, internal chores, experiments, or urgent work where a GitHub issue would be ceremony. |
| Scheduled task | A recurring cron task or one-shot fire time. | Repeated repository hygiene, dependency chores, docs sweeps, or other periodic maintenance. |
| Rebase | Merge-state polling sees a controlled PR branch become unmergeable. | Keep an open PR current with the base branch. |

Direct Jobs and scheduled Jobs still use the same Job, Workflow, Step,
and Run records as issue-driven work. The source is different; the
operational contract is the same.

## What Syrus Owns

Syrus owns the parts that should be predictable:

- Polling GitHub for issues, PR feedback, checks, mergeability, and
  scheduled work.
- Creating Jobs, Workflows, Steps, and Runs with auditable state.
- Preparing the repository with `.syrus.yml` or lockfile detection.
- Running the selected agent provider with the right prompt and context.
- Capturing transcript, diff, cost metadata, branch SHA, and PR copy.
- Pushing branches, opening PRs, updating existing PRs, and cleaning up
  workspaces.

The agent owns the part that benefits from reasoning: reading the code,
making the change, resolving conflicts when deterministic Git cannot,
running tests when possible, and explaining what it did.

That split is the product thesis. Clone management, branch naming,
environment setup, workflow state, transcript capture, PR opening, and
force-with-lease rebases are ordinary software automation problems. Syrus
keeps those deterministic. Code interpretation and change design are the
agentic parts, so Syrus gives the model enough context to work without
making it remember how the harness should operate.

## Product Shape

Syrus is built for teams that want agentic code work without handing
their repositories, credentials, and audit trail to a hosted service.

It is:

- **Self-hosted**: run the web app, worker, database, and workspace volume
  on infrastructure you control.
- **Bring-your-own-key**: each user supplies their GitHub and agent
  credentials; credentials are encrypted in the Syrus database.
- **Multi-user**: one deployment coordinates work across users and
  repositories while preserving per-user credentials and defaults.
- **GitHub-native**: issues, labels, comments, checks, branches, and pull
  requests remain the system of record for code review.

It is not:

- A hosted SaaS.
- A replacement for code review.
- A hardened sandbox for arbitrary untrusted repositories.
- A custom model or a new agent loop competing with every provider.

## The Core Terms

Syrus uses these terms everywhere:

| Term | Meaning |
| --- | --- |
| Epic | A repository-local group of related Jobs for larger goals that need sequencing. |
| Job | The long-lived thread for one issue, scheduled task fire, or direct prompt. It owns the repository, source prompt, branch, PR number, priority, provider, dependencies, and final closure reason. |
| Workflow | One attempt to move a Job forward. Trigger kinds include `initial`, `pr_comment`, `chat_feedback`, `ci_failure`, `retry`, `manual`, and `rebase`. |
| Step | A stage inside a Workflow, such as `prepare`, `implement`, `summarize`, `pr_open`, `respond`, `auto_rebase`, or `force_push`. |
| Run | One execution of a Step, with prompt, transcript, provider metadata, captured diff, head SHA, PR copy, and outcome. |

The distinction matters operationally. A Job survives across review
comments, retries, CI fixes, and rebases. Each new attempt is a Workflow.
Each Workflow is broken into Steps so deterministic service work and
agentic work are visible. Each Step execution gets a Run so transcripts
and diffs are not overwritten when Syrus retries or follows up.

Read [Concepts](/docs/concepts) for the state machines and
[Workflows](/docs/workflows) for the built-in pipelines.
