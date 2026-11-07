---
id: ADR-0001
title: Poll GitHub instead of receiving inbound webhooks
status: retired
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0001: Poll GitHub instead of receiving inbound webhooks

## Retirement

This record was retired after a broader evidence review found current polling
behavior but not enough evidence of accepted alternatives and rationale to
classify that behavior as a durable decision. Polling-driven ingestion remains
current architecture; retiring this ADR does not remove that behavior or make
webhooks current. The record remains here to preserve its allocated identifier
and the history of the earlier classification.

## Context

Syrus must discover issues, pull-request feedback, and merge-state changes while
remaining deployable without a publicly reachable callback endpoint. Polling
also gives the application explicit control over rate-limit handling,
deduplication, retries, pause behavior, and per-repository serialization.

## Decision

GitHub work is discovered by recurring polling jobs. Syrus does not expose an
inbound GitHub webhook endpoint. Repository polling fans out onto the polling
queue and serializes work per repository; other pollers cover pull requests and
merge state.

## Consequences

New GitHub-driven behavior must fit the polling model and tolerate discovery
latency. Pollers must be idempotent, respect credentials and rate limits, and
avoid overlapping work. Deployments do not need a public GitHub callback
surface, but they must run the recurring schedule and polling workers reliably.

## Evidence

- [Scheduling and polling architecture](../architecture/scheduling-and-polling.md)
- [`PollAllRepositoriesJob`](../../../app/jobs/poll_all_repositories_job.rb)
- [`PollRepositoryJob`](../../../app/jobs/poll_repository_job.rb)
- [GitHub App request specs](../../../spec/requests/admin/github_app_spec.rb)
- [Recurring polling schedule](../../../config/recurring.yml)
