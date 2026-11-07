---
id: ADR-0007
title: Separate work admission from workflow execution
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0007: Separate work admission from workflow execution

## Context

Retry, locking, landing, and ownership policy accumulated across dispatch
callers while Workflow, Step, and Run already modeled executable state. Folding
all admission policy into those state machines would mix durable intent and
cross-attempt coordination with one materialized execution attempt.

## Decision

`WorkIntent` records desired work and `WorkUnit` owns an admitted runtime
attempt, its locks, members, and retry policy. `Workflow`, `Step`, and `Run`
continue to own materialized execution. All launch paths enter through
`WorkUnits::Launcher` and then fall through to `StepDispatcher`.

## Consequences

Repairs and new launch paths must establish WorkUnit ownership instead of
creating Workflows directly. Operators gain durable admission and lock state,
at the cost of maintaining linked ownership and execution records. Historical
rollout flags are not part of the current contract.

## Evidence

- [Work-engine architecture](../architecture/domain-model-and-work-engine.md)
- [`WorkUnits::Launcher`](../../../app/services/work_units/launcher.rb)
- [Launch-funnel architecture spec](../../../spec/architecture/workflow_launch_funnel_spec.rb)
- [Workflow execution architecture](../architecture/workflow-execution.md)
