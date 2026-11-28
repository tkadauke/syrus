---
title: Deployment
description: Ways to run Syrus — pick the smallest path that gives you the full loop you need.
---

# Deployment

Syrus has one recommended local app path and a few more specialized
paths. Start with the prebuilt Docker Compose install; move down the
list only when you need source changes, custom packages, or cluster
operations.

| Path | Audience | Setup time | Use case |
| --- | --- | --- | --- |
| **1. Download the macOS app** | Mac users who want zero terminal | ~2min + image download | [Desktop app](/docs/desktop): DMG install, guided backend setup, web UI in a native window, menu-bar inbox, auto-updates. |
| **2. Run the app locally** | Developers / small teams | ~5min | `install.sh --docker` pulls the prebuilt Docker Compose image. Full web + worker + SQLite + GitHub PR loop. |
| **3. Build or customize the local image** | Operators changing Syrus or adding OS packages | 20-40min first build | `bin/compose-up` builds from the checkout and applies `EXTRA_APT_PACKAGES` / `Dockerfile.local`. |
| **4. Develop Syrus from source** | Syrus contributors | Toolchain-dependent | `install.sh --bare-metal`, `bin/setup`, and `bin/dev` for fast reloads. |
| **5. Deploy to a cluster** | Teams running real infra | Infrastructure-dependent | Kubernetes/k3s hard mode. The public Helm/chart path is still not a complete artifact. |
| **6. Add native Mac workers** | Teams with Xcode workloads | Host-dependent | [macOS workers](/docs/deployment/macos-workers) run outside Kubernetes, consume capability-matched queues, and update themselves by polling for releases. Use the [iOS Compute Runbook](/docs/ios-compute-runbook) for Job planning and grader placement. |

## Decision tree

- **On a Mac and want the easiest start?** [Download the desktop app](/docs/desktop).
- **Running Syrus for yourself or a small team?** Use [Docker Compose](/docs/deployment/docker-compose).
- **Need system packages or source changes in the image?** Use the source/custom build path in [Docker Compose](/docs/deployment/docker-compose#build-or-customize-the-image).
- **Working on Syrus itself?** Use the bare-metal source path in the project README.
- **Production at scale?** Read [Kubernetes](/docs/deployment/kubernetes), including the current packaging status.
- **Need Xcode or iOS simulators?** Add [macOS workers](/docs/deployment/macos-workers) as an external compute pool, then follow the [iOS Compute Runbook](/docs/ios-compute-runbook).

## Run Locally

[Docker Compose](/docs/deployment/docker-compose) runs the real Syrus app
on one machine. The default command pulls the prebuilt
`ghcr.io/tkadauke/syrus-backend` image, generates local secrets, starts web
and worker containers, and stores the SQLite databases plus workflow
workspaces in one named Docker volume.

## Docker Compose

[Docker Compose](/docs/deployment/docker-compose) is the recommended
self-host path for developers and small teams. It runs the Rails web app,
the Solid Queue worker, and SQLite together, then lets you add a GitHub
repository, label an issue, and watch Syrus open a pull request.

If you are a Ruby developer with the toolchain already installed, you
can also run from source with `git clone`, `bundle install`, and
`bin/dev`. Docker Compose is still the recommended path for most users
because it owns the answers to "what else should I install?"

## Kubernetes

[Kubernetes](/docs/deployment/kubernetes) is for teams that already have
ingress, persistent storage, secrets management, backups, and operational
monitoring. It is the hard-mode path; use it when you need cluster-native
operations, not because it looks more official.

## Runtime image build evidence

Each runtime image build attempt records provenance evidence: source digest, resolved base image digests (including `ARG`-parameterized `FROM` lines), the build-network policy digest, builder version, reached destinations, layer digests, measured resource usage, and the terminal result. Build logs are sanitized and size-bounded before storage; output past the cap is counted, not kept. Administrators can read the full evidence at `GET /api/v1/admin/runtime_image_build_requests/:id/evidence`; other surfaces only see a safe summary without log text or addresses.

Before an image becomes a candidate, Syrus retains a digest-bound CycloneDX SBOM and package-and-layer vulnerability report. The default policy rejects Critical and High vulnerabilities plus configured prohibited packages; scanner or database unavailability blocks verification. Configure instance-wide severities, prohibited package names, and exact reasoned time-bounded exemptions with the JSON `SYRUS_RUNTIME_IMAGE_VERIFICATION_POLICY` setting. The scanner version, database version, effective exemptions, report hashes, and decision evidence remain attached to the verification attempt.

For isolated builds, candidate verification also scans the captured source, image layers, complete image history, OCI metadata, and bounded sanitized build log for secrets; replays recorded destinations against the build's administrator allowlist snapshot; and enforces image byte, layer, non-root identity, startup, and forbidden-capability limits. Ordinary views expose only safe counts and policy codes. Exact secret locations and scanner output remain hash-bound restricted evidence for authorized administrator remediation.

## Runtime image build recovery

Builds retry after a lost worker, an attempt that runs too long, registry unavailability, or quota exhaustion (with slower backoff for the last two), and stop without retrying when a build failed on destinations the allowlist refused (`network_denied`). Identical requests share one live build, and administrators can cancel a build or list requests and attempts through `/api/v1/admin/runtime_image_build_requests`. `GET /api/v1/admin/runtime_images` reports build queue age, stale attempts, failure codes, and denied-destination counts, and Prometheus alerts fire on stuck attempts and a stalled queue.

## Coworker base promotion, rollback, and revocation

A published, conformance-verified coworker base starts as a candidate. Administrators promote it to be the active base for its platform (one active base per platform), which retires the previous base and keeps it pullable for 90 days so it can be rolled back to. Use `POST /api/v1/admin/coworker_base_releases/:id/promote`, `POST .../rollback` (`platform`, optional `release_id` of a retired base for that platform), `POST .../:id/support` (`supported_until`, or null to clear), and `POST .../:id/revoke` (`reason`, `severity` of `standard` or `severe`). `GET /api/v1/admin/coworker_base_releases` lists releases, each platform's launch state, and the environments that need a rebuild.

Published coworker-specific environments keep the active image plus two verified rollback images by default. Admin Retention Settings controls that count and the repeated startup-failure threshold. Reaching the threshold atomically returns to the immediately previous compatible verified digest under its recorded publication authority. Revoked digests cannot start new turns; severe revocation also terminates live turns pinned to that digest.

At the start of each coworker turn, Syrus records one immutable execution-image digest together with the active revision, runtime ABI, feature-gate value, and revocation state. That digest remains pinned for the turn even if an administrator publishes or activates a replacement concurrently. When the `coworker_custom_environments` Labs flag is disabled, new turns use the active standard Syrus base without deleting or changing the coworker's custom environment; re-enabling the flag makes a compatible active custom revision eligible again. If the selected base or custom image is unavailable, revoked, expired, or ABI-incompatible, the turn is blocked instead of silently falling back to another image.

Images extending that base must pass candidate verification before publication. Syrus checks their pinned-base ancestry, OCI platform and non-root identity, signed runtime ABI, every bundled provider probe, and the read-only confinement contract. It runs the environment's smoke test without secrets, publication credentials, or network access and with strict CPU, memory, process, output, and time limits. Verification fails closed when a required probe or its durable evidence is unavailable.

The default coworker-environment template installs its seeded smoke test on the candidate image's executable path. Custom templates must likewise ensure that the command named by `smoke_test` is available inside the image when the normal workspace mount is present.

Revoking a base withdraws its image and blocks new launches from it; if it was active, launches stay blocked (no silent fallback to another image) until another candidate is promoted or a retired base is rolled back to. A severe revocation immediately requests termination on every worker for executions pinned to the digest, and severely revokes every coworker environment built on that base, which stops their launches and terminates their running turns. Launch registration shares the revocation boundary, so a racing launch is either included in that request or refused before spawning. Worker health reports registry-access evidence, cache integrity, base ABI compatibility, confinement, `/scratch` profile, and termination support. After any base change, environments built on a revoked, out-of-support, or ABI-incompatible base are reported as needing a rebuild; a superseded but still supported base is not. Every change is audited with the acting administrator, and recovery guidance points operators to a compatible promotion or rollback.
