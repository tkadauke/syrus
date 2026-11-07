---
id: ADR-0011
title: Centralize permission authority and distinguish harness authorship
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0011: Centralize permission authority and distinguish harness authorship

## Context

Parallel authorization paths drift and can disagree about the same action.
Treating deterministic harness plumbing as agent-authored intent also blocks
required orchestration, while exempting all execution would bypass capability
ceilings and confinement.

## Decision

One canonical permission evaluator authorizes user, operator, and agent
actions. Execution requests classify authorship so deterministic harness work
is not gated as agent intent, while capability ceilings, resource restrictions,
and execution confinement continue to apply at their owning boundaries.

## Consequences

New action surfaces must register with and call the canonical evaluator rather
than inventing local policy. Authorship classification must remain explicit;
it is not a blanket bypass. Centralization makes decisions explainable but
raises the importance of parity and registry coverage tests.

## Evidence

- [Permission authority operator documentation](../../../config/syrus_docs/permission_authority.md)
- [Unified-authority architecture spec](../../../spec/architecture/unified_permission_cutover_spec.rb)
- [Execution-authorship architecture spec](../../../spec/architecture/execution_kind_authorship_spec.rb)
- [Permission diagnostics](../../../config/syrus_docs/permission_shadow_evaluation.md)
