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
