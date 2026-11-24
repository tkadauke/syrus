# Runtime image registry

The Runtime Image Service stores images in one operator-provided OCI registry
(an external dependency, like MySQL). Core registers the `oci_registry`
provider when `SYRUS_RUNTIME_IMAGE_REGISTRY_URL` is set.

## Configuration

| Variable (prefix `SYRUS_RUNTIME_IMAGE_REGISTRY_`) | Purpose |
|---|---|
| `URL` | Registry base URL. Use https; no embedded credentials. |
| `REPOSITORY_PREFIX` | Top-level path for everything Syrus owns (default `syrus`). |
| `BUILDER_USERNAME` / `BUILDER_PASSWORD` | Pull + push; used only when publishing. |
| `WORKER_USERNAME` / `WORKER_PASSWORD` | Pull only; used for resolve, inspect, and pull. |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | Pull + delete; used only for revoke and delete. |
| `TIMEOUT` | HTTP timeout in seconds (default 30). |

Use three distinct registry identities. The registry's token service is what
enforces scopes; the provider only requests the actions each role needs.

## Isolation

A namespace maps to exactly one repository,
`<prefix>/<owner_kind>/<namespace name>`, and every token is requested for that
single repository. A locator outside the namespace's repository is refused.

## Digests

Manifest bytes are hashed locally on publish, resolve, and pull; a registry
response that disagrees with the requested or reported digest is an error.
Blob digests are verified before upload.

## Credentials and workloads

Deployment registry variables are stripped from every `ProcessRunner`
environment (including explicit unsets when the environment is inherited).
Workloads that need to pull receive `Provider#worker_pull_grant`, a short-lived
pull-only token for one repository. If the registry cannot mint tokens (for
example basic auth only), the grant raises `Unsupported` rather than exposing
the deployment credential.

## Diagnostics

`bin/rails runtime_images:diagnose` checks reachability, transport security,
credential separation, and for each role whether the registry accepts its token
(tag listing for pull, a cancelled blob upload for builder push; delete is
unverifiable without mutating). Output never includes
secrets and the task exits non-zero on failure.

Revocation and deletion require the registry to allow manifest deletion; a
registry that does not raises `Unsupported`. Retention is tracked in Syrus only.

## Worker image cache

Workers keep pulled images in their local container engine, keyed by immutable digest.

- Pulls are by digest only. After a pull the engine must report the requested digest, otherwise the local copy is removed and the pull fails as corrupt.
- Pull concurrency is bounded per process and concurrent requests for one digest share one pull. A request that cannot get a slot in time fails as busy.
- Images in use are leased and are never evicted. Eviction is least-recently-used; revoked or deleted digests are evicted first and can be purged on demand. Pressure is reported as ok, high (80%), or critical (92%) disk use, and prefetch stands down unless pressure is ok.
- Every lookup or pull records an outcome (hit, pulled, registry_unavailable, timeout, corrupt, revoked, not_found, busy) for hit-ratio reporting. Holding an image is never a worker admission capability.
- A revoked digest is refused without contacting the registry.

## Retention, garbage collection, and reconciliation

Retention is configured on the shared retention page (`runtime_image_retention_days`, 0 = never collect). A namespace may override the window with its own `retention_days`. `RetentionPolicyExecutors::RuntimeImage` runs `RuntimeImages::Collector`, which only considers stored images that are older than their window, have no retention hold (`RuntimeImage#retain!`, including lapsed holds, which are expired first), and are not the newest pullable image of their namespace and platform.

Deletion order is deliberate: revoke is recorded durably first, a worker lease (`RuntimeImageCacheEntry`) defers deletion, the provider delete runs, and only then is the record marked deleted. Deleted records stay as tombstones so a digest can never be republished. Provider failures are stored on the image (`cleanup_failure_count`, `cleanup_last_error`), retried every pass, and stop after `Collector::MAX_CLEANUP_ATTEMPTS`; exhausted images fail the `image cleanup` health check. Workers drop revoked and deleted digests from their local caches through `WorkerCache#purge_revoked` and eviction.

`RuntimeImageReconcileJob` (hourly, `cleanup` queue) runs `RuntimeImages::Reconciler`: stale pending records are resolved against the provider, available records the registry lost are marked deleted, revoked images still stored are revoked again, and digests with no record are reported. Orphan digests are only removed with `bin/rails runtime_images:reconcile DELETE_ORPHANS=1`, because an in-flight publish looks the same as an orphan. Only tagged manifests are enumerable through the OCI tag API.

## Operations

- `bin/rails runtime_images:status` prints health checks and failed cleanup; it exits non-zero on a failing check.
- `bin/rails runtime_images:reconcile [REPAIR=0] [DELETE_ORPHANS=1]` runs a reconciliation pass.
- `GET /api/v1/admin/runtime_images` returns the same checks plus image counts by state, retained rollback images, cache footprint per host, pull outcomes and hit ratio for the last 24 hours, and recent audit events. `POST /api/v1/admin/runtime_images/reconcile` queues a pass.
- Every publish, revoke, retain, delete, collection, retention expiry, reconciliation repair, and authentication failure is a `RuntimeImageAuditEvent` and increments `syrus_runtime_image_operations_total{kind,outcome}`. `Metrics::RuntimeImageSampler` exports `syrus_runtime_images{state}`, `syrus_runtime_image_cache_bytes{state}`, and `syrus_runtime_image_pulls_24h{outcome}`.

## Build orchestration

Build requests (`RuntimeImageBuildRequest`), attempts, and terminal results
are durable. A request captures an immutable source (full commit sha or sha256
digest, never a branch) and a recipe, and is deduplicated on
(namespace, source digest, recipe digest, platform): one live build per tuple,
enforced by a unique index on `active_dedup_key`. States are queued, building,
verifying, succeeded, failed, canceled, rejected.

`RuntimeImageBuildDispatchJob` (recurring, `control_plane`) reaps attempts with
expired leases and claims startable requests within
`RUNTIME_IMAGE_BUILD_CONCURRENCY` (default 2) and
`RUNTIME_IMAGE_BUILD_NAMESPACE_CONCURRENCY` (default 1), then enqueues
`RuntimeImageBuildJob` on the `runtime_image_builds` queue (Linux compute
workers; pool size `RUNTIME_IMAGE_BUILD_THREADS`). Retryable failures back off
and stop after `RUNTIME_IMAGE_BUILD_MAX_ATTEMPTS` (default 3). Nothing is
claimed until an executor is registered via `RuntimeImages::Builds.builder=`,
so the plane is inert by default.
