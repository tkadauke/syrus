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

## Built devcontainers

When the registry is configured, a devcontainer that builds from a Dockerfile is built once per repository revision and devcontainer fingerprint, exported, and published to the repository's own registry repository. Every worker then pulls and runs it by immutable digest, so workers with separate Docker image stores run the same image and no shared Docker daemon is needed. Concurrent Workflows for the same revision wait on one build across the whole fleet.

- Publication needs a container engine that saves images as an OCI layout (current Docker with the containerd image store, or Podman). An engine that cannot is reported as an export failure.
- Devcontainers that name an `image` keep that reference. The digest the engine holds for it is recorded on the Workflow as the `container_execution_image_resolution` artifact.
- Without a configured registry, builds fall back to a tag in the worker's own Docker daemon, as before.

## Retention and cleanup

- `runtime_image_retention_days` on the retention settings page controls how long published images are kept (0 keeps them forever). A namespace can set its own `retention_days`.
- Images under a retention hold (for example a rollback image) are never collected; a lapsed hold is released first. The newest pullable image of each namespace and platform is always kept.
- Collection revokes an image, waits while any worker holds it in use, deletes it from the registry, and only then records it as deleted. Failed cleanup is retried each pass and is reported by `bin/rails runtime_images:status` and `GET /api/v1/admin/runtime_images`.
- An hourly reconciliation compares records with the registry and repairs drift. Unrecorded registry digests are reported and removed only with `bin/rails runtime_images:reconcile DELETE_ORPHANS=1`.
- Pull outcomes, authentication failures, corruption, and lifecycle decisions are kept as audit events and exposed as metrics (`syrus_runtime_image_*`).


## Build-network allowlists

Runtime image builds run with no direct network. All build egress goes through an enforcing proxy and resolver that permits only destinations an administrator has declared.

- Rules are managed at `/api/v1/admin/runtime_image_build_network_rules` (`GET` lists rules, source classes, and language ecosystems; `POST`, `PATCH`, and `DELETE` manage a rule). Edits apply to the next build.
- Each rule has a source class: `os_mirror`, `language_registry` (with an `ecosystem` such as npm or pypi), `source_host`, `artifact_registry`, `exact_domain`, `repository_namespace` (host plus a path prefix), or `internal_mirror`. A rule may set a port, a path prefix, `required`, and `enabled`.
- A required internal mirror displaces the public OS mirrors and language registries of its ecosystem (all of them when it names no ecosystem), so builds must use the mirror. Other ecosystems and source hosts stay allowed.
- Package registries that no rule declares are refused.
- Blocked: literal-IP destinations in any notation, redirects to undeclared hosts, hosts resolving to private, loopback, link-local, or cloud-metadata addresses (or a mix of public and private), DNS rebinding (names are resolved once and dialed by that address), unauthorized `CONNECT`, and host or shared network modes.
- Denied attempts are recorded as `build.network` audit events and the network policy digest is recorded in the image provenance.
