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

## Spend Agent Context On Code

An agent should not need to spend its prompt budget remembering how to
clone the repository, choose a branch name, push with the right token,
open the PR, notice new review comments, or retry a failed workflow. Syrus
keeps those mechanics in application code and gives the agent the smaller
job it is better suited for: understand the repository, make the change,
run useful checks, and report the result.

That separation makes runs easier to reason about. If a branch push,
prepare command, PR open, or deterministic rebase fails, Syrus records
that as workflow state instead of leaving the operator to infer what
happened from an agent transcript.

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

## Keep An Audit Trail

Every Job has durable records for its Workflows, Steps, Runs, prompts,
transcripts, logs, captured diffs, branch SHAs, PR copy, and closure
reason. Follow-up PR feedback, retry attempts, CI-failure repairs, and
rebases become new Workflows on the same Job instead of replacing the
original history.

That gives operators a practical audit trail:

- The prompt that started the work.
- The agent provider and credential mode used.
- The setup and workflow stages that ran before the agent touched code.
- The transcript and diff for each attempt.
- The PR, branch, and final outcome.

The point is not only compliance. It is also debugging. When an agent run
does something surprising, the transcript, diff, logs, and state machine
are attached to the same durable thread.

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

## Keep Humans In Control

Syrus is designed for operator control around agent work, not silent
autonomy. Operators can choose which issues to delegate, create direct
Jobs, schedule recurring tasks, retry failed attempts, cancel work, inspect
transcripts and diffs, and approve or manage Jobs according to repository
policy.

The follow-up flows are explicit too:

- PR feedback creates a `pr_comment` Workflow on the existing Job and
  branch.
- Failing checks can create a bounded `ci_failure` repair Workflow.
- A stuck attempt can be retried without losing the earlier Run history.
- An unmergeable controlled branch can be rebased through deterministic
  Git first, then agent conflict resolution only if needed.

Those controls let a team use agents repeatedly without pretending every
run should be trusted to land untouched.

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

## Repeat Work Across Repositories

The same Syrus deployment can poll many repositories, each with its own
trigger label, provider override, prepare behavior, credentials path,
schedules, and automation settings. The workflow templates stay shared:
issue work, direct Jobs, scheduled Jobs, PR feedback, CI repair, retries,
and rebases all map to known Job/Workflow/Step/Run records.

That makes automation repeatable. A repository can opt into the same
issue-to-PR loop as another repository without copying a pile of scripts,
GitHub Actions, local agent wrappers, and credential glue.

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
