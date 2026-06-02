---
title: Syrus
description: Self-hosted, multi-user, BYOK automation for the GitHub issue-to-PR loop.
---

# Syrus

> *Bis dat qui cito dat.*
> He gives twice who gives quickly. — Publilius Syrus

Syrus is a self-hosted, multi-user, bring-your-own-key harness for the
GitHub issue-to-PR loop. It turns issues, review feedback, scheduled
tasks, retries, and rebases into agent runs, then captures the commits and
opens or updates the pull request.

It owns the deterministic plumbing: polling, clones, branches, setup
commands, transcripts, diffs, PR copy, pushes, retries, and cleanup. The
agent gets to focus on the code.

[Try it locally](/docs/deployment/try-it-locally) | [Read the docs](/docs) | [Star on GitHub](https://github.com/tkadauke/syrus)

## What Syrus Does

```text
GitHub issue with label
  -> Syrus poller
  -> Job
  -> prepare
  -> agent implements
  -> summarize
  -> pull request
```

After the PR exists, Syrus keeps the thread alive. It can respond to PR
feedback, attempt CI-failure repairs, retry failed runs, rebase branches
it controls, and run scheduled repository chores.

The source of truth stays where teams already work: GitHub issues,
branches, checks, comments, and pull requests.

## Why It Exists

Hosted coding agents are convenient, but they ask hard questions: where do
the credentials live, who can read the transcript, how does the branch get
pushed, what happens when CI fails, and how do several users share the same
automation without sharing one secret?

Syrus answers by keeping the harness in your deployment:

- **You own the keys.** Users bring their own GitHub and agent
  credentials. Syrus stores them encrypted in your database.
- **You keep the audit trail.** Jobs, Workflows, Runs, transcripts, diffs,
  PR copy, costs, and logs stay in your instance.
- **You stay in GitHub.** Issues become PRs. Review comments become
  follow-up commits. Checks and branch protection still matter.
- **Your team can share it.** One Syrus install can serve multiple users
  and repositories with per-user credentials and repository-level provider
  overrides.

## The Product Shape

Syrus is a Rails web app plus a Solid Queue worker and database. The web UI
is for operators: add credentials, register repos, inspect Jobs, read
transcripts, retry failures, manage schedules, and cancel work. The worker
does the long-running work: polls GitHub, prepares repositories, invokes
agents, pushes branches, opens PRs, and cleans workspaces.

The MVP trust boundary is practical rather than magical. Register
repositories whose setup commands you are willing to execute, scope tokens
narrowly, and review the generated PR before merging.

## Get Started

| Path | Use it when | Start here |
| --- | --- | --- |
| Local evaluation | You want a one-off diff against a local checkout | [Try it locally](/docs/deployment/try-it-locally) |
| Self-hosted app | You want the real issue-to-PR loop for yourself or a small team | [Getting Started](/docs/getting-started) |
| Operations | You are planning backups, workers, credentials, and failure handling | [Deployment](/docs/deployment) |

Syrus has been working on itself since its first week. The public docs are
written from that operating model: explain the product honestly, show the
workflow, and keep the recovery paths concrete.

---

[What is Syrus?](/docs/what-is-syrus) | [Why use Syrus?](/docs/why-use-syrus) | [About the name](/about)
