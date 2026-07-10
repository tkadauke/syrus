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

**[Download Syrus for Mac](https://github.com/tkadauke/syrus/releases/latest/download/Syrus.dmg)** — drag to Applications, and the app installs and runs Syrus for you. ([Other platforms & details](/docs/desktop))

[What is Syrus?](/what-is-syrus) · [Why use Syrus?](/why-use-syrus) · [Get Started](/docs/getting-started) · [Run locally](/docs/deployment/docker-compose) · [Read the docs](/docs/getting-started) · [Star on GitHub](https://github.com/tkadauke/syrus)

## The Loop

The shortest proof is a GitHub issue with label-based delegation:
connect a repository, choose the trigger label, and let Syrus turn that
issue into a branch, run, and pull request.

Get Started with the Docker Compose path if you want the shortest route
from a GitHub issue with label `syrus` to a reviewed pull request.

## What Syrus Does

Give Syrus a connected GitHub repository and a trigger label. A typical
first run starts with a GitHub issue with label `syrus`. When an
issue is labeled, Syrus creates a Job, runs a Workflow, lets the agent
make the code change in an isolated clone, and opens the PR. When a
reviewer leaves feedback, Syrus can run a follow-up attempt on the same
branch. When a scheduled task fires, it uses the same pipeline without a
GitHub issue. When a PR needs a retry or rebase, Syrus treats that as
another controlled Workflow instead of a one-off shell adventure.

The standard starting point is a GitHub issue with label-based delegation:
file the issue, add the configured trigger label, and let Syrus carry the
work through to a pull request.

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
instead of leaving agent work scattered across terminal sessions. While
work is executing, Syrus shows the active workflow trigger so operators
can tell whether the current run is initial issue work, PR feedback, a
retry, CI follow-up, or a rebase.

### Label GitHub issues

The shortest path is label-based routing: connect the repository, choose
the trigger label, and let Syrus turn the labeled issue into a tracked run
and pull request.

Get Started with the Docker Compose guide when you want the smallest
proof before connecting a team repository.

Need the longer version? Read [What is Syrus?](/what-is-syrus).

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

For the adoption argument and fit checks, read
[Why use Syrus?](/why-use-syrus).

## A Concrete Example: GitHub issue with label

Start with a GitHub issue with label `syrus`, then let the harness carry
that issue through the workflow.

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

## Get Started

The shortest path is to run Syrus locally, connect a GitHub repository,
and delegate one small GitHub issue with label-based triggering. From
there, move to Docker Compose or Kubernetes when the workflow proves it
can carry real review feedback and repeat attempts.

The shortest proof is a GitHub issue with a trigger label: file the
issue, add the label, and let Syrus carry it through to a pull request.

Choose a deployment path based on how much of the loop you want to run.

## Start Small

Start small, then deploy the full loop when the product proves useful.

Choose the path that matches how much of the system you want to exercise.

| Path | Best for | Start here |
| --- | --- | --- |
| Docker prebuilt | Running the web app, worker, database, GitHub polling, and PR flow on one machine without compiling | [Docker Compose guide](/docs/deployment/docker-compose) |
| Source/custom Docker | Building from the checkout or adding system packages for repository graders | [Docker Compose guide](/docs/deployment/docker-compose#build-or-customize-the-image) |
| Kubernetes | Operating Syrus on shared infrastructure with persistent clone storage and separate web/worker pods | [Kubernetes guide](/docs/deployment/kubernetes) |

If you are still choosing a path, start with [Getting Started](/docs/getting-started)
or the [deployment overview](/docs/deployment).

## Get Started

Use [Docker Compose](/docs/deployment/docker-compose) for the shortest
proof of the full polling, worker, and PR loop, then move to Kubernetes
only when you need cluster operations.

## Honest Status

Syrus is early software, built in the open style of a tool that has to
operate itself before it can ask anyone else to trust it. The public
website and docs are being assembled alongside the product surface. Some
deployment pages describe target flows that are still being polished; the
pages say so where that is true.

What is already clear is the shape: self-hosted, multi-user, BYOK
automation that turns GitHub work into controlled agent runs and PRs.

## Get Started

[Run Syrus locally](/docs/deployment/docker-compose) if you want the
shortest proof. [Read the concepts](/docs/concepts) if you want the
mental model. [Read the naming story](/about) if you want to know why a
Roman maxim writer is haunting your pull-request automation.
