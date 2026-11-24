# Runtime image registry

The Runtime Image Service publishes and distributes runtime images (Syrus bases, repository devcontainers, coworker environments) through one operator-provided OCI registry. The registry is an external dependency, like the database. The `oci_registry` provider is enabled when `SYRUS_RUNTIME_IMAGE_REGISTRY_URL` is set.

## Settings

All settings are environment variables on web and worker processes.

| Variable | Purpose |
|---|---|
| `SYRUS_RUNTIME_IMAGE_REGISTRY_URL` | Registry base URL. Use https; embedded credentials are rejected. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_REPOSITORY_PREFIX` | Top-level repository path owned by Syrus (default `syrus`). |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_USERNAME` / `_PASSWORD` | Pull + push identity, used only when publishing. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_WORKER_USERNAME` / `_PASSWORD` | Pull-only identity for resolve, inspect, and pull. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_ADMIN_USERNAME` / `_PASSWORD` | Pull + delete identity, used only for revoke and delete. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_TIMEOUT` | HTTP timeout in seconds (default 30). |

Use three distinct registry identities; the registry's token service enforces the scopes.

## Behavior

- Each namespace (base, repository devcontainer, coworker environment) maps to exactly one registry repository; tokens are requested per repository and role.
- Manifest and blob digests are verified locally; a registry answer that disagrees with the expected digest is an error.
- Deployment registry credentials are removed from every workload environment. Workloads that must pull receive a short-lived pull-only token for a single repository.
- Revocation and deletion need a registry that allows manifest deletion.

## Diagnostics

`bin/rails runtime_images:diagnose` checks reachability, https, credential separation, and each role against the registry itself: a read-only tag listing must be accepted, a builder's push is verified by opening and cancelling a blob upload, and delete is reported as unverified unless the token reports it (a registry that rejects the token fails the role even if the token claims the right access; use an existing repository as the probe if your registry hides unknown names behind a bare 404). Output never includes secrets; the task exits non-zero on failure.

## Worker image cache

Workers keep pulled images in their local container engine, keyed by immutable digest.

- Pulls are by digest only. After a pull the engine must report the requested digest, otherwise the local copy is removed and the pull fails as corrupt.
- Pull concurrency is bounded per process and concurrent requests for one digest share one pull. A request that cannot get a slot in time fails as busy.
- Images in use are leased and are never evicted. Eviction is least-recently-used; revoked or deleted digests are evicted first and can be purged on demand. Pressure is reported as ok, high (80%), or critical (92%) disk use, and prefetch stands down unless pressure is ok.
- Every lookup or pull records an outcome (hit, pulled, registry_unavailable, timeout, corrupt, revoked, not_found, busy) for hit-ratio reporting. Holding an image is never a worker admission capability.
- A revoked digest is refused without contacting the registry.
