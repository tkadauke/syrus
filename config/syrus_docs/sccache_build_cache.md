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

## Cache-safe coverage recipe for projects that opt into path normalization

Syrus itself should keep leaving `SCCACHE_BASEDIRS` out of the worker env. A
repository may still set it inside a wrapper script or CI job when that project
has proved its coverage build is path-stable. The validated `tkadauke/raytracer`
approach is the generic shape to copy, with project paths and thresholds
replaced by local values.

For GCC/gcov coverage builds, compile coverage objects with both coverage
instrumentation and prefix remapping so cached `.gcno` notes do not contain the
ephemeral Syrus workspace path:

```cmake
# CMakeLists.txt, a toolchain file, or a coverage preset include.
add_compile_options(
  $<$<CONFIG:Coverage>:-O0>
  $<$<CONFIG:Coverage>:-g>
  $<$<CONFIG:Coverage>:--coverage>
  $<$<CONFIG:Coverage>:-fprofile-abs-path>
  $<$<CONFIG:Coverage>:-fprofile-prefix-map=${CMAKE_SOURCE_DIR}=.>
  $<$<CONFIG:Coverage>:-ffile-prefix-map=${CMAKE_SOURCE_DIR}=.>
  $<$<CONFIG:Coverage>:-fdebug-prefix-map=${CMAKE_SOURCE_DIR}=.>
)
add_link_options("$<$<CONFIG:Coverage>:--coverage>")
```

Equivalent wrapper-script form:

```bash
repo_root="$(pwd)"
export CFLAGS="${CFLAGS:-} --coverage -O0 -g -fprofile-abs-path -fprofile-prefix-map=${repo_root}=. -ffile-prefix-map=${repo_root}=. -fdebug-prefix-map=${repo_root}=."
export CXXFLAGS="${CXXFLAGS:-} --coverage -O0 -g -fprofile-abs-path -fprofile-prefix-map=${repo_root}=. -ffile-prefix-map=${repo_root}=. -fdebug-prefix-map=${repo_root}=."
export LDFLAGS="${LDFLAGS:-} --coverage"

cmake -S . -B build/coverage -DCMAKE_BUILD_TYPE=Coverage
cmake --build build/coverage
ctest --test-dir build/coverage --output-on-failure
gcovr --root . --object-directory build/coverage --lcov coverage/lcov.info
```

Only after that remapping is in place should the wrapper opt into shared
absolute-path normalization for the coverage build:

```bash
export SCCACHE_BASEDIRS="$repo_root"
```

Do not set a broad value such as `/syrus-home`, `$SYRUS_DATA_ROOT`, or `/`.
Normalize only the current repository checkout, and only from the command that
has already added the coverage prefix-map flags.

### Two-path validation before enabling it

Validate the recipe from two different absolute checkouts before committing the
`SCCACHE_BASEDIRS` export:

1. Build and test coverage from checkout A with an empty or isolated sccache
   namespace. Keep the cache warm.
2. Build and test coverage from checkout B at a different absolute path, using
   the same sccache namespace and `SCCACHE_BASEDIRS` value so the second build
   can hit objects produced by checkout A.
3. Inspect the `.gcno` files produced or restored in checkout B:

   ```bash
   gcno_count="$(find build/coverage -name '*.gcno' -type f -print | wc -l)"
   test "$gcno_count" -gt 0 || {
     echo "no .gcno files inspected under build/coverage" >&2
     exit 1
   }

   gcno_strings="$(mktemp)"
   find build/coverage -name '*.gcno' -type f -exec strings -- {} + > "$gcno_strings"
   ! grep -F "$checkout_a" "$gcno_strings"
   ! grep -F "$checkout_b" "$gcno_strings"
   ```

   The exact build directory may differ by generator; the important assertions
   are that at least one `.gcno` file was inspected and that no `.gcno` restored
   into checkout B mentions either ephemeral absolute checkout path. Stable
   project-relative paths, compiler-internal paths, and system include paths are
   fine.
4. Generate the normal coverage artifact from checkout B and confirm it resolves
   source files under checkout B, not checkout A, and does not report missing
   source files.
5. Repeat with the order reversed when practical: prime from checkout B, then
   build and report from checkout A.

If any `.gcno`, `gcov`, `gcovr`, lcov, or Cobertura output still contains the
other checkout's absolute path, the project is not safe for normalized shared
coverage caching. Leave `SCCACHE_BASEDIRS` disabled for coverage commands until
the notes are path-remapped or otherwise proven stable.

The rule is intentionally conservative: generic path normalization is unsafe for
coverage unless coverage notes are known to be path-stable or path-remapped.
Non-coverage compile commands can still use shared sccache normally.

## Cache stats

After every `prepare` and `grader` shell command runs (with the compiler masquerade active), Syrus captures `sccache --show-stats --stats-format=json` best-effort and appends it to `workflow.artifacts["sccache_stats"]` (see `BuildCache::StatsArtifact`). Each entry records which Run/Step produced it and the raw stats payload. `--show-stats` reports the sccache daemon's cumulative counters since the local server process started, not a delta for the single command that just ran — diff adjacent entries for a per-command figure.

This capture always runs (best-effort, non-fatal) regardless of whether `sccache` is actually doing anything useful for that repo — a repo with no C/C++ code just gets a near-instant no-op read (or, before the `sccache` binary existed on a given worker image, a silent skip).

## Cache stats UI

The Job detail page's Summary tab shows a "Compiler Cache (sccache)" card (`SccacheCard.tsx`) next to the Coverage card, using the same pattern: `BuildCache::UiSlots` (which contributes the card to the `job.detail` slot) finds the most recent `sccache_stats` capture across the Job's Workflows (by the capture's own `captured_at`, not the owning Workflow's), and `BuildCache::StatsSummary` best-effort-normalizes the raw `stats` payload into `hits`/`misses`/`hit_rate`/`cache_size`/`max_cache_size`/`cache_location` — tolerant of the shape differences sccache versions have shown (flat integers vs. per-language `counts` maps, top-level vs. nested under a `"stats"` key). The panel renders only when at least one capture exists anywhere on the Job; older Runs, non-C++ repos, and Runs predating the sccache wrapper simply omit it — no error state.

## Admin: inspecting and clearing the bucket

`/admin/build_cache` (nav: Admin → Build Cache, `AdminBuildCache.tsx`) talks to the bucket directly via the S3 API — not through Run artifacts — to show aggregate footprint: object count, total size, and oldest/newest object age. `BuildCache::Client` wraps `Aws::S3::Client`, reading the exact same `SCCACHE_BUCKET` / `SCCACHE_ENDPOINT` / `SCCACHE_REGION` / `SCCACHE_S3_KEY_PREFIX` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars documented above — there is one credential source for the whole cache feature, not a second one for the admin UI. The page renders a "not configured" notice instead of an error when `SCCACHE_BUCKET` is unset. A single stats/clear pass is capped at `BuildCache::Client::MAX_OBJECTS_SCANNED` (200,000) objects; the UI surfaces a "truncated" notice when the real totals may be higher rather than silently under-reporting.

Clearing the bucket (full, or scoped to objects older than N days) never fires directly off a button click. It follows this codebase's pending-action pattern: submitting the form creates a `pending` `BuildCache::ClearRequest` with a required audit `reason` but does **not** touch the bucket; a separate "Confirm and clear" action (behind a `useConfirm` dialog) actually executes the deletion via `BuildCache::ClearRequest#confirm!`, which records the outcome (`deleted_count`, `bytes_freed`, `truncated`) on the request and logs an `AdminAction` (`build_cache_clear`) for audit. A pending request can also be cancelled without ever touching the bucket. Only one request may be pending at a time. This mirrors — but does not reuse — `ChatPendingAction`'s confirm+reason+audit flow, since that model is chat-session-scoped and this is a plain admin-UI surface with no chat involved.

Endpoints: `GET /api/v1/app/admin/build_cache` (stats + pending/recent requests), `POST /api/v1/app/admin/build_cache/clear_requests` (create pending), `POST .../clear_requests/:id/confirm`, `POST .../clear_requests/:id/cancel` — session-authenticated, admin-only. `GET /api/v1/admin/build_cache` exposes the same read-only stats to bearer-token external API clients; destructive actions are intentionally not exposed on that surface.

## Plugin ownership

Everything above lives in the `build_cache` plugin: the S3 client, the stats
capture and summary, the clear-request model (table `build_cache_clear_requests`),
the admin page, and the Job-detail card.

Two core hooks make that possible. `Syrus::Plugin::StepEnvironment` lets the
plugin contribute the `SCCACHE_*` and `AWS_*` names that `Steps::Prepare`
forwards into prepare/grader/deploy subprocesses -- core no longer names them.
And the capture runs as a `domain_subscriber` on `step.command.completed`, an
inline event published after each shell command a step runs, replacing the
`Steps::Base#capture_sccache_stats!` call that three step classes used to make
directly. Inline delivery is what lets the subscriber still reach the workspace
and the command's own scrubbed environment before the workspace is torn down.

Disabling the plugin stops the captures, drops the `SCCACHE_*` variables from
step subprocesses (so sccache falls back to its local cache), and removes the
admin page and the Job-detail card. The recorded artifacts and clear-request
rows are left alone.
