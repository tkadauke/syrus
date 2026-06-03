---
title: What is Syrus?
description: The short product explanation: what Syrus does, what it owns, and where it fits.
---

# What is Syrus?

Syrus is a self-hosted automation harness for coding agents. It turns
GitHub issues, PR feedback, scheduled tasks, retries, rebases, and
operator prompts into agent runs, then captures the resulting commits and
opens or updates pull requests.

The agent writes code. Syrus owns the deterministic product work around
that agent run:

- polling GitHub for issues, PR comments, CI failures, and merge state
- creating Jobs, Workflows, Steps, and Runs with auditable state
- preparing repositories before the agent starts
- managing clones, workspaces, branches, commits, pushes, and PRs
- recording transcripts, diffs, summaries, costs, and operator-visible logs
- retrying, rebasing, and responding to follow-up feedback on the same PR

## The 30-second flow

```text
GitHub issue, PR feedback, CI failure, schedule, or direct prompt
  -> Syrus Job
  -> Workflow
  -> prepare Step
  -> agent Step
  -> summary / push / PR Step
  -> GitHub pull request or no-changes result
```

A Job is the thread. A Workflow is one attempt. A Step is one stage. A Run
is one execution attempt for a Step. Those words appear throughout the UI,
API, logs, and docs.

## Where it fits

Syrus is not a hosted coding-agent service. It is an operator-run Rails
application that coordinates existing agent providers, currently Claude
and Codex, against repositories you register.

It is also not a replacement for CI, GitHub, or code review. Syrus creates
and updates PRs; your normal branch protection, review process, test suite,
and merge policy still decide what lands.

## What it is good for

Syrus is useful when you want a durable issue-to-PR loop instead of a
one-off chat session:

- small code changes from labeled issues
- follow-up commits from PR review feedback
- automated attempts to fix failing checks on Syrus-created PRs
- scheduled maintenance prompts
- recurring repository hygiene tasks
- controlled retries and rebases on long-running agent work

Next: [Why use Syrus?](/docs/why-use-syrus) explains the product tradeoffs,
or [Concepts](/docs/concepts) explains the model in more detail.
