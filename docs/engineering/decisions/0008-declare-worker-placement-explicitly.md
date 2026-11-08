---
id: ADR-0008
title: Declare worker placement explicitly
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0008: Declare worker placement explicitly

## Context

Inferring placement from prompt keywords confused incidental platform language
with an execution requirement and could route work to unavailable workers.
Mutable workflow placement and immutable grader-target placement also have
different capability contracts that one prose classifier cannot safely blur.

## Decision

Placement requirements are structured declarations, never inferred from prose.
Jobs and Workflows record their planned project, target, source, and supported
capabilities; target configuration may narrow immutable grader requirements.
Resolvers match those declarations against live worker capabilities or block
with an explicit reason.

## Consequences

Proposal and configuration authors must state required capabilities, even when
the prose appears obvious. Unsupported or unavailable requirements fail closed
instead of being guessed. The additional metadata makes routing deterministic
and auditable.

## Evidence

- [Placement architecture](../architecture/workspace-lifecycle.md)
- [No-text-inference architecture spec](../../../spec/architecture/no_planned_execution_text_inference_spec.rb)
- [`PlannedExecutionRequirement`](../../../app/models/planned_execution_requirement.rb)
- [`RunQueueResolver`](../../../app/services/run_queue_resolver.rb)
