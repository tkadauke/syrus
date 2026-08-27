---
title: Scheduling and Recovery
description: How Syrus admits work, pauses it, resumes it, retries failures, and repairs stale execution state.
---

# Scheduling and Recovery

Syrus separates the operator-facing Job from the scheduler-owned work needed
to move it forward. This keeps retries, pauses, deploy interruptions, and
preemption visible without turning every internal state into a Job state.

## Work Intents and Work Units

A Work Intent records desired work: implement this Job, land this approved PR,
repair this CI failure, rebase this stack, or run this bundle.

A Work Unit records one attempt to satisfy that intent. It owns or links to
the workflow that is actually executing. A resume or retry-from-failed-step is
a continuation of the same unit when it is safe. A full retry or new landing
attempt is a new unit.

Most users do not need to see Work Intents and Units during normal review. The
admin UI exposes them so operators can debug admission control, dependency
gates, and preemption.

## Admission Control

Admission control decides whether work should start now. It considers current
worker pressure, active high-cost workflows, provider availability, repository
concurrency, and minimum progress floors.

When work cannot safely start, the unit is blocked or paused with a reason and
a next check time. Once resources improve, Syrus should resume the work rather
than leave half-started Jobs behind.

## Pause Reasons

Syrus can pause work for several reasons:

- manual pause by an operator,
- admission-control pressure,
- provider usage or quota limits,
- repository policy such as main-branch health enforcement,
- dependency gates,
- preemption by higher-priority work.

Manual pauses stay paused until an operator unpauses them. Automatic pauses
are reconsidered by the scheduler and reconciler.

## Preemption

Preemption is an intentional interruption. Syrus may stop lower-priority work
when a more important unit needs the same slot or when an epic-wide operation
must prevent conflicting job-level work.

Preempted work should explain what interrupted it and should be resumable or
retryable through the same recovery paths as other non-terminal interruptions.

## Reconciler

The reconciler is the background safety net. It looks for states that should
not persist:

- queued runs with no queue claim,
- workflows with no first run,
- stale running runs after worker death or deploy,
- terminal workflows still attached to active Jobs,
- closed Jobs with active workflows,
- paused work that is now eligible to resume.

The reconciler records what it found and what repair it applied. This is the
best audit trail when something gets unstuck without an operator clicking a
button.

## Retry Semantics

Syrus prefers the smallest safe retry:

- Retry failed step: continue the current attempt when the workspace and
  branch are still trustworthy.
- Resume: continue after a pause or transient failure.
- Retry workflow: start a new workflow for the same desired work.
- Retry implementation: start a new implementation attempt when the previous
  output itself should not be trusted.

Agent-produced commits can be preserved through checkpoint refs, so a later
retry can recover useful work even if the original workspace disappeared.

## Provider Availability

Provider availability is tracked per user/provider/account. Usage-limit
signals can pause matching work, while successful evidence can clear a hard
rate-limit circuit. Low remaining quota is a warning unless it crosses the
configured per-agent threshold.

Operators can recheck usage and, when appropriate, override a provider pause.
Overrides should be used when the account situation changed outside Syrus,
such as buying extra credits or switching credentials.
