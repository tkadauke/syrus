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
| Evaluate without a long-running install | [Try it locally](/docs/deployment/try-it-locally) |
| Choose a deployment path | [Deployment](/docs/deployment) |

## Product Manual

- [Concepts](/docs/concepts): Epics, Jobs, Workflows, Steps, Runs,
  trigger kinds, and state machines.
- [Features](/docs/features): Jobs, Epics, schedules, chats, direct Jobs,
  credentials, GitHub App/PAT behavior, and multi-user operation.
- [Workflows](/docs/workflows): the built-in pipelines for issues, PR
  feedback, CI failures, retries, rebases, direct Jobs, and local dev.
- [Configuration](/docs/configuration): `.syrus.yml`, user settings,
  repository settings, credentials, and worker environment.
- [Recipes](/docs/recipes): common how-tos for CI failures, PR feedback,
  scheduled tasks, custom workflows, direct Jobs, and stopping work.
- [Troubleshooting](/docs/troubleshooting): failure modes and concrete
  debug paths.

## Operating Syrus

For local exploration, start with [Try it locally](/docs/deployment/try-it-locally).
For a real issue-to-PR loop, use [Docker Compose](/docs/deployment/docker-compose)
once the published packaging is available. For team infrastructure, read
[Kubernetes](/docs/deployment/kubernetes) before deciding whether cluster
operations are worth the extra moving parts.

The important operational model is simple: the database is the source of
truth, the worker owns long-running agent and Git operations, and
`$SYRUS_DATA_ROOT` stores clone caches plus workflow workspaces.
