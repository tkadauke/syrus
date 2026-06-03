---
title: Syrus
description: Self-hosted, multi-user, BYOK issue-to-PR automation for engineering teams.
---

# Syrus

> *Bis dat qui cito dat.*
> He gives twice who gives quickly. — Publilius Syrus

Syrus is a self-hosted automation harness for agentic coding work. It
turns GitHub issues, PR feedback, scheduled tasks, retries, and rebases
into agent runs, then captures the commits and opens or updates the pull
request.

The point is not to make the language model understand your deployment
pipeline. Syrus owns the deterministic plumbing: cloning repositories,
creating branches, preparing workspaces, running the agent, recording
transcripts and diffs, pushing commits, and keeping the PR current. The
agent writes code; Syrus handles the job control around it.

[Try it locally](/docs/deployment/try-it-locally) · [Read the docs](/docs/getting-started) · [Star on GitHub](https://github.com/tkadauke/syrus)

## What Syrus Does

Give Syrus a connected GitHub repository and a trigger label. When an
issue is labeled, Syrus creates a Job, runs a Workflow, lets the agent
make the code change in an isolated clone, and opens the PR. When a
reviewer leaves feedback, Syrus can run a follow-up attempt on the same
branch. When a scheduled task fires, it uses the same pipeline without a
GitHub issue. When a PR needs a retry or rebase, Syrus treats that as
another controlled Workflow instead of a one-off shell adventure.

The core loop is deliberately boring:

```text
GitHub issue or task
  -> Syrus poller
  -> prepared workspace
  -> agent run
  -> captured diff and transcript
  -> commit, push, pull request
```

Operators see the work as Jobs, Workflows, Steps, and Runs. That gives
each attempt a state, a log, a diff, and a link back to the GitHub PR
instead of leaving agent work scattered across terminal sessions.

## Why Teams Run It

**You own the keys.** Syrus is BYOK: run it with your own agent provider
credentials and GitHub credentials, inside infrastructure you control.

**It is multi-user from day one.** Repositories, credentials, scheduled
tasks, retries, PR feedback, and operator actions are modeled for teams,
not just a single local coding session.

**It keeps agent work auditable.** Each run records prompts, transcripts,
tool output, diffs, PR copy, queue state, and operational logs so you can
debug what happened after the PR exists.

**It handles more than first drafts.** Initial issue work, PR comments,
CI-failure retries, scheduled maintenance, manual retries, and rebases
all share the same harness instead of becoming separate scripts.

## A Concrete Example

1. File a GitHub issue: "Add pagination to the admin jobs list."
2. Add the repository's Syrus trigger label.
3. Syrus notices the issue, clones the repo, runs setup, and starts the
   configured agent.
4. The agent edits the code and tests.
5. Syrus commits the change, captures the diff, opens the PR, and keeps
   the Job page tied to the transcript and pull request.
6. A reviewer asks for a tweak. Syrus runs the follow-up on the same
   branch and pushes the update.

That is the product: not just an agent prompt, but the machinery around
the prompt that lets a team delegate real GitHub work repeatedly.

## Deployment Paths

Start small, then deploy the full loop when the product proves useful.

| Path | Best for | Start here |
| --- | --- | --- |
| Local evaluation | Seeing Syrus produce a diff against your own checkout without GitHub setup | [Try it locally](/docs/deployment/try-it-locally) |
| Docker Compose | Running the web app, worker, database, GitHub polling, and PR flow for a small team | [Docker Compose guide](/docs/deployment/docker-compose) |
| Kubernetes | Operating Syrus on shared infrastructure with persistent clone storage and separate web/worker pods | [Kubernetes guide](/docs/deployment/kubernetes) |

If you are still choosing a path, read [Getting Started](/docs/getting-started)
or the [deployment overview](/docs/deployment).

## Honest Status

Syrus is early software, built in the open style of a tool that has to
operate itself before it can ask anyone else to trust it. The public
website and docs are being assembled alongside the product surface. Some
deployment pages describe target flows that are still being polished; the
pages say so where that is true.

What is already clear is the shape: self-hosted, multi-user, BYOK
automation that turns GitHub work into controlled agent runs and PRs.

## Next

[Try Syrus locally](/docs/deployment/try-it-locally) if you want the
shortest proof. [Read the concepts](/docs/concepts) if you want the
mental model. [Read the naming story](/about) if you want to know why a
Roman maxim writer is haunting your pull-request automation.
