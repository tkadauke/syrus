---
id: ADR-0004
title: Prefer GitHub App identity while retaining PAT compatibility
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0004: Prefer GitHub App identity while retaining PAT compatibility

## Context

Using an operator's personal token for every action obscures automated
attribution and makes self-review and approval boundaries ambiguous. Requiring
an App exclusively would strand repositories whose installation or permissions
are incomplete and would remove a useful compatibility path.

## Decision

Syrus supports both credential modes and prefers an active GitHub App identity
for bot-authored pull-request work. The Job captures its credential mode at
creation so an attempt does not silently change identity; PAT remains the
supported compatibility mode.

## Consequences

GitHub calls must honor the captured mode and surface App installation failures
instead of silently impersonating a user. Operators retain a PAT path, while
App-backed work has distinct attribution and can evolve narrower permissions.

## Evidence

- [GitHub App design issue](https://github.com/tkadauke/syrus/issues/211)
- [`Job` credential selection](../../../app/models/job.rb)
- [GitHub App credential migration](../../../db/migrate/20260511140000_add_github_app_credentials_to_app_settings.rb)
- [GitHub App request specs](../../../spec/requests/admin/github_app_spec.rb)
