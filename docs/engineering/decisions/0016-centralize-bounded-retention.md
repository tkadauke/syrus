---
id: ADR-0016
title: Centralize bounded retention
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0016: Centralize bounded retention

## Context

Independent deletion jobs make retention policy hard to inventory and can run
unbounded work against operational tables. Archiving a separately queried set
can also diverge from the rows actually deleted. Plugins need retention without
making core depend on their models.

## Decision

Retention definitions live in a central registry with plugin contributions
behind an extension point. Pruning uses bounded, stable primary-key batches.
When enabled, archiving and deletion operate transactionally on the same
selected IDs. Durations and current registry membership remain configurable
inventory rather than architectural decisions.

## Consequences

Retention work has predictable transaction size, shared visibility, and a
single extension mechanism. Specialized data shapes may need registered
executors, but must preserve bounded work and ownership isolation. Archive
failure prevents deletion of that batch.

## Evidence

- [`RetentionPolicyRegistry`](../../../app/models/retention_policy_registry.rb)
- [`RetentionPruner`](../../../app/services/retention_pruner.rb)
- [Pruner transactional specs](../../../spec/services/retention_pruner_spec.rb)
- [Retention operator documentation](../../../config/syrus_docs/app_settings.md)
