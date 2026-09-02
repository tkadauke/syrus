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

### Deliberately not forwarded by default: `SCCACHE_BASEDIRS`

sccache supports normalizing away a base directory before hashing
(`SCCACHE_BASEDIRS`), which lets a cache hit span builds run from different
absolute paths. Syrus does **not** forward this var globally, and it should
stay that way. Project-specific grader scripts may opt in only after proving
their coverage notes are path-stable or path-remapped; see the
coverage-correctness guidance below.

## Coverage builds (`gcov`/`--coverage`) and cache correctness

`-fprofile-arcs -ftest-coverage` (GCC's coverage instrumentation, used by e.g. raytracer's `coverage` CMake preset) makes the compiler write a `.gcno` notes file alongside each object file. That `.gcno` embeds the **absolute source path** used at compile time. sccache treats `.gcno` as a cacheable output of the compile — on a cache hit, it restores the previously-cached `.gcno` bytes untouched, it does not regenerate them.

Every Syrus Workflow clones to a fresh, never-reused `$SYRUS_DATA_ROOT/workflows/<workflow_id>/` path. Combined with sccache's *default* behavior — an exact absolute-path match is required for a cache hit — this means a coverage build's `.gcno` cache entry can only ever be reused by a later compile from the **same Workflow's same still-live workspace**. It cannot be served to a different Workflow, because the absolute path never matches. This is what keeps `gcovr`/coverage output safe: a served `.gcno` always points at a workspace that still exists on disk.

**This safety property depends on never setting `SCCACHE_BASEDIRS` for an
unvalidated coverage build.** That variable exists specifically to let cache
hits span different absolute paths by normalizing them away before hashing.
Turning it on globally would let a coverage build's `.gcno` cache-hit across
Workflows and could silently corrupt downstream coverage reports with a notes
file pointing at a different (likely deleted) workspace.

Net effect: non-coverage C/C++ compiles get full cross-Workflow/cross-worker
cache benefit once a bucket is configured. Coverage-instrumented compiles only
benefit from same-Workflow reruns (still valuable -- that's every retry in a
grade loop) unless the repository's coverage recipe deliberately remaps the
paths embedded in coverage notes. This is the safe default, not a cache bug.

## Cache-safe GCC coverage recipe

The safe way to combine shared sccache reuse with GCC coverage is to make the
coverage notes path-independent before enabling `SCCACHE_BASEDIRS`. The
raytracer validation from JOB-4056 is the reference example, but future
projects should copy the shape, not raytracer-specific directories or
thresholds.

For GCC/gcov coverage builds, compile with coverage instrumentation plus path
remapping for both the source/build path recorded in generated debug or
coverage metadata and the profile path used by GCC's coverage runtime:

```cmake
# CMake example for a coverage build type or preset.
add_compile_options(
  --coverage
  -fprofile-prefix-map=${CMAKE_SOURCE_DIR}=.
  -ffile-prefix-map=${CMAKE_SOURCE_DIR}=.
)

add_link_options(--coverage)
```

Equivalent shell flags for a wrapper script:

```sh
export CFLAGS="${CFLAGS:-} --coverage -fprofile-prefix-map=$PWD=. -ffile-prefix-map=$PWD=."
export CXXFLAGS="${CXXFLAGS:-} --coverage -fprofile-prefix-map=$PWD=. -ffile-prefix-map=$PWD=."
export LDFLAGS="${LDFLAGS:-} --coverage"
```

Use the build-system equivalent if the project already centralizes flags in a
CMake preset, toolchain file, Meson native file, Make wrapper, or CI script.
The important invariant is that the `.gcno` files restored from sccache do not
contain the absolute Syrus workflow path that produced them.

### Validation before opting in

Before a project sets `SCCACHE_BASEDIRS` in a grader or prepare wrapper, prove
the coverage notes are path-stable across two different checkout roots:

1. Build and run the coverage suite in one clean path, for example
   `/tmp/syrus-coverage-a/project`, with the proposed remapping flags and
   `SCCACHE_BASEDIRS` enabled for that path.
2. Build and run the same coverage suite in a second clean path, for example
   `/tmp/syrus-coverage-b/project`, with the same flags and
   `SCCACHE_BASEDIRS` enabled for that second path. Warm the cache from the
   first build so the second path exercises restored cached compiler outputs,
   not only fresh compiles.
3. Inspect representative `.gcno` files from the second build with
   `strings path/to/file.gcno` (or the project's chosen gcov/gcovr debug
   tooling). The first checkout root must not appear, and neither Syrus
   workflow path should be required for `gcovr` or the configured coverage
   reporter to find sources.
4. Generate the normal coverage artifact from the second path and confirm it
   reports paths relative to the repository (or another stable prefix the
   project's coverage parser understands), not `/tmp/syrus-coverage-a/...` or
   `$SYRUS_DATA_ROOT/workflows/<old_workflow_id>/...`.

If any `.gcno` restored in path B still names path A, the recipe is unsafe:
leave `SCCACHE_BASEDIRS` disabled for coverage builds. If non-coverage builds
want cross-workflow cache hits, split them from coverage builds instead of
normalizing every compile indiscriminately.

## Cache stats

After every `prepare` and `grader` shell command runs (with the compiler masquerade active), Syrus captures `sccache --show-stats --stats-format=json` best-effort and appends it to `workflow.artifacts["sccache_stats"]` (see `Workflow::SccacheArtifact`). Each entry records which Run/Step produced it and the raw stats payload. `--show-stats` reports the sccache daemon's cumulative counters since the local server process started, not a delta for the single command that just ran — diff adjacent entries for a per-command figure.

This capture always runs (best-effort, non-fatal) regardless of whether `sccache` is actually doing anything useful for that repo — a repo with no C/C++ code just gets a near-instant no-op read (or, before the `sccache` binary existed on a given worker image, a silent skip).

## Cache stats UI

The Job detail page's Summary tab shows a "Compiler Cache (sccache)" card (`SccacheCard.tsx`) next to the Coverage card, using the same pattern: `App::JobDetailPayload#latest_sccache_json` (`app/services/app/job_detail_payload.rb`) finds the most recent `sccache_stats` capture across the Job's Workflows (by the capture's own `captured_at`, not the owning Workflow's), and `SccacheStatsSummary` (`app/services/sccache_stats_summary.rb`) best-effort-normalizes the raw `stats` payload into `hits`/`misses`/`hit_rate`/`cache_size`/`max_cache_size`/`cache_location` — tolerant of the shape differences sccache versions have shown (flat integers vs. per-language `counts` maps, top-level vs. nested under a `"stats"` key). The panel renders only when at least one capture exists anywhere on the Job; older Runs, non-C++ repos, and Runs predating the sccache wrapper simply omit it — no error state.

## Admin: inspecting and clearing the bucket

`/admin/build_cache` (nav: Admin → Build Cache, `AdminBuildCache.tsx`) talks to the bucket directly via the S3 API — not through Run artifacts — to show aggregate footprint: object count, total size, and oldest/newest object age. `Admin::BuildCache::Client` (`app/services/admin/build_cache/client.rb`) wraps `Aws::S3::Client`, reading the exact same `SCCACHE_BUCKET` / `SCCACHE_ENDPOINT` / `SCCACHE_REGION` / `SCCACHE_S3_KEY_PREFIX` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars documented above — there is one credential source for the whole cache feature, not a second one for the admin UI. The page renders a "not configured" notice instead of an error when `SCCACHE_BUCKET` is unset. A single stats/clear pass is capped at `Admin::BuildCache::Client::MAX_OBJECTS_SCANNED` (200,000) objects; the UI surfaces a "truncated" notice when the real totals may be higher rather than silently under-reporting.

Clearing the bucket (full, or scoped to objects older than N days) never fires directly off a button click. It follows this codebase's pending-action pattern: submitting the form creates a `pending` `AdminBuildCacheClearRequest` with a required audit `reason` but does **not** touch the bucket; a separate "Confirm and clear" action (behind a `useConfirm` dialog) actually executes the deletion via `AdminBuildCacheClearRequest#confirm!`, which records the outcome (`deleted_count`, `bytes_freed`, `truncated`) on the request and logs an `AdminAction` (`build_cache_clear`) for audit. A pending request can also be cancelled without ever touching the bucket. Only one request may be pending at a time. This mirrors — but does not reuse — `ChatPendingAction`'s confirm+reason+audit flow, since that model is chat-session-scoped and this is a plain admin-UI surface with no chat involved.

Endpoints: `GET /api/v1/app/admin/build_cache` (stats + pending/recent requests), `POST /api/v1/app/admin/build_cache/clear_requests` (create pending), `POST .../clear_requests/:id/confirm`, `POST .../clear_requests/:id/cancel` — session-authenticated, admin-only. `GET /api/v1/admin/build_cache` exposes the same read-only stats to bearer-token external API clients; destructive actions are intentionally not exposed on that surface.
