---
id: ADR-0010
title: Record immutable workflow source snapshots
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0010: Record immutable workflow source snapshots

## Context

Distributed graders cannot safely assume access to a worker-local mutable
checkout, and a branch ref can move after scheduling. Transient copies or refs
alone do not provide a durable answer to which source a grader observed.

## Decision

Immutable workflow sources are first-class `WorkflowSourceSnapshot` records.
Distributed work resolves and checks out the recorded source detached from the
live workspace, and reusable preparation layers are keyed by that source and
the relevant preparation and capability inputs.

## Consequences

Every distributed result can be attributed to durable source metadata. Source
changes require a new snapshot, and snapshot checkout and cleanup become
explicit lifecycle responsibilities. Graders must never read later mutable
workspace state as though it belonged to the recorded run.

## Evidence

- [Source snapshot implementation pull request](https://github.com/tkadauke/syrus/pull/3458)
- [`WorkflowSourceSnapshot`](../../../app/models/workflow_source_snapshot.rb)
- [Workspace lifecycle architecture](../architecture/workspace-lifecycle.md)
- [Workflow-step operator documentation](../../../config/syrus_docs/workflow_steps.md)
