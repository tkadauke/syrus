# Standard coworker base image

The standard Syrus coworker base is one OCI image containing every bundled
agent-provider CLI (`claude`, `codex`, `agy`, `muse`) and the support tools a
coworker turn needs (`git`, `ssh`, `curl`, `jq`, `rg`, `fd`, `node`, `python3`,
`unzip`). Because all providers are present, switching a coworker's provider
never requires rebuilding its environment.

## Definition

| File | Purpose |
|---|---|
| `images/coworker-base/Dockerfile` | The reproducible build definition. |
| `images/coworker-base/base.yml` | The machine-readable contract: generation, runtime ABI, identity, providers, writable paths, publication identity, and the build-network destinations the build needs. |
| `images/coworker-base/syrus-base-probe` | In-image check of identity, provider binaries, tools, baked credentials, and read-only operation. |
| `RuntimeImages::CoworkerBase` | Reads the contract, validates the definition, archives it deterministically, and submits the build. |

Reproducibility: the base is pinned by digest, Debian packages by an immutable
`snapshot.debian.org` date (`DEBIAN_SNAPSHOT`), Node by exact package version
(`NODE_VERSION`), provider CLIs by exact version,
and every downloaded artifact by a checksum verified in the same `RUN`. The
build source is a deterministic archive (sorted entries, fixed mtime and
modes), so identical files always produce the same source digest; the build
plane deduplicates on source, recipe, and platform.

## Identity and filesystem

The image runs as user `coworker` (uid/gid 1000 by default, `COWORKER_UID` and
`COWORKER_GID` build args) and ends in `USER`. It needs no write access to its
own filesystem. The only writable paths are mounts supplied by Container
Execution: `/workspace`, the provider home (`/home/coworker`), and `/tmp`.
The execution envelope (read-only root, dropped capabilities, no-new-privileges,
egress policy) belongs to Container Execution, not the image; image metadata
cannot weaken it.

`CoworkerBase.probe_command(reference)` returns the `docker run` argv that runs
`syrus-base-probe` read-only, as uid 1000, with all capabilities dropped and no
network. The probe fails if the root filesystem is writable, the user is root,
a provider binary does not start, or a credential-shaped variable is baked in.
Beyond those, the full probe verifies the entrypoint, each provider at its
contracted path, `no_new_privs` and an empty capability set, writable
`/workspace`, provider home, and `/tmp`, `/tmp` mounted `nosuid,nodev,noexec`,
and the MCP socket directory and path.

`RuntimeImages::ConformanceProbe` judges the probe's output. The expected check
list is derived from `abi.yml` and `base.yml`, so a check that is missing from
the output fails exactly like one reporting `fail`; a non-zero exit also fails.
`ConformanceProbe.verify_image!(reference, runner:)` runs the confined probe and
raises `NonConformant` on any problem. `CoworkerBase.validate` also statically
checks the probe script emits every expected check, and the conformance spec
requires every bundled `*_agent` provider plugin to appear in `abi.yml`,
`base.yml`, the Dockerfile, and the probe before it can enter the standard base.

The build also runs the probe once (without the confinement checks) as the final
non-root user, so a broken provider binary fails the build.

## Runtime ABI

`images/coworker-base/abi.yml` is the versioned runtime ABI: entrypoint and
handshake (`syrus-base-probe`), provider binary paths and invocation protocol
(exec by absolute path, no shell, cwd `/workspace`), the filesystem layout
(`/workspace`, provider home, bounded `/tmp`, the optional admin-enabled
`/scratch`, and the read-only MCP socket), the MCP transport, the non-root
identity, per-turn environment variables, and the minimum confinement policy.
`RuntimeImages::RuntimeAbi` derives the `io.syrus.runtime-abi.*` OCI labels from
it (the Dockerfile must carry them exactly; `CoworkerBase.validate` checks),
signs the contract into the image's provenance (`runtime_abi_attestation`,
HMAC over the contract digest, version, compatibility range, and minimum
confinement policy, bound to the build's source and recipe digests,
signed by Syrus and never by the keyless builder), and exposes
`validate_for_launch`, which `RuntimeImages::WorkerCache#acquire` runs against
the engine-inspected labels of every standard base image before it returns the
lease (so a launcher never receives an unvalidated one). It refuses (never falling back to host execution) images that are
revoked, outside the compatibility range, missing labels, requiring a newer
confinement policy than the worker enforces, for an unknown provider, or whose
provenance is unsigned or any ABI label disagrees with the signed contract. To change the ABI, bump
`version` in `abi.yml` and `runtime_abi` in `base.yml`, widen or narrow
`compatibility`, update the Dockerfile labels, and a spec fails until they agree.

## Credentials

No provider credential is a build input. The Dockerfile has no credential-named
`ARG`/`ENV`, no secret or ssh mounts, and no auth files;
`CoworkerBase.validate` rejects any of these, and the isolated builder already
gives a build no registry, provider, repository, MCP, or deployment credential.
Provider credentials are injected per turn at runtime and never stored in a
layer.

## Publishing

1. Allow the destinations listed under `build_network` in `base.yml` as
   build-network rules (`/api/v1/admin/runtime_image_build_network_rules`).
   An empty allowlist denies all egress and the build fails `network_denied`.
2. In `bin/rails runner`, call `RuntimeImages::CoworkerBase.validate!` and then
   `RuntimeImages::CoworkerBase.submit(platform: "linux/amd64")` (and
   `linux/arm64`). It returns the build request; follow it under
   `/api/v1/admin/runtime_image_build_requests`.
3. The isolated builder publishes through the Runtime Image Service to the
   `syrus_base / coworker-base` namespace with source ref
   `coworker-base/generation-<generation>`. Consumers resolve it with
   `CoworkerBase.current_image` and run it only by the registry-verified digest.

## Updating

All changes go through a pull request that edits the pins in the Dockerfile and
the matching values in `base.yml`:

- **Provider CLI or tool version**: change the `ARG` (and its checksums). The
  source digest changes, so the next submit is a new build.
- **Base image**: replace the digest in both the Dockerfile default and
  `base.yml`; `validate` fails if they disagree or the reference is a tag.
- **Runtime ABI or generation**: bump `generation`/`runtime_abi` in `base.yml`
  and the matching `io.syrus.coworker-base.*` labels. A new generation is a new
  source ref, so it never reads as a rebuild of the previous one.
- **New provider plugin with a CLI**: add it to `base.yml`, the Dockerfile, and
  the probe; a spec fails until all three agree.

After merging, submit the build for each platform. Previously published digests
stay immutable and available for rollback until retention collects them; a bad
image is withdrawn with the Runtime Image Service's revoke operation (see
[runtime image registry](runtime-image-registry.md)).

## Probe in the build path

`Builds::Runner` runs `ConformanceProbe.verify_published!` on every published
`syrus_base` image after registry inspection. The image is pulled through the
worker cache and probed under the real confinement. A non-conformant image is
revoked (so `CoworkerBase.current_image` never returns it) and the build fails
permanently with `conformance_failed`.
