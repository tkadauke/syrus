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

Publishing bytes creates an `unverified` image, not a launch candidate. The
build runner snapshots the verification policy and executes its required
verifiers in order against the immutable digest. Each re-verification creates
a new `RuntimeImageVerificationAttempt`; its ordered check rows retain safe
evidence references and a failure class without replacing prior attempts. An
image becomes `candidate` only when every required check has durable evidence
and passes. Policy or integrity findings reject it, while an unavailable
verifier, registry, or evidence store blocks it. Both outcomes are fail-closed:
the image is not pullable. A newer attempt owns candidate eligibility, so a
slower older attempt cannot overwrite a later decision.

### Isolated builder

`RuntimeImages::Builds::IsolatedBuilder` is the executor registered through
`RuntimeImages::Builds.builder=` once an operator enables the build plane; it
is not registered by default. It drives rootless `buildah` (chroot isolation,
no daemon) as a `ProcessRunner` child, so the worker's Docker socket is never
mounted. The child environment is an allowlist (no inherited variables, empty
registry auth), so no repository, provider, coworker-memory, MCP, runtime-secret,
or deployment-registry credential reaches a build.

The source is unpacked from the request's archive into a private scratch
directory (entry, byte, and symlink checks); the context and Dockerfile paths
are rejected on traversal and re-checked after resolution. Layer storage,
`HOME`, and `TMPDIR` live on a tmpfs sized to `RUNTIME_IMAGE_BUILD_STORAGE_BYTES`,
mounted inside a private unprivileged user+mount namespace (`unshare`), so the
aggregate storage ceiling is enforced by the kernel (ENOSPC) rather than
sampled, and nothing persists between builds or is shared across namespaces
(tmpfs pages are charged to the build's memory cgroup). Ceilings, all environment-overridable:
`RUNTIME_IMAGE_BUILD_CPUS`, `_MEMORY_BYTES`, `_PIDS`, `_STORAGE_BYTES`,
`_TIMEOUT_SECONDS`, `_LOG_BYTES`, `_MAX_OUTPUT_BYTES`,
`_MAX_SOURCE_BYTES`, `_MAX_SOURCE_ENTRIES`; `RUNTIME_IMAGE_BUILD_BINARY` and
`_STORAGE_DRIVER` select the tool and driver. The builder fails closed (`builder_not_isolated`): it refuses to run as root
unless `RUNTIME_IMAGE_BUILD_WORKER_CONFINED=1` attests the worker is itself a
confined sandbox, requires `prlimit` plus a working bounded-tmpfs user namespace (probed before each build), and requires
per-spawn cgroup memory/CPU/PID limits: before each build it checks that they can be applied (the `per_spawn_resource_limits`
feature on, cgroup v2 with delegated memory and pids controllers) and refuses the build otherwise, and afterwards it rejects a
command whose limits were not actually applied (override both only with `RUNTIME_IMAGE_BUILD_CGROUP_OPTIONAL=1`). With
`per_spawn_resource_limits` off, which is its default, no build runs. Build and push run as one command under
`prlimit` (process count, largest file, CPU seconds); the host-side source and
output archive are re-checked after the command. Accepted recipe keys are
`dockerfile`, `context`, `target`, and `build_args`.

### Build network allowlists

A build has no network of its own. It runs in an empty network namespace
(`unshare --net`: loopback only, probed before every build) whose single route
out is `bin/runtime-image-build-relay`, a loopback listener bridging to the
enforcing proxy (`RuntimeImages::BuildNetwork::Proxy`) over a per-build Unix
socket. The proxy settings (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, empty
`NO_PROXY`) are set in the build environment; a recipe may not set `network`,
`network_mode`, `add_host`, `dns*`, or `proxy`, nor a proxy build arg
(`network_mode_forbidden`). Host and shared network modes therefore do not
exist for a build, and a Dockerfile `RUN --network=host` only reaches the
build's own empty namespace.

Administrators declare destinations as `RuntimeImageBuildNetworkRule` rows,
managed through `/api/v1/admin/runtime_image_build_network_rules`. Each rule has
a source class, a DNS host, and a port (default 443); nothing is reachable
without a matching enabled rule, so an empty allowlist denies all egress.

| Source class | Meaning |
| --- | --- |
| `os_mirror` | Distribution package mirror (ecosystem such as `debian`, `alpine`). |
| `language_registry` | Package registry; ecosystem is one of `npm pypi rubygems cargo go maven nuget hex packagist`. |
| `source_host` | Source code host (e.g. `github.com`). |
| `artifact_registry` | Container or artifact registry (e.g. `ghcr.io`). |
| `exact_domain` | Any other single host. |
| `repository_namespace` | A path prefix (`/acme/`) on a host. Enforced only on plain-HTTP requests, where the path is visible; a CONNECT tunnel hides it, so a namespace rule never admits a tunnel (`path_not_inspectable`). |
| `internal_mirror` | An internal mirror. The only class that may resolve into private address space. `required` displaces the public `os_mirror` and `language_registry` rules of its ecosystem (all of them when it names none), so those builds must use the mirror (`internal_mirror_required`). |

Enforcement, all in the proxy and resolver:

- Hosts must be DNS names. Literal IPs in any notation (dotted, decimal, hex,
  octal, IPv6) are denied (`literal_ip_forbidden`).
- The host is resolved once per connection and the proxy dials the validated
  address, never the name, so a name cannot rebind between check and connect.
  One forbidden answer among several fails the lookup.
- Loopback, link-local, cloud metadata (169.254.169.254, 100.100.100.200,
  fd00:ec2::254), unspecified, multicast, and reserved ranges are never
  reachable, not even for an internal mirror. IPv4-mapped and NAT64 addresses
  are judged by the IPv4 address they embed. RFC 1918, CGNAT, and ULA space is
  reachable only through an `internal_mirror` rule.
- Only `CONNECT host:port` and absolute-form `http://` requests are accepted;
  the proxy rewrites `Host`, strips proxy and hop-by-hop headers, and refuses
  chunked request bodies and malformed heads.
- The proxy never follows redirects. A 3xx whose `Location` is not allowlisted
  becomes a 403 (`redirect_not_allowlisted`); a client following an allowed
  redirect comes back through the proxy and is decided again.
- Well-known public registries that no rule declares are denied as
  `undeclared_package_registry`.

Rules are snapshotted when a build starts, so an edit applies to the next build.
Each build records a `build.network` audit event (allowed and denied counts, the
first denied destinations, and the policy digest) and the policy digest in the
image provenance. The worker needs `unshare`, `ip` (iproute2), `ruby`, and
`prlimit`.

## Build evidence

`Builds::Runner` creates an `Evidence` collector per attempt and hands it to the
builder through `Control#evidence`. The builder fills it as facts become known
(log via `LogCapture`, network summary and policy snapshot, base images parsed
from the Dockerfile and resolved with `buildah images --json --digests`, builder
version, cgroup measurements from the `SpawnedProcess`), including on a path
that later fails. In `ensure`, `EvidenceRecorder` writes one
`RuntimeImageBuildEvidence` per terminal attempt, copies the safe summary into
the result's `details`, and audits `build.evidence`. Recording is observational:
a failure to record is logged and never changes the build's outcome.

`ScopedPublisher` is the only registry authority a build has: publish and
inspect inside the request's namespace, nothing else.


## Build recovery and diagnostics

`RuntimeImageBuildDispatchJob` runs `Orchestrator#recover` before admitting
work. Recovery is idempotent and every write takes the request's row lock, so a
cancel, a late worker callback, and the reaper can race without disagreeing:

| Situation | Handling |
| --- | --- |
| Worker lost (no heartbeat) | Attempt fails `lease_expired`, retryable; request re-queues with backoff. |
| Attempt outlives `RUNTIME_IMAGE_BUILD_MAX_ATTEMPT_SECONDS` (default build timeout + 900) even with fresh heartbeats | Attempt fails `attempt_deadline_exceeded`, retryable. |
| Request in building/verifying with no active attempt, or queued with an unfinished cancel | `reap_orphans` re-queues it, fails it as `orphaned_request` when attempts are used up, or completes the cancel; audited as `build.recovered`. |
| Cancel | Queued requests cancel at once; in-flight ones are flagged, then cancel when the builder observes it, the attempt fails, or the lease expires. |
| Quota exhaustion (registry quota/429, `ENOSPC`/`EDQUOT`) | `quota_exhausted`, retryable on a slow backoff (base 10 min). |
| Registry unavailable | `registry_unavailable`, retryable on a 2 min base backoff. |
| Build failed after the egress proxy refused destinations | `network_denied`, terminal: retrying cannot help until an administrator changes the allowlist. The message carries only counts and reasons; hosts stay in the restricted evidence. |
| Duplicate submit | Returns the live request (or the existing pullable image); counted as `duplicate_submit`. |
| Duplicate job delivery | `begin_execution` sets `execution_started_at` once under the lock; later deliveries do nothing (`duplicate_delivery`). |

Diagnostics:

- `GET /api/v1/admin/runtime_images` includes a `builds` section (requests by state, oldest queued age, stale attempts, orphans, 24h outcomes and error codes, denied-destination count, in-flight attempts, recent failures) and the checks `build executor`, `build queue`, `stale build attempts`, `orphaned build requests`, `build failures`, `build network`, `build quota`. `bin/rails runtime_images:status` prints them.
- `GET /api/v1/admin/runtime_image_build_requests[?state=&limit=]` lists requests with their current attempt and result; `POST .../:id/cancel` cancels one. Log text and addresses remain only on `.../:id/evidence`.
- Metrics: `syrus_runtime_image_build_requests{state}`, `syrus_runtime_image_build_oldest_queued_seconds`, `syrus_runtime_image_build_stale_attempts` (sampled), `syrus_runtime_image_build_attempts_total{outcome,reason}` and `syrus_runtime_image_build_recoveries_total{reason}` (counters). Alerts: `SyrusRuntimeImageBuildStaleAttempts`, `SyrusRuntimeImageBuildQueueStalled`.
- Tunables: `RUNTIME_IMAGE_BUILD_MAX_ATTEMPT_SECONDS`, `_STUCK_QUEUE_SECONDS` (default 900), `_STALE_LEASE_GRACE_SECONDS` (default 300).

Queue partitioning: the dispatcher and recovery live on `control_plane` (home
worker); builds run on `runtime_image_builds`, a dedicated pool on Linux compute
workers only (`RUNTIME_IMAGE_BUILD_THREADS`), so a saturated build pool cannot
starve recovery. `spec/config/queue_partitioning_spec.rb` pins this.

Negative fixtures proving the isolation contract live in
`spec/services/runtime_images/build_network/negative_fixtures_spec.rb`
(metadata, loopback, application-network, lookalike, and rebinding
destinations) and the "negative security fixtures" group of
`spec/services/runtime_images/builds/isolated_builder_spec.rb` (no ambient
credentials, sockets, host mounts, or non-isolated network flags reach a build).
