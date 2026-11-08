---
id: ADR-0009
title: Extend Syrus through acyclic plugin boundaries
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0009: Extend Syrus through acyclic plugin boundaries

## Context

Optional capabilities embedded in core make removal unsafe and let
feature-specific constants, routes, and registrations leak across subsystem
boundaries. Separate services would increase deployment complexity; unconstrained
Rails engines would still allow core to depend on optional code.

## Decision

Plugins are Rails Engine gems that contribute behavior only through declared
extension points. The dependency graph is acyclic: plugins may depend on core,
but core and unrelated plugins must not reference an optional plugin's source
or constants. Plugin-specific implementation and documentation remain with
their owner.

## Consequences

New extension needs a stable provider contract instead of a direct core
reference. Boundary audits add work but preserve plugin removability and make
ownership discoverable. Shared contracts remain in core; plugin subjects follow
[ADR-0002](0002-keep-plugin-documentation-with-its-plugin.md).

## Evidence

- [Plugin architecture](../architecture/plugins.md)
- [Plugin conventions](../conventions/plugins.md)
- [Source-boundary architecture spec](../../../spec/architecture/plugin_source_boundary_audit_spec.rb)
- [Plugin boundary audit](../../../bin/plugin-boundary-audit)
