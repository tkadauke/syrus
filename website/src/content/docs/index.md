---
title: Syrus Docs
description: Start here for Syrus product docs, setup paths, operations, and troubleshooting.
---

# Syrus Docs

Syrus is a self-hosted automation harness for the issue-to-PR loop. It
polls GitHub, creates Jobs from issues, feedback, scheduled tasks, and
operator prompts, runs a configured coding agent in an isolated workflow
workspace, captures the diff and transcript, then opens or updates the
pull request.

Use these docs as the public product manual. They explain the product
shape, the first successful run, the core concepts, and the operational
recipes needed to run Syrus without reading the Rails source.

## Start Here

| Goal | Page |
| --- | --- |
| Understand the product in a few minutes | [What is Syrus?](/docs/what-is-syrus) |
| Decide whether Syrus is the right fit | [Why use Syrus?](/docs/why-use-syrus) |
| Get to a first successful PR | [Getting Started](/docs/getting-started) |
| Choose a deployment path | [Deployment](/docs/deployment) |

## Use Syrus

- [Concepts](/docs/concepts): Epics, Jobs, Workflows, Steps, Runs,
  trigger kinds, and state machines.
- [Workflows](/docs/workflows): the built-in pipelines for issues, PR
  feedback, CI failures, retries, rebases, direct Jobs, and landing.
- [Landing Code](/docs/landing): approved Jobs, Epic merge trains, bundles,
  final graders, branch repair, and queue blockers.
- [Tests and Graders](/docs/tests-and-graders): review/landing/CI phases,
  JUnit output, inherited failures, test insights, coverage, and wrapper
  scripts.
- [Previews and Visual Review](/docs/previews): preview boot commands, seed
  data, logs, visual review verdicts, and reliable development-mode previews.
- [Collaboration](/docs/collaboration): solo, shared-repository team,
  fork-based team, and open source contributor modes; review policies;
  feedback policies.
- [Features](/docs/features): broad feature reference for Jobs, Epics,
  schedules, chats, direct Jobs, credentials, and automation surfaces.

## Configure Syrus

- [Configuration](/docs/configuration): `.syrus.yml`, user settings,
  repository settings, credentials, and worker environment.
- [Plugins](/docs/plugins): installed vs enabled plugins, UI contributions,
  MCP tools, plugin data, dependencies, and authoring guidelines.
- [Syrus CLI](/docs/cli): terminal chat, inbox review, checkout,
  test-plan, Job, Epic, repository, and schedule commands.

## Operating Syrus

For local exploration and the first real issue-to-PR loop, use
[Docker Compose](/docs/deployment/docker-compose). For team
infrastructure, read
[Kubernetes](/docs/deployment/kubernetes) before deciding whether cluster
operations are worth the extra moving parts.

The important operational model is simple: the database is the source of
truth, the worker owns long-running agent and Git operations, and
`$SYRUS_DATA_ROOT` stores clone caches plus workflow workspaces. In
multi-worker deployments, Syrus records a durable storage identity for each
data root and routes failed-step resumes back to a worker that advertises the
matching queue, so pod or container names can change across deploys without
breaking workspace-affinity retries.

- [Scheduling and Recovery](/docs/scheduling-and-recovery): Work Intents,
  Work Units, admission control, pauses, preemption, retries, and the
  reconciler.
- [Observability](/docs/observability): performance traces, SQL explains,
  operational logs, browser errors, backend exceptions, activity logs, and
  live MySQL diagnostics.
- [Recipes](/docs/recipes): common how-tos for CI failures, PR feedback,
  scheduled tasks, custom workflows, direct Jobs, and stopping work.
- [Troubleshooting](/docs/troubleshooting): failure modes and concrete
  debug paths.
