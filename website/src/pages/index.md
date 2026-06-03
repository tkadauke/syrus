---
title: Syrus
description: Self-hosted, multi-user, BYOK automation for the GitHub issue-to-PR loop.
---

# Syrus

> *Bis dat qui cito dat.*
> He gives twice who gives quickly. — Publilius Syrus

Syrus is a self-hosted automation harness that turns GitHub issues,
operator prompts, schedules, and PR feedback into coding-agent runs that
open or update pull requests.

Syrus is a self-hosted, multi-user, bring-your-own-key harness for the
GitHub issue-to-PR loop. It turns issues, review feedback, scheduled
tasks, retries, and rebases into agent runs, then captures the commits and
opens or updates the pull request.

[Try it locally](/docs/deployment/try-it-locally) &nbsp;&nbsp;
[Get started](/docs/getting-started) &nbsp;&nbsp;
[Read the docs](/docs/what-is-syrus) &nbsp;&nbsp;
[View source](https://github.com/tkadauke/syrus)

## The Loop

Syrus is built around a practical code-review loop:

```text
GitHub issue
  -> Syrus Job
  -> agent writes code in a cloned workspace
  -> Syrus commits the result
  -> pull request
```

The agent handles the part that benefits from language and judgment.
Syrus handles the repeatable mechanics around it: polling GitHub,
creating workspaces, running repository setup, tracking state, capturing
transcripts and diffs, pushing branches, opening PRs, retrying failures,
and keeping the work attached to the original request.

It owns the deterministic plumbing: polling, clones, branches, setup
commands, transcripts, diffs, PR copy, pushes, retries, and cleanup. The
agent gets to focus on the code.

You do not need to understand the internal Job and Workflow model to use
it. Label an issue, start a direct job, schedule maintenance, or respond
to PR feedback; Syrus turns that request into a traceable agent run and
a normal pull request your existing review process can accept or reject.

## Why Self-Hosted Matters

Syrus is meant for teams and operators who want coding-agent automation
without moving the center of control outside their own environment.

Your repositories stay registered in your Syrus instance. Your GitHub
credentials and agent-provider keys are stored and encrypted there. Your
transcripts, diffs, logs, costs, retries, and operational history remain
in infrastructure you control. If your team already has rules for network
access, audit trails, branch protection, Kubernetes, backups, or secret
handling, Syrus fits into that operating model instead of replacing it
with a black box.

That also makes it easier to be honest about responsibility. Syrus opens
pull requests; it does not merge code behind your back. Your CI, review
policy, and release process still decide what lands.

## The Product Shape

Syrus is a Rails web app plus a Solid Queue worker and database. The web UI
is for operators: add credentials, register repos, inspect Jobs, read
transcripts, retry failures, manage schedules, and cancel work. The worker
does the long-running work: polls GitHub, prepares repositories, invokes
agents, pushes branches, opens PRs, and cleans workspaces.

The MVP trust boundary is practical rather than magical. Register
repositories whose setup commands you are willing to execute, scope tokens
narrowly, and review the generated PR before merging.

## What You Can Use It For

**Issue ingestion.** Label GitHub issues and let Syrus create the branch,
run the agent, capture the diff, and open the PR.

**Direct jobs and chats.** Start ad-hoc work from the UI when the request
does not belong in GitHub yet, or use chat to shape a proposal before it
becomes a job.

**Scheduled maintenance.** Run recurring prompts for dependency hygiene,
documentation upkeep, repository audits, and other low-drama maintenance
work.

**PR feedback and retries.** Send review comments, failed checks, retry
requests, and rebase work back through the same controlled pipeline so
follow-up commits stay attached to the PR.

## Start Small

The fastest evaluation path runs Syrus once against a local checkout and
prints a diff. It does not require a GitHub App, database, or persistent
service.

For the full product, start with the getting-started guide. It walks
through choosing a deployment path, registering a repository, labeling a
small issue, and watching Syrus open the first PR.

[Try it locally](/docs/deployment/try-it-locally) &nbsp;&nbsp;
[Get started](/docs/getting-started) &nbsp;&nbsp;
[Read the docs](/docs/what-is-syrus) &nbsp;&nbsp;
[View source](https://github.com/tkadauke/syrus)
