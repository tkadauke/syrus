---
id: ADR-0015
title: Own referential integrity in the application
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0015: Own referential integrity in the application

## Context

Adding or changing database foreign keys on large operational MySQL tables can
require costly, brittle table rewrites and complicate online evolution. Database
constraints would catch some invalid states, but historical declarations and
SQLite behavior do not provide a consistent cross-adapter guarantee.

## Decision

Syrus does not enforce database foreign keys. Associations, validations,
ordered cleanup, reconciliation, and repair paths own referential integrity.
New references explicitly opt out of foreign-key creation.

## Consequences

Schema evolution avoids foreign-key table rewrites, but application deletion
paths and repairs carry more responsibility and require focused tests. A
historical `foreign_key` declaration is not evidence of a current database
guarantee.

## Evidence

- [Foreign-key policy initializer](../../../config/initializers/foreign_keys.rb)
- [MySQL compatibility and no-FK specs](../../../spec/migrations/mysql_fresh_install_compatibility_spec.rb)
- [Database and migration conventions](../conventions/database-and-migrations.md)
- [Database pitfalls](../pitfalls/queues-databases-and-polling.md)
