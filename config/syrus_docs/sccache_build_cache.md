# Shared Compiler Cache (sccache)

Syrus's worker image includes [sccache](https://github.com/mozilla/sccache) as a transparent compiler cache for C/C++ (and other sccache-supported) builds — repos like `tkadauke/raytracer` stop paying full cold-compile cost on every grader iteration. No `.syrus.yml` or `CMakeLists.txt` changes are required.

## How it's wired in

The worker image (`Dockerfile`, `worker-deps` stage) installs the `sccache` binary and symlinks `cc`, `c++`, `gcc`, `g++`, `clang`, and `clang++` to it, ahead of the real toolchain on `PATH`. Build systems that resolve compilers by name off `PATH` — CMake, Make, Meson, Bazel host-toolchain compiles — pick this up automatically; sccache finds the real compiler further down `PATH` and only intercepts the invocation to check/populate the cache.

This masquerade is always present in the worker image. Whether it does anything useful depends on the backend:

- **No `SCCACHE_BUCKET` configured** — sccache falls back to a local per-pod disk cache. Still speeds up same-pod, same-workspace reruns (e.g. iteration 2 of a grade loop rerunning the same command), but gives no cross-pod or cross-Job benefit. This is the safe default before an operator provisions a bucket — nothing hard-fails.
- **`SCCACHE_BUCKET` configured** — sccache reads/writes a shared S3-compatible bucket, giving cross-worker and cross-Job cache hits.

## Operator setup

1. Provision a **new, separate S3-compatible bucket** on the existing self-hosted MinIO instance (see `config/storage.yml`'s `minio` service) — e.g. `syrus-build-cache`. Do **not** reuse the `syrus-attachments` bucket: cache objects are disposable and want an aggressive lifecycle-expiry policy that shouldn't share blast radius or retention rules with operator-uploaded content.
2. Create scoped read/write credentials for that bucket.
3. Set the environment variables below on the worker pod/deployment.

Bucket creation and credential provisioning happen outside Syrus (no cloud/infra access from a grader sandbox) — Syrus only consumes the resulting env vars.

## Environment variables

These are forwarded into `prepare` and `grader` subprocess env by `Steps::Prepare::PREP_ENV_FORWARD` (also used by `Steps::Grader`) — see `.env.example` / `compose.env.example` for the same list with inline descriptions.

| Variable | Required | Meaning |
|---|---|---|
| `SCCACHE_BUCKET` | Operator-provided (optional) | Name of the S3-compatible bucket. Unset = local-disk-only fallback. |
| `SCCACHE_ENDPOINT` | With `SCCACHE_BUCKET` | S3-compatible endpoint URL, e.g. the same MinIO endpoint used for `S3_ENDPOINT`. |
| `SCCACHE_REGION` | With `SCCACHE_BUCKET` | S3 region. Use `auto` for MinIO/most self-hosted S3-compatible backends when `SCCACHE_ENDPOINT` is set. |
| `SCCACHE_S3_KEY_PREFIX` | Optional | Prefix prepended to all cache object keys — useful if the bucket is ever shared with another application. |
| `AWS_ACCESS_KEY_ID` | With `SCCACHE_BUCKET` | Access key for the scoped bucket credentials. Read directly by sccache's S3 backend (standard AWS SDK env var name, not `SCCACHE_`-prefixed). |
| `AWS_SECRET_ACCESS_KEY` | With `SCCACHE_BUCKET` | Secret key for the scoped bucket credentials. |

Verify this list against [sccache's S3 docs](https://github.com/mozilla/sccache/blob/main/docs/S3.md) before changing it — it's the source of truth for what sccache's S3 backend actually reads.

### Deliberately not forwarded: `SCCACHE_BASEDIRS`

sccache supports normalizing away a base directory before hashing (`SCCACHE_BASEDIRS`), which lets a cache hit span builds run from different absolute paths. Syrus does **not** forward this var, and it should stay that way — see the coverage-correctness note below.

## Coverage builds (`gcov`/`--coverage`) and cache correctness

`-fprofile-arcs -ftest-coverage` (GCC's coverage instrumentation, used by e.g. raytracer's `coverage` CMake preset) makes the compiler write a `.gcno` notes file alongside each object file. That `.gcno` embeds the **absolute source path** used at compile time. sccache treats `.gcno` as a cacheable output of the compile — on a cache hit, it restores the previously-cached `.gcno` bytes untouched, it does not regenerate them.

Every Syrus Workflow clones to a fresh, never-reused `$SYRUS_DATA_ROOT/workflows/<workflow_id>/` path. Combined with sccache's *default* behavior — an exact absolute-path match is required for a cache hit — this means a coverage build's `.gcno` cache entry can only ever be reused by a later compile from the **same Workflow's same still-live workspace**. It cannot be served to a different Workflow, because the absolute path never matches. This is what keeps `gcovr`/coverage output safe: a served `.gcno` always points at a workspace that still exists on disk.

**This safety property depends on never setting `SCCACHE_BASEDIRS`.** That variable exists specifically to let cache hits span different absolute paths by normalizing them away before hashing — turning it on for this fleet would let a coverage build's `.gcno` cache-hit across Workflows, silently corrupting downstream coverage reports with a notes file pointing at a different (likely deleted) workspace. If a future change wants cross-Workflow cache benefit for coverage builds specifically, it needs its own solution (e.g. rewriting/stripping the cached `.gcno`'s embedded path before use) — don't just flip on `SCCACHE_BASEDIRS`.

Net effect: non-coverage C/C++ compiles get full cross-Workflow/cross-worker cache benefit once a bucket is configured. Coverage-instrumented compiles only benefit from same-Workflow reruns (still valuable — that's every retry in a grade loop) until a dedicated fix ships. This is an accepted interim limitation, not a bug.

## Cache stats

After every `prepare` and `grader` shell command runs (with the compiler masquerade active), Syrus captures `sccache --show-stats --stats-format=json` best-effort and appends it to `workflow.artifacts["sccache_stats"]` (see `Workflow::SccacheArtifact`). Each entry records which Run/Step produced it and the raw stats payload. `--show-stats` reports the sccache daemon's cumulative counters since the local server process started, not a delta for the single command that just ran — diff adjacent entries for a per-command figure.

This capture always runs (best-effort, non-fatal) regardless of whether `sccache` is actually doing anything useful for that repo — a repo with no C/C++ code just gets a near-instant no-op read (or, before the `sccache` binary existed on a given worker image, a silent skip).

## Cache stats UI

The Job detail page's Summary tab shows a "Compiler Cache (sccache)" card (`SccacheCard.tsx`) next to the Coverage card, using the same pattern: `App::JobDetailPayload#latest_sccache_json` (`app/services/app/job_detail_payload.rb`) finds the most recent `sccache_stats` capture across the Job's Workflows (by the capture's own `captured_at`, not the owning Workflow's), and `SccacheStatsSummary` (`app/services/sccache_stats_summary.rb`) best-effort-normalizes the raw `stats` payload into `hits`/`misses`/`hit_rate`/`cache_size`/`max_cache_size`/`cache_location` — tolerant of the shape differences sccache versions have shown (flat integers vs. per-language `counts` maps, top-level vs. nested under a `"stats"` key). The panel renders only when at least one capture exists anywhere on the Job; older Runs, non-C++ repos, and Runs predating the sccache wrapper simply omit it — no error state.
