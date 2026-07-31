---
title: What is Syrus?
description: A plain-language explanation of Syrus as a self-hosted harness for turning GitHub work into agent-authored pull requests.
---

# What is Syrus?

Syrus is a self-hosted automation harness for agentic coding work. It
turns GitHub issues, PR feedback, scheduled tasks, retries, and rebases
into controlled agent runs, then captures the commits and opens or
updates the pull request.

That means Syrus is not just a chat interface and not just a coding
agent. It is the job-control layer around the agent: the part that
clones the repository, creates the branch, prepares the workspace, runs
the configured provider, records what happened, pushes the commits, and
keeps the pull request tied back to the original request.

## The Short Version

```text
GitHub issue, PR comment, schedule, retry, or rebase
  -> Syrus Job
  -> Workflow
  -> prepared workspace
  -> agent Run
  -> captured diff, transcript, commit, and PR
```

The agent writes code. Syrus owns the deterministic plumbing around that
code: repository setup, state tracking, GitHub coordination, PR updates,
and operational visibility.

## What Syrus Runs

Syrus starts from events your team already uses:

| Source | What Syrus does |
| --- | --- |
| GitHub issue | A trigger label creates a Job and starts the initial issue-to-PR Workflow. |
| PR feedback | New human review comments create a follow-up Workflow on the same branch; failed handling stays visible and retryable without another GitHub comment. |
| Scheduled task | A recurring or one-shot prompt creates a Job without a GitHub issue. |
| Retry | An operator asks Syrus to run another attempt on an existing Job. |
| Rebase | Syrus detects an unmergeable branch it controls and runs a rebase Workflow. |

Those paths share the same vocabulary and audit trail. A **Job** is the
long-lived thread of work. A **Workflow** is one attempt to move that Job
forward. A **Step** is one stage in the Workflow, such as prepare,
implement, summarize, push, or rebase. A **Run** is one execution attempt
for a Step, carrying prompt, transcript, provider metadata, diff, and PR
copy.

For the full mental model, read [Concepts](/docs/concepts).

## What Syrus Does Not Try To Be

Syrus does not replace GitHub, code review, CI, or your deployment
pipeline. It fits between written intent and a pull request that your
normal engineering process can inspect.

Syrus also does not require every team to use the same agent provider or
hosted service. It is designed for BYOK operation: you bring your own
agent credentials and GitHub credentials, and you run the harness in
infrastructure you control.

## What You See As An Operator

Instead of a loose terminal session, Syrus gives each attempt a durable
record:

- the source issue, prompt, PR comment, scheduled task, retry, or rebase
- the Job, Workflow, Step, and Run states
- setup output and agent transcript
- captured diff and head SHA
- commit, push, and pull request result
- operational logs for debugging when a run fails or gets cancelled

That record is the point. Syrus makes agent work repeatable enough that a
team can delegate small GitHub tasks without losing track of what ran,
where it ran, and which PR contains the result.

## Where It Fits

Syrus fits best when your team already uses GitHub issues and pull
requests as the source of engineering work, and wants an agent to handle
bounded implementation tasks inside that process.

It is a good fit for teams that want:

- self-hosted control over credentials and infrastructure
- a multi-user queue instead of one developer's local scripts
- auditable transcripts, diffs, and PR updates
- scheduled maintenance runs that use the same harness as issue work
- follow-up attempts for review feedback, CI failures, retries, and rebases

It is probably not the first tool to pick if you only want an occasional
local pair-programming chat, or if your team does not want GitHub issues
and pull requests to be the coordination layer.

## Next

[Why use Syrus?](/why-use-syrus) explains the value tradeoffs.
[Run Syrus locally](/docs/deployment/docker-compose) is the shortest proof.
[Getting Started](/docs/getting-started) walks through the first real
deployment path.
