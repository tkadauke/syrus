---
id: ADR-0006
title: Persist canonical dependency graphs
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0006: Persist canonical dependency graphs

## Context

Free-form dependency declarations are useful at ingestion but cannot reliably
support cycle checks, operator edits, or different execution and landing
semantics. Re-parsing prose would make a durable scheduling constraint depend
on mutable wording.

## Decision

Persisted dependency rows are canonical. Ingested textual declarations may
seed them, after which cycle-checked rows gate work and remain operator
editable. Execution readiness and landing readiness deliberately evaluate the
graph for their own phase, and explicit satisfaction modes represent whether a
dependency requires success or merely terminal closure.

## Consequences

Callers must query the graph rather than re-parse source text. Importers must
validate and normalize edges, and UI/API changes must preserve cycle and mode
semantics. The extra data model makes graph state inspectable and repairable.

## Evidence

- [Dependency graph design issue](https://github.com/tkadauke/syrus/issues/246)
- [Dependency graph implementation](https://github.com/tkadauke/syrus/pull/248)
- [`JobDependency`](../../../app/models/job_dependency.rb)
- [Landing dependency semantics](../../../config/syrus_docs/landing_queue.md)
