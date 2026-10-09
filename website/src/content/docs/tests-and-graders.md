---
title: Tests and Graders
description: Configure fast review checks, landing checks, CI repair checks, coverage, and test insights.
---

# Tests and Graders

Graders are repository-owned commands that Syrus runs to decide whether agent
work is good enough to continue. Custom `run:` graders execute exactly as
configured. Framework plugins can also provide typed graders that own the
normal command shape, JSON/JUnit output, and base-revision retry metadata for
common test frameworks.

## Phases

Each grader can declare the phases where it should run:

- `review`: cheap checks before a human reviews the PR.
- `landing`: checks that must pass immediately before merge.
- `ci`: checks used when Syrus is repairing CI failures.

Example:

```yaml
grade:
  - type: rspec
    failures: allow_inherited
    tags:
      ci:
        include: [ci_only]
```

Minitest projects can use the Ruby plugin's Minitest typed grader:

```yaml
grade:
  - type: minitest
```

By default it uses `bin/rails test` in Rails apps, `bundle exec rake test`
when a Rakefile is present, and `bundle exec ruby -Itest test` otherwise.
Use `command`, `focused_command`, `ci_command`, or `paths` when a repository
needs a custom Minitest wrapper.

Java/JVM and Kotlin/JVM projects can use the Java plugin's Gradle and Maven typed graders:

```yaml
grade:
  - type: gradle
    tasks: [test]
```

```yaml
grade:
  - type: maven
    goals: [verify]
```

Both prefer project wrappers (`./gradlew`, `./mvnw`) and aggregate standard
JUnit XML report directories into one Syrus `junit_output` artifact when
reports are present. Use `report_paths:` for custom report directories or
`junit_output: false` when a project does not emit JUnit XML.
The Kotlin plugin detects Kotlin/JVM projects and Gradle Kotlin DSL files, then
reuses the same Gradle/JUnit machinery instead of defining a separate Kotlin
grader type.

Android projects can use the Android plugin's Gradle-backed typed graders:

```yaml
grade:
  - type: android-assemble
    tasks: [assembleDebug]
  - type: android-unit-test
    tasks: [testDebugUnitTest]
  - type: android-managed-device
    tasks: [allDevicesCheck]
    phases: [landing, ci]
    timeout_minutes: 60
```

Available Android types are `android-assemble`, `android-unit-test`,
`android-instrumented-test`, and `android-managed-device`. They prefer
`./gradlew`, declare Linux execution capabilities, aggregate Android/JUnit XML
reports when present, and record APK/AAB, Android test result, managed-device,
and report/log paths in grader metadata. Use explicit `tasks:` for repository
variants and Gradle Managed Device names.

For mixed-language monorepos, put the typed grader in the JVM project's nested
`.syrus.yml` and scope it to that project:

```yaml
project:
  id: api
  label: API service
  kind: service

grade:
  - type: gradle
    name: api-tests
    tasks: [test]
    when_files_changed:
      - "src/main/java/**/*"
      - "src/main/kotlin/**/*"
      - "src/test/java/**/*"
      - "src/test/kotlin/**/*"
      - "build.gradle.kts"
      - "gradle/**/*"
      - "gradlew"
```

The practical pattern is to keep review checks fast enough that iteration
feels interactive, then run heavier checks at landing or during CI repair.
Typed graders can generate those variants from one declaration; custom graders
use `phases` directly.

## Required and Optional Checks

Graders are required by default. Optional graders still run and appear in the
UI, but they do not fail the workflow by themselves.

```yaml
grade:
  - name: lint-docs
    run: bin/lint-docs
    required: false
```

Use optional checks for early warning signals, not for correctness gates that
must protect the branch.

## Inherited Failures

Some projects allow a Job to pass when a grader failure is already present on
the base revision and the Job did not introduce it. Set
`failures: allow_inherited` for graders where Syrus can compare the branch
result against known base results or structured test cases.

This works best for test runners that produce JUnit. Binary build checks can
still benefit from inherited-failure policy, but they provide less detail than
test-level results.

## JUnit and Test Insights

When a grader writes JUnit output, Syrus ingests individual test cases. The
repository Tests page groups repeated executions into durable test identities,
so operators can find:

- recently failing tests,
- slow tests,
- tests with changing outcomes,
- test history with links back to specific runs.

Prefer stable test names and suites. If a test runner changes names on every
run, Syrus cannot build a useful history.

## Coverage

Coverage belongs in the repository's grader command. Syrus can read configured
coverage artifacts, summarize deltas, and post a PR comment when requested,
but the command itself should decide when coverage is collected.

When a workflow has PR diff annotations, the Job Review tab can also show a
`PR coverage` metric gutter for the selected diff version. Covered added lines
render as passing, uncovered added lines render as attention-needed, and
non-executable lines stay visually quiet.

Repository pages also use stored coverage snapshots as one input to the
cognitive debt panel. That panel ranks files for human review by combining
coverage, review/approval engagement evidence, recent churn, and health
signals. Its "cognitive coverage" percentage is deliberately labeled as a
proxy for human engagement, not proof that a person fully understands the code.
When line-specific review evidence comes from a different revision and cannot
be projected on the repository page, Syrus links it as review context but does
not count it as covered.

For large suites, a common setup is:

- no coverage for most review and repair iterations,
- one coverage run for the final or landing path,
- CI-only coverage checks for expensive policies.

### C/C++ coverage with shared compiler caches

Syrus workers include `sccache` for C/C++ compiles, but coverage builds need
extra care. GCC `--coverage` / `-fprofile-arcs -ftest-coverage` writes `.gcno`
notes next to object files, and those notes can contain the absolute source path
from the compile workspace. sccache caches and restores `.gcno` files
byte-for-byte, so a cache hit from another Syrus workflow can point coverage
tools at a stale workspace if paths were normalized too broadly.

Do not enable generic `SCCACHE_BASEDIRS` path normalization for coverage unless
the project has proved its coverage notes are path-stable or path-remapped.
Without `SCCACHE_BASEDIRS`, coverage builds are conservative: they can still hit
within the same workflow workspace, but they will not reuse `.gcno` files across
different workflow paths.

The safe pattern, validated on the `tkadauke/raytracer` CMake/GCC coverage
build, is to remap the repository checkout before opting into
`SCCACHE_BASEDIRS`:

```cmake
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

Then export `SCCACHE_BASEDIRS` only from the coverage wrapper, scoped to the
current checkout:

```bash
repo_root="$(pwd)"
export SCCACHE_BASEDIRS="$repo_root"
cmake -S . -B build/coverage -DCMAKE_BUILD_TYPE=Coverage
cmake --build build/coverage
ctest --test-dir build/coverage --output-on-failure
gcovr --root . --object-directory build/coverage --lcov coverage/lcov.info
```

Before shipping that wrapper, validate it from two different absolute checkout
paths. Prime sccache from checkout A, build/report from checkout B, and inspect
the `.gcno` files restored into checkout B:

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

Adjust the build directory for your layout. The important checks are that at
least one `.gcno` file was inspected, restored coverage notes do not mention
either ephemeral checkout path, and the generated lcov or Cobertura report
resolves sources under the checkout that produced the report. Repeat in the
opposite direction when practical.

## File-Sensitive Graders

Use `when_files_changed` for expensive checks that only matter for certain
paths:

```yaml
grade:
  - name: website-build
    run: npm run build
    phases: [landing]
    when_files_changed:
      - "website/**/*"
      - "package.json"
      - "package-lock.json"
```

This keeps agents from burning time on unrelated checks while preserving the
gate when relevant files change.

## Good Wrapper Scripts

Good grader commands are deterministic, reasonably quiet, and produce
machine-readable output in a known location. For common test suites, prefer
typed graders such as `type: rspec` or `type: vitest`; use custom wrapper
scripts only when the framework plugin cannot express a repository-specific
requirement yet.
