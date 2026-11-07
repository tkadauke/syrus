---
id: ADR-0014
title: Use adapter-specific schema authority
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0014: Use adapter-specific schema authority

## Context

Syrus uses SQLite for local development and tests and MySQL in production.
Loading a Ruby schema captured from SQLite into MySQL can import unsupported or
misleading adapter semantics. Removing the dump would make local and test setup
slower and less deterministic.

## Decision

Production MySQL schema authority is the ordered migration history. The Ruby
schema dump represents SQLite local/test state and must not initialize MySQL.
Schema-changing work still updates the dump for its SQLite consumers.

## Consequences

Migration compatibility must be validated independently from the SQLite dump,
and contributors must not infer production guarantees from dump-only details.
The repository keeps fast local setup while paying the cost of cross-adapter
migration checks.

## Evidence

- [Database and migration conventions](../conventions/database-and-migrations.md)
- [MySQL fresh-install compatibility spec](../../../spec/migrations/mysql_fresh_install_compatibility_spec.rb)
- [SQLite schema dump](../../../db/schema.rb)
- [Database technical debt](../../../docs/technical-debt.md)
