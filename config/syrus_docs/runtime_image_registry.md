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
- `runtime_image_verification_evidence_retention_days` controls exact scanner and policy reports (0 keeps them forever). Safe summaries, digests, attestations, and revocation history remain after exact evidence is purged.
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

## Build provenance and evidence

Every build attempt that finishes records evidence bound to its outcome: the captured source digest, the Dockerfile's base images (with the digest each resolved to, or the digest pinned in the reference), a snapshot of the build-network rules and their digest, the builder version, the destinations the build actually reached (host, port, resolved address, source class), the published image's layer digests, measured resource usage (peak memory, CPU time, duration, scratch storage, output size, OOM kills) next to the limits it ran under, and the attempt's terminal result.

- The build log is sanitized line by line before it is stored (credential-shaped values, authorization headers, URL passwords, tokens, and private key blocks are replaced; control sequences are removed) and is capped at the configured log limit. Output past the cap is counted, not stored.
- Administrators read the full evidence, including the log and resolved destinations, at `GET /api/v1/admin/runtime_image_build_requests/:id/evidence`. Other surfaces only receive the safe summary: digests, counts, and measurements, with no log text or addresses. The summary is stored in the build result's details and emitted as a `build.evidence` audit event.
- The image provenance carries the builder version, network policy digest, base images, and layer digests, never log text.
- A build can publish only into the namespace its request was made for, and only through the Runtime Image Service; it holds no registry credential and cannot revoke, delete, or read other images.

Before an extension image becomes a candidate, Syrus verifies that its recorded build ancestry contains the approved digest-pinned base, its OCI platform and non-root user match the supported contract, and its signed runtime ABI remains compatible. It then exercises every provider binary and the confinement handshake in a read-only, capability-free container. The source-defined smoke test runs separately with no secrets or publication credentials, no network, bounded CPU, memory, processes, output, and time, and only the standard ephemeral writable paths. Each assertion is retained as digest-bound verification evidence; missing evidence, an unavailable probe, or any failed required assertion prevents candidate status.

Every candidate also receives a CycloneDX SBOM and a package-and-layer vulnerability scan. The default policy blocks every Critical or High vulnerability and every package named by the instance's prohibited-package policy. Time-bounded exemptions must identify one vulnerability or package, include a reason and expiry, and are copied into the immutable decision evidence. Syrus retains the exact SBOM and scan report with their hashes, scanner version, vulnerability-database version, finding summary, and effective exemptions. An unavailable scanner, missing database identity, or missing evidence blocks candidate status; a later policy change is evaluated by a new attempt so earlier evidence remains reproducible.

An accepted attempt produces an expiring attestation digest bound to the immutable image digest, policy digest, and complete evidence-reference digest. Syrus periodically re-evaluates stored available images when that attestation expires or the effective policy changes; a vulnerability-database refresh can trigger the same path immediately. Any newly blocking result makes the image ineligible for pulls. A newly blocking High or Critical vulnerability also creates a revocation candidate containing only its safe severity summary; other policy findings do not receive a fabricated vulnerability severity. Exact vulnerability identifiers, secret locations, and remediation output remain available only from the administrator evidence endpoint.

Isolated build candidates also pass a policy replay over the captured source, image layers, untruncated image history, OCI metadata, and the sanitized bounded build log. Any detected secret blocks the candidate. The recorded destinations are checked again against the exact administrator allowlist snapshot used by the build, and the image must remain within configured byte and layer ceilings, use the required non-root identity and startup contract, and request no forbidden capabilities. Normal views contain only finding counts and policy codes. Exact secret locations and scanner output are retained as hash-bound restricted evidence and returned only from the administrator evidence endpoint.

Set `SYRUS_RUNTIME_IMAGE_VERIFICATION_POLICY` to a JSON object to configure `vulnerabilities.blocked_severities`, `prohibited_packages`, `exemptions`, `evidence_ttl_seconds`, or the `image` byte, layer, identity, startup, and forbidden-capability policy instance-wide. Other keys are ignored so configuration cannot remove required checks. Each exemption has `kind` (`vulnerability` or `package`), exact `id`, non-empty `reason`, and ISO 8601 `expires_at`; expired or malformed entries have no effect.

## Build recovery and diagnostics

Runtime image builds recover on their own from the failures a long-running build plane sees:

- **Lost workers and stale attempts:** an attempt whose worker stops reporting, or that runs past `RUNTIME_IMAGE_BUILD_MAX_ATTEMPT_SECONDS`, is failed and retried with backoff. Requests left in flight with no active attempt are repaired.
- **Cancellation:** queued builds cancel immediately; running builds stop at the next safe point. Administrators cancel with `POST /api/v1/admin/runtime_image_build_requests/:id/cancel`.
- **Quota and registry trouble:** quota exhaustion (`quota_exhausted`) and an unreachable registry (`registry_unavailable`) are retried on a slower backoff than ordinary failures.
- **Denied network destinations:** a build that fails after the egress proxy refused destinations ends as `network_denied` without retrying; review the build-network allowlist.
- **Duplicates:** identical requests share one live build, and a build job delivered twice runs once.

Diagnostics: `GET /api/v1/admin/runtime_images` includes a `builds` section and build health checks; `GET /api/v1/admin/runtime_image_build_requests` lists requests, attempts, and results. Metrics `syrus_runtime_image_build_requests`, `syrus_runtime_image_build_oldest_queued_seconds`, `syrus_runtime_image_build_stale_attempts`, `syrus_runtime_image_build_attempts_total`, and `syrus_runtime_image_build_recoveries_total` back the stale-attempt and stalled-queue alerts. Builds run on the `runtime_image_builds` queue of Linux compute workers, separate from the control plane that recovers them.

## Coworker base lifecycle

The standard coworker base moves candidate → active → retired (kept pullable 90 days for rollback), or → revoked (terminal). One base is active per platform. Admin endpoints under `/api/v1/admin/coworker_base_releases`:

- `GET` lists releases, per-platform launch state, and environments needing a rebuild.
- `POST /:id/promote` makes a candidate active and retires the previous base.
- `POST /rollback` (`platform`, optional `release_id`) re-activates a retired base; `release_id` must belong to the requested platform (`platform_mismatch` otherwise).
- `POST /:id/support` (`supported_until`, null clears) sets a support deadline; after it passes, environments on that base are reported as needing a rebuild.
- `POST /:id/revoke` (`reason`, `severity` = `standard` or `severe`) withdraws the base. New launches are blocked with `base_revoked`/`no_active_base` until another base is promoted or rolled back to; a severe revocation also revokes every coworker environment built on that base (so those environments stop launching and their running turns are terminated) and terminates turns running on the base itself.

Rebuild discovery lists environments built on a revoked, support-ended, or ABI-incompatible base. A base that is itself out of support is never offered as the replacement; such environments are reported as blocked until a supported base is active. All changes are audited.

## Coworker environment recovery

Publishing a verified coworker environment retains the active image and, by default, the two newest compatible verified rollback images. Administrators configure both that count and the repeated startup-failure threshold on **Admin → Retention Settings**. A failure before the agent process starts counts against the exact activation; ordinary provider failures after startup do not.

Once the threshold is reached, the publication authority recorded for the immediately previous compatible activation authorizes an atomic automatic rollback. Revoked, unavailable, expired-evidence, and ABI-incompatible images are never selected. A revoked digest is rejected at new-turn admission. Severe revocation additionally requests immediate termination of every live agent process whose recorded runtime-image digest matches the affected image. Launch registration shares the revocation boundary, so a racing launch is either included in that request or refused before spawning. Worker capability diagnostics report registry-access evidence, cache integrity, base ABI compatibility, confinement, the configured `/scratch` profile, and termination support. Rollback and termination are audited; recovery guidance directs operators to promote or roll back to a compatible non-revoked image before retrying the turn.
