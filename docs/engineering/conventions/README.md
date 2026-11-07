# Conventions

Conventions are mandatory repository-wide implementation, review, migration,
testing, localization, documentation, and plugin-boundary practices. Repository
maintainers own the shared rules; subsystem maintainers own narrower additions.
Prefer executable enforcement when a rule can be checked reliably.

Read the guide that matches the work in front of you:

- [Rails and services](rails-and-services.md) — service boundaries, registries,
  APIs, credentials, and repository integrations.
- [Background jobs and queues](background-jobs-and-queues.md) — queue placement,
  scheduling, concurrency, and process supervision.
- [State machines](state-machines.md) — AASM transitions and lifecycle
  propagation.
- [Database and migrations](database-and-migrations.md) — persistence,
  ownership invariants, migration safety, and backfills.
- [Testing and workspace safety](testing.md) — test seams, diffs, and workspace
  isolation.
- [Frontend](frontend.md) — React routing, interaction patterns, and visual
  consistency.
- [Localization](localization.md) — frontend and backend user-visible copy.
- [Plugins](plugins.md) — lifecycle, registration, boundaries, and plugin-owned
  coverage.
- [Prompts and agent tools](prompts-and-tools.md) — prompt composition, chat
  orientation, and invocation limits.
- [CLI and desktop](cli-and-desktop.md) — Go CLI and Electron application
  conventions.
- [Documentation policy](documentation-policy.md) — public, operator, plugin,
  and repository documentation ownership.
- [Deployment](deployment.md) — single-host Docker distribution and image
  lifecycle.

Executable workflow instructions remain in [`.claude/skills/`](../../../.claude/skills/),
and component-level contracts remain next to their implementations. The legacy
[conventions reference](../../../.claude/reference/conventions.md) is only a
compatibility pointer to this index.

Return to the [engineering documentation index](../README.md).
