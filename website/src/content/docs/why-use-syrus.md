---
title: Why use Syrus?
description: When Syrus is a good fit, what it optimizes for, and where its trade-offs are.
---

# Why use Syrus?

Use Syrus when you want coding agents to participate in your normal GitHub
workflow, but you want the automation harness, credentials, logs, and
operational decisions under your control.

Syrus is most useful for teams that already trust GitHub issues and pull
requests as their software workflow. It makes the agent another worker in
that loop instead of asking the team to move work into a separate hosted
environment.

## Own The Keys

Syrus is bring-your-own-key. Users store their own GitHub and agent
credentials in the Syrus instance, encrypted with Rails Active Record
Encryption. The database, logs, transcripts, and workspace storage live in
your deployment.

That matters when your evaluation questions are:

- Which token pushed this branch?
- Which provider ran this job?
- What prompt and transcript produced this diff?
- Where are repository clones stored?
- How do we revoke access?

Hosted products may have cleaner onboarding. Syrus gives you a smaller
trust boundary.

## Keep GitHub As The Workflow

Syrus starts from GitHub issues, responds to PR feedback, reacts to
failing checks, and updates PR branches. Reviewers still review pull
requests. CI still runs in GitHub. Branch protection still applies.

The result is less theatrical than a separate autonomous dashboard, but
it fits how most code already moves:

```text
issue -> branch -> commit -> PR -> review -> CI -> merge
```

Syrus makes that loop agent-addressable without moving the source of truth.

## Self-Host The Boring Parts

Agent runs are only useful when the surrounding machinery is reliable.
Syrus centralizes the repeatable work that per-repository scripts and
one-off GitHub Actions tend to duplicate:

- Pollers for issues, feedback, checks, mergeability, and schedules.
- Durable Job/Workflow/Run state.
- Per-workflow workspaces and clone caches.
- Preparation commands with timeouts and scrubbed environment.
- Diff capture that matches GitHub's Files changed view.
- PR copy collection, push behavior, retries, cancellation, and cleanup.

This is the boring product surface on purpose. Reliable boring machinery
is what lets the model spend its attention on code.

## Multi-User From The Start

Syrus is not a single-user desktop loop stretched into a server. Users
have their own GitHub credentials, provider credentials, provider defaults,
max-turn settings, scheduling pause controls, and repository access model.
Repositories can override the provider when a codebase needs a different
agent than the user's default.

That makes Syrus a better fit for a small team or internal platform than
a personal script, while keeping the deployment small enough to understand.

## Good Fits

Syrus is a strong fit when you want to:

- Turn well-scoped issues into PRs.
- Let agents address review comments on their own branches.
- Give CI failures a bounded repair attempt.
- Run recurring repository hygiene tasks.
- Keep transcripts and diffs attached to durable work records.
- Operate with your own GitHub and model-provider credentials.

## Poor Fits

Syrus is probably not the right answer when you need:

- A hosted product with no infrastructure ownership.
- Hard isolation for untrusted arbitrary code execution.
- Real-time webhook reaction instead of polling.
- A model-agnostic research agent framework.
- A replacement for review, testing, and merge policy.

Start with [Getting Started](/docs/getting-started) if the trade-off is
right, or [FAQ](/docs/faq) if you are comparing Syrus with other tools.
