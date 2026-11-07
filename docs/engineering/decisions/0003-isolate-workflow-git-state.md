---
id: ADR-0003
title: Isolate mutable Git state by workflow
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0003: Isolate mutable Git state by workflow

## Context

Concurrent agents once shared a clone and its mutable refs. Fetches and branch
updates could then corrupt another execution's view or produce orphaned
histories. Sharing objects or aggressively reusing checkouts reduces transfer
cost, but sharing mutable Git state makes correctness depend on timing.

## Decision

Each Workflow owns an isolated mutable checkout. Immutable source snapshots and
prepared-layer reuse may optimize distributed work, but must not make concurrent
workflows share mutable refs or an actionable working tree.

## Consequences

Workspace creation and cleanup cost more than one shared clone, and caches need
explicit lifecycle rules. In return, fetch, rebase, repair, and push operations
cannot mutate another workflow's Git state. New reuse mechanisms must preserve
that isolation boundary.

## Evidence

- [Original isolation report](https://github.com/tkadauke/syrus/issues/105)
- [Workflow workspace implementation](../../../app/services/workflow_workspace.rb)
- [Workspace lifecycle architecture](../architecture/workspace-lifecycle.md)
- [Workspace isolation specs](../../../spec/services/workflow_workspace_spec.rb)
