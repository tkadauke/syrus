---
title: Why use Syrus?
description: When Syrus is worth adopting, what it gives an engineering team, and when another tool may fit better.
---

# Why use Syrus?

Use Syrus when you want coding agents to participate in your existing
GitHub workflow without turning every request into a bespoke terminal
session. Syrus gives the agent a prepared workspace and gives the team a
tracked Job, Workflow, transcript, diff, commit, and pull request.

The value is not that Syrus makes models smarter. The value is that it
keeps the surrounding process boring enough for a team to trust: one
source request, one controlled branch, one visible PR, and a durable
record of what happened.

## The Decision In One Table

| You need | Syrus helps by |
| --- | --- |
| GitHub issue-to-PR automation | Polling labeled issues, running an agent, and opening the PR. |
| Review feedback follow-up | Reusing the same branch and pushing a follow-up Workflow. |
| Scheduled maintenance | Turning recurring prompts into Jobs without filing issues by hand. |
| Team visibility | Recording Job, Workflow, Step, and Run state instead of hiding work in a shell. |
| Self-hosted control | Running with your own GitHub credentials, agent credentials, database, and logs. |
| Operational recovery | Making retries, CI-failure attempts, rebases, and queue state explicit. |

If those are not your problems, Syrus may be more machinery than you
need. If they are your problems, that machinery is the product.

## Why Not Just Use An Agent CLI?

An agent CLI is excellent for one developer asking for one change in one
checkout. Syrus is for the repeated team version of that loop.

With only a CLI, someone still has to decide where the work runs, prepare
dependencies, create branches, preserve transcripts, turn output into a
commit, push, open a PR, notice review feedback, retry failed attempts,
and clean up after long-running work.

Syrus makes those responsibilities part of the system:

- **prepare** runs configured setup commands or auto-detected dependency
  installs before the agent starts
- **implement**, **respond**, and **analyze_and_fix** run the agent in a
  Workflow with a specific trigger kind
- **summarize** and **summarize_amend** collect PR copy through structured
  MCP output
- **pr_open**, **push**, and **force_push** handle the deterministic GitHub
  side

That separation keeps the agent focused on the code change and keeps the
harness responsible for state, Git, and PR mechanics.

## Why Self-Host?

Syrus is designed for teams that want the automation close to their
repositories, credentials, and audit logs.

Self-hosting is useful when:

- repository access should stay inside infrastructure you control
- GitHub credentials and agent provider keys should be BYOK
- operators need database-backed visibility into runs and queues
- workers need persistent clone storage for repeated repository work
- you want to choose the agent provider rather than commit to one hosted
  coding-agent product

Self-hosting also means you own the operational work: database, workers,
secrets, upgrades, logs, and backups. Syrus is a better fit when that
tradeoff is acceptable because control and auditability matter more than
outsourcing the harness.

## Why Multi-User From The Start?

Agent automation becomes a team system quickly. Someone files the issue,
someone owns the repository, someone supplies credentials, someone reviews
the PR, and someone debugs the queue when a run fails.

Syrus models that reality directly:

- repositories belong to users and can choose their agent provider
- Jobs keep GitHub issue and PR identifiers together
- Workflows make each attempt visible
- Steps show where the attempt is in the pipeline
- Runs carry the prompt, transcript, diff, and PR metadata
- scheduled tasks and retries are operator actions, not private scripts

That makes Syrus a fit for small teams that want repeatable delegation,
not just individual prompt history.

## Where Syrus Is Strong

Syrus is strongest for bounded GitHub work:

- small product or docs changes from issues
- bug fixes with a clear reproduction
- PR feedback follow-ups
- CI-failure diagnosis and repair
- dependency, cleanup, and maintenance chores on a schedule
- rebasing controlled branches when GitHub reports them unmergeable

The common pattern is written intent in, reviewable pull request out.

## Where Syrus Is Not The Right Fit

Syrus may not fit if:

- you only want interactive local coding help
- your team does not use GitHub issues and pull requests as the workflow
- you need a hosted service that owns all operations for you
- your work requires long exploratory research before a bounded code task
  exists
- your organization cannot run persistent workers, databases, and clone
  storage

Those are valid constraints. Syrus is intentionally aimed at teams that
want a self-hosted harness around agentic PR work, not a general-purpose
assistant for every engineering conversation.

## How To Evaluate It

Start with one boring change. Ask Syrus to add a small docs paragraph,
fix a tiny bug, or update a low-risk test fixture. Watch whether the
Job, Workflow, transcript, diff, and PR make the work easier to trust than
a one-off agent session.

Then test the team loops: leave review feedback, retry a failed run, or
schedule a maintenance task. Syrus earns its keep when those follow-up
paths use the same visible machinery as the first draft.

Next: [Run Syrus locally](/docs/deployment/docker-compose), or read [What is Syrus?](/what-is-syrus)
for the product model.
