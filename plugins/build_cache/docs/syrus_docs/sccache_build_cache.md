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

### Not forwarded by default: `SCCACHE_BASEDIRS`

sccache supports normalizing away a base directory before hashing (`SCCACHE_BASEDIRS`), which lets a cache hit span builds run from different absolute paths. Syrus does **not** forward this by default — see the coverage-correctness note below. A repository can opt in to having Syrus manage this itself once its coverage build has proven it is path-remapped/safe (see "Repository opt-in: `basedirs_safe`" below) — do not hand-roll `export SCCACHE_BASEDIRS=...` inside a `.syrus.yml` grader command instead; see "Why hand-rolled `SCCACHE_BASEDIRS` in a grader command doesn't work" below for why that pattern silently fails.

## Per-Workflow daemon isolation

sccache is a client/server pair: the small CLI that masquerades as `cc`/`g++`/etc. is a *client* that talks to a long-running *server* process over a local TCP port. The server reads its entire backend and cache-key configuration — `SCCACHE_BUCKET` and friends, and `SCCACHE_BASEDIRS` — exactly once, when it starts. A client invocation's own environment only matters for the very first invocation that has to lazily spawn the server; every later invocation just reuses whatever server is already listening, regardless of that invocation's own env.

Worker pods run multiple Workflows concurrently (`AppSetting.max_concurrent_agent_runs`), and by default sccache listens on one fixed port per host. That makes the daemon a de facto host-level singleton that can easily end up serving a completely different Workflow's, or even a stale/long-dead Workflow's, configuration — this was JOB-4309's root cause: a grader command exported `SCCACHE_BASEDIRS`/pointed at the shared bucket, but a daemon that had already been started earlier (by `prepare`, an earlier grade iteration, or an unrelated Job on the same worker pod) was still serving requests with whatever env it had when *it* started, silently ignoring the later command's env entirely.

`BuildCache::DaemonAddress.port_for(workflow)` derives a distinct `SCCACHE_SERVER_PORT` per Workflow (`20000 + workflow.id % 40000`). Both `Steps::Prepare` and `Steps::Grader` forward this via `BuildCache::StepEnvironment#extra_env` (the computed-value companion to `#forwarded_env_keys` on `Syrus::Plugin::StepEnvironment`), so every compiler invocation within one Workflow — across `prepare` and every `grader` Step — agrees on the same port, and that Workflow's first invocation (almost always during `prepare`) lazily spawns a daemon that is guaranteed to inherit *that Workflow's own, current* env: the S3 backend vars, and conditionally `SCCACHE_BASEDIRS` (see below). It is never a daemon left over from a different Workflow, and never shared with a concurrent one on the same pod. The daemon self-terminates after sccache's own idle timeout once the Workflow's compiles stop — an accepted, low resource cost for the correctness this buys.

## Repository opt-in: `basedirs_safe`

`BuildCache::RepositorySettings` (`build_cache_repository_settings` table, one row per repository, missing row = not opted in) is a per-repository boolean, analogous in spirit to `Repository#trust_clean_rebase_grade` but kept in the `build_cache` plugin's own table rather than on the core `Repository` model (see `PluginDataCleanup`/`Syrus::DataCleanup` — a plugin owns the rows that reference a core record, the core model does not declare an association back into a plugin table). Read/write it via:

```
GET   /api/v1/app/repositories/:id/build_cache_settings
PATCH /api/v1/app/repositories/:id/build_cache_settings   { "basedirs_safe": true }
```

When `basedirs_safe` is true, `BuildCache::RuntimeEnv` forwards `SCCACHE_BASEDIRS=<this Workflow's workspace path>` for that repository's `prepare`/`grader` subprocesses, for the whole Workflow — not scoped to a single grader command, since the opt-in itself is a repository-wide claim ("I have proved every coverage-relevant compile in this repo is path-remapped/stable"), and the daemon can only be configured once per Workflow regardless. Every other repository keeps sccache's default exact-path-match behavior. **Only set this after completing the two-path validation below** — an unproven repository that opts in gets exactly the `.gcno` cross-Workflow corruption risk this whole section exists to prevent.

### Why hand-rolled `SCCACHE_BASEDIRS` in a grader command doesn't work

An earlier version of this guide suggested exporting `SCCACHE_BASEDIRS` directly inside a `.syrus.yml` grader command. **Don't do this** — per the daemon-isolation section above, that command's own env only matters if it happens to be the very first sccache invocation of the Workflow, which a coverage grader typically is not (`prepare`'s dependency install usually gets there first). The command's `export` has no effect on an already-running daemon. Use the repository-level `basedirs_safe` opt-in instead, which is threaded into every `prepare`/`grader` subprocess's env from the start of the Workflow, guaranteeing it reaches whichever invocation actually spawns the daemon.

## Coverage builds (`gcov`/`--coverage`) and cache correctness

`-fprofile-arcs -ftest-coverage` (GCC's coverage instrumentation, used by e.g. raytracer's `coverage` CMake preset) makes the compiler write a `.gcno` notes file alongside each object file. That `.gcno` embeds the **absolute source path** used at compile time. sccache treats `.gcno` as a cacheable output of the compile — on a cache hit, it restores the previously-cached `.gcno` bytes untouched, it does not regenerate them.

Every Syrus Workflow clones to a fresh, never-reused `$SYRUS_DATA_ROOT/workflows/<workflow_id>/` path. Combined with sccache's *default* behavior — an exact absolute-path match is required for a cache hit — this means a coverage build's `.gcno` cache entry can only ever be reused by a later compile from the **same Workflow's same still-live workspace**. It cannot be served to a different Workflow, because the absolute path never matches. This is what keeps `gcovr`/coverage output safe: a served `.gcno` always points at a workspace that still exists on disk.

**This safety property depends on never setting `SCCACHE_BASEDIRS`.** That variable exists specifically to let cache hits span different absolute paths by normalizing them away before hashing — turning it on unconditionally for this fleet would let a coverage build's `.gcno` cache-hit across Workflows, silently corrupting downstream coverage reports with a notes file pointing at a different (likely deleted) workspace. This is exactly why the `basedirs_safe` opt-in below is per-repository and requires proving the coverage build's notes are path-remapped first — don't just flip it on.

Net effect: non-coverage C/C++ compiles get full cross-Workflow/cross-worker cache benefit once a bucket is configured. Coverage-instrumented compiles only get cross-Workflow cache benefit for repositories that have opted into `basedirs_safe`; everyone else only benefits from same-Workflow reruns (still valuable — that's every retry in a grade loop).

## Cache-safe coverage recipe for projects that opt into path normalization

Syrus leaves `SCCACHE_BASEDIRS` out of the daemon env by default. A repository
can opt in once it has proved its coverage build is path-stable, via the
`basedirs_safe` setting described above — Syrus then manages the actual
`SCCACHE_BASEDIRS` value itself (the Workflow's own workspace path), scoped
safely per-Workflow (see "Per-Workflow daemon isolation" above). The
project-side work is unchanged: the validated `tkadauke/raytracer` approach
below is the generic shape to copy, with project paths and thresholds replaced
by local values.

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

Only after that remapping is in place, and only after the two-path validation
below passes, set the repository's opt-in:

```bash
curl -X PATCH -H "Authorization: Bearer $SYRUS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"basedirs_safe": true}' \
  "$SYRUS_URL/api/v1/app/repositories/$REPOSITORY_ID/build_cache_settings"
```

Do not build a project-specific workaround that sets `SCCACHE_BASEDIRS`
directly (in a `.syrus.yml` command, a wrapper script, or otherwise) — see "Why
hand-rolled `SCCACHE_BASEDIRS` in a grader command doesn't work" above. Syrus
normalizes only the current Workflow's own workspace path; there is no way to
set a broader value like `/syrus-home` or `$SYRUS_DATA_ROOT` through this
mechanism.

### Two-path validation before enabling it

Validate the recipe from two different absolute checkouts before setting
`basedirs_safe`:

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

### Cache mismatch warnings

`BuildCache::CacheMismatchDetector` runs after every captured snapshot and files a `WorkflowWarning` (`kind: "sccache_config_mismatch"`, visible on the Job details page with a one-click "file a fix Job" action — see `config/syrus_docs/workflow_warnings.md`) when the daemon's reported state doesn't match what Syrus configured it for:

- **Shared cache expected, but `cache_location` reports local disk** — `SCCACHE_BUCKET` was forwarded into the command's env, but the stats snapshot still reports a local-disk cache. Per-Workflow daemon isolation (above) should make this rare going forward; a recurrence usually means the S3/MinIO backend vars aren't actually reaching the worker pod, or the daemon's connection to the bucket is failing silently.
- **`basedirs_safe` expected, but stats report `basedirs: []`** — `SCCACHE_BASEDIRS` was forwarded (the repository opted in), but the daemon's stats show it was never applied.

Both warnings are best-effort and never fail the Workflow — they're an operator signal, not a grading gate.

## Cache stats UI

The Job detail page's Summary tab shows a "Compiler Cache (sccache)" card (`SccacheCard.tsx`) next to the Coverage card, using the same pattern: `BuildCache::UiSlots` (which contributes the card to the `job.detail` slot) finds the most recent `sccache_stats` capture across the Job's Workflows (by the capture's own `captured_at`, not the owning Workflow's), and `BuildCache::StatsSummary` best-effort-normalizes the raw `stats` payload into `hits`/`misses`/`hit_rate`/`cache_size`/`max_cache_size`/`cache_location` — tolerant of the shape differences sccache versions have shown (flat integers vs. per-language `counts` maps, top-level vs. nested under a `"stats"` key). The panel renders only when at least one capture exists anywhere on the Job; older Runs, non-C++ repos, and Runs predating the sccache wrapper simply omit it — no error state.

## Admin: inspecting and clearing the bucket

`/admin/build_cache` (nav: Admin → Build Cache, `AdminBuildCache.tsx`) talks to the bucket directly via the S3 API — not through Run artifacts — to show aggregate footprint: object count, total size, and oldest/newest object age. `BuildCache::Client` wraps `Aws::S3::Client`, reading the exact same `SCCACHE_BUCKET` / `SCCACHE_ENDPOINT` / `SCCACHE_REGION` / `SCCACHE_S3_KEY_PREFIX` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars documented above — there is one credential source for the whole cache feature, not a second one for the admin UI. The page renders a "not configured" notice instead of an error when `SCCACHE_BUCKET` is unset. A single stats/clear pass is capped at `BuildCache::Client::MAX_OBJECTS_SCANNED` (200,000) objects; the UI surfaces a "truncated" notice when the real totals may be higher rather than silently under-reporting.

Clearing the bucket (full, or scoped to objects older than N days) never fires directly off a button click. It follows this codebase's pending-action pattern: submitting the form creates a `pending` `BuildCache::ClearRequest` with a required audit `reason` but does **not** touch the bucket; a separate "Confirm and clear" action (behind a `useConfirm` dialog) actually executes the deletion via `BuildCache::ClearRequest#confirm!`, which records the outcome (`deleted_count`, `bytes_freed`, `truncated`) on the request and logs an `AdminAction` (`build_cache_clear`) for audit. A pending request can also be cancelled without ever touching the bucket. Only one request may be pending at a time. This mirrors — but does not reuse — `ChatPendingAction`'s confirm+reason+audit flow, since that model is chat-session-scoped and this is a plain admin-UI surface with no chat involved.

Endpoints: `GET /api/v1/app/admin/build_cache` (stats + pending/recent requests), `POST /api/v1/app/admin/build_cache/clear_requests` (create pending), `POST .../clear_requests/:id/confirm`, `POST .../clear_requests/:id/cancel` — session-authenticated, admin-only. `GET /api/v1/admin/build_cache` exposes the same read-only stats to bearer-token external API clients; destructive actions are intentionally not exposed on that surface.

## Plugin ownership

Everything above lives in the `build_cache` plugin: the S3 client, the stats
capture and summary, the mismatch detector, the clear-request model (table
`build_cache_clear_requests`), the per-repository opt-in
(`BuildCache::RepositorySettings`, table `build_cache_repository_settings`),
the admin page, and the Job-detail card.

Three core hooks make that possible. `Syrus::Plugin::StepEnvironment` lets the
plugin contribute both the `SCCACHE_*`/`AWS_*` names `Steps::Prepare` forwards
from the worker's own `ENV` into prepare/grader/deploy subprocesses
(`#forwarded_env_keys`) and values it computes per Workflow --
`SCCACHE_SERVER_PORT` and conditionally `SCCACHE_BASEDIRS` -- through the
companion `#extra_env` hook, gathered by `Steps::Prepare.prep_extra_env` and
merged into both `Steps::Prepare#env` and `Steps::Grader#env`. The stats
capture runs as a `domain_subscriber` on `step.command.completed`, an
inline event published after each shell command a step runs, replacing the
`Steps::Base#capture_sccache_stats!` call that three step classes used to make
directly. Inline delivery is what lets the subscriber still reach the workspace
and the command's own scrubbed environment before the workspace is torn down;
the mismatch detector runs from that same subscriber, right after the capture.
`BuildCache::RepositorySettings` belongs to `Repository` by plain foreign key
rather than a core-model association -- see `PluginDataCleanup`/
`Syrus::DataCleanup`, registered via `BuildCache::DataCleanup.install_into`.

Disabling the plugin stops the captures and mismatch warnings, drops the
`SCCACHE_*` variables (both forwarded and computed) from step subprocesses (so
sccache falls back to its local cache, unscoped per-Workflow), and removes the
admin page and the Job-detail card. The recorded artifacts, clear-request rows,
and per-repository `basedirs_safe` settings are left alone.
