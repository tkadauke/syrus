---
id: ADR-0012
title: Separate operational diagnosis from repair
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0012: Separate operational diagnosis from repair

## Context

Diagnosing stuck work requires broad observation, but observation should not
silently change the state being investigated. Combining explanation and repair
also makes an operator unable to review evidence or choose among recovery
actions before mutation.

## Decision

Operational explanation is read-only and returns evidence-rich current state.
Repair is a separate, explicit action with its own authorization and
confirmation boundary. A diagnostic tool may recommend an action but must not
perform it as a side effect.

## Consequences

Recovery takes a deliberate second action, trading speed for reviewability and
safer automation. New operational tools must classify themselves as observation
or mutation and keep those interfaces distinct.

## Evidence

- [Administrative recovery documentation](../../../config/syrus_docs/admin_recovery.md)
- [Production debugging guide](../operations/production-debugging.md)
- [Workflow recovery guide](../operations/workflow-recovery.md)
- [Operational MCP tool implementations](../../../app/services/mcp/tools)
