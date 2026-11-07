# Deployment

## Before deployment

Confirm the revision and target, review migrations and image changes, and run
the narrow checks relevant to the change. Use `bin/deploy` as the repository's
deployment entry point; its Ruby implementation is primary and the shell
implementation is a fallback. Do not reconstruct its sequence manually.

Production image and service definitions live in `Dockerfile`,
`docker-compose.yml`, `config/deploy.yml`, `bin/deploy`, and deployment support
under `lib/`. The operator contract is in
[Deploy](../../../config/syrus_docs/deploy.md). The actual target is configured
per environment; never copy a private hostname into repository documentation.

## Rollout sequence

The deploy command builds or selects the application image, publishes it,
applies required database migrations, updates services, and waits for rollout
health. Database compatibility must span the rollout window: migrations are
idempotent, do not depend on every process switching versions simultaneously,
and avoid unsupported MySQL JSON defaults. Follow
[Database and migration conventions](../conventions/database-and-migrations.md).

Worker and web images must agree on code and schema before new work is allowed
to depend on them. Plugin runtime images and external services have their own
build and health contracts; consult the owning plugin docs instead of adding
plugin-specific procedures here.

## Verification

Verify rollout status, web health, worker heartbeats/capabilities, queue
consumption, and the migration version. Then inspect application logs for boot,
schema, plugin-loading, and queue errors. A successful orchestrator rollout is
not sufficient if workers cannot claim Runs or content/runtime providers are
unavailable.

For a failed rollout, preserve logs and current state before changing anything,
then use [Production debugging](production-debugging.md). Roll back only with a
schema-compatible image; use a forward fix when a destructive migration makes
binary rollback unsafe. See [Release troubleshooting](../../release-troubleshooting.md)
for packaging-specific failures.
