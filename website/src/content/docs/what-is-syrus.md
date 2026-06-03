---
title: What is Syrus?
description: The product model behind Syrus and the issue-to-PR loop it automates.
---

# What is Syrus?

Syrus is a self-hosted, multi-user harness for coding agents. It turns
structured software intent into pull requests while keeping the
deterministic plumbing outside the model.

The normal loop is:

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
Claude Code or Codex, gives them the right repository workspace and
prompt, records what happened, and handles the surrounding lifecycle:
clones, branches, setup commands, transcripts, diffs, retries, PR
creation, follow-up feedback, and cleanup.

## The 30-Second Version

You register a GitHub repository in Syrus and choose a trigger label,
usually `syrus`. When an issue gets that label, Syrus creates a Job,
checks out the repo in a worker-managed workspace, runs preparation
commands, invokes the configured agent, captures the resulting diff, asks
for PR copy, pushes a branch, and opens a pull request.

After the PR exists, Syrus keeps watching it. New review feedback creates
a follow-up Workflow on the same branch. Failing checks can create a CI
repair Workflow. If the branch becomes unmergeable, Syrus can run its
rebase workflow. Operators can also retry, cancel, run direct Jobs, or
schedule recurring prompts.

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
making the change, running tests when possible, and explaining what it did.

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

Syrus uses five terms everywhere:

| Term | Meaning |
| --- | --- |
| Epic | A repository-local group of related Jobs for larger goals that need sequencing. |
| Job | The long-lived thread for one issue, scheduled task, or direct prompt. |
| Workflow | One attempt to move that Job forward. |
| Step | A stage inside a Workflow, such as `prepare`, `implement`, or `pr_open`. |
| Run | One execution of a Step, with prompt, transcript, metadata, and diff. |

Read [Concepts](/docs/concepts) for the state machines and
[Workflows](/docs/workflows) for the built-in pipelines.
