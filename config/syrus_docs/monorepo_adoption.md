# Project-Aware Monorepo Adoption Guide

This guide is the practical path for adopting project-aware `.syrus.yml`
configuration. It mirrors DOC-20's staged model: start with unchanged
root-only behavior, then add precision only where a repository actually needs
it.

Use the reference docs for field-level details:

- `syrus_yml.md` explains every `.syrus.yml` section.
- `target_graph.md` explains compiled labels, dependencies, target health, and
  inspection APIs.

## The Adoption Rule

Do not model the whole repository on day one. Add the smallest amount of
configuration that makes Syrus's behavior easier to understand, faster to run,
or less ambiguous for operators.

Syrus never creates a project boundary from directory layout alone. A nested
project exists because a nested `.syrus.yml` declares it, or because an
explicit build-system graph provider imports it. Package manifests, Rails
layouts, Go modules, Gradle projects, and workspace files can help humans
choose where to declare projects, but they do not make Syrus select project
previews, coverage, hooks, or target health by themselves.

Good reasons to move up a level:

- A change in one directory should not boot, preview, or grade an unrelated
  product.
- Operators need to choose between multiple previewable apps.
- A shared package affects several products and should select their checks.
- A repository already has a precise Buck, Bazel, Pants, Nx, Turbo, or similar
  build graph.

Poor reasons to move up a level:

- The repository merely has more than one directory.
- A single root grader is already fast and reliable.
- A target would only restate one command with no reusable source scope or
  dependencies.
- The relationship is temporary and a simple `when_files_changed` glob would
  be clearer.

## Level 0: Root `.syrus.yml` Only

Level 0 is the default for small repositories and for monorepos that are still
early in adoption. Keep one `.syrus.yml` at the repository root. Syrus preserves
the existing behavior: root `prepare`, `preview`, `visual_review`, `hooks`,
`adversarial_review`, `formatters`, `generated`, `grade`, `coverage`,
`deploy`, and `deployment_stages` remain repository-wide.

```yaml
# /.syrus.yml
prepare:
  - bundle install
  - npm ci

preview:
  start: bin/rails server -p $PORT -b 0.0.0.0
  health_check: /up

grade:
  - name: rspec
    run: bin/rspec-fast
    phases: [review, landing]
  - name: react
    run: npm run test:react
    phases: [review, landing]
```

Internally, Syrus still compiles this into the TargetGraph under the implicit
root project, with labels such as `//:repo`, `//:prepare`, and
`//:grade/rspec`. Operators do not need to care unless they open the target
graph inspector.

Stay at Level 0 when:

- The repository behaves like one product or one deployable unit.
- A root preview is the only useful preview.
- Root graders are cheap enough to run for ordinary PRs.
- File-based grader skips through `when_files_changed` are enough.

Small app example:

```yaml
# /.syrus.yml
prepare:
  - bundle install
  - npm ci

preview:
  seed: bin/rails db:prepare db:seed
  start: bin/rails server -p $PORT -b 0.0.0.0
  health_check: /up

grade:
  - name: smoke
    run: bin/check-eager-load
  - name: tests
    run: bin/rspec-fast
```

Small CLI example:

```yaml
# /.syrus.yml
prepare:
  - go mod download

grade:
  - name: go-tests
    run: go test ./...
```

## Level 1: Nested `.syrus.yml` With Scoped Legacy Primitives

Move to Level 1 when the repository has real operator-facing boundaries:
separate apps, a CLI beside a web app, mobile apps with different previews, or
subsystems that deserve their own review/coverage policy.

Add a `.syrus.yml` only inside directories that should become Syrus projects.
Nested discovery is automatic. The file itself is the explicit declaration;
Syrus does not guess projects from `package.json`, `go.mod`, Xcode, Gradle, or
Rails conventions.

```text
.
|-- .syrus.yml
|-- apps
|   |-- web
|   |   `-- .syrus.yml
|   `-- api
|       `-- .syrus.yml
`-- cli
    `-- .syrus.yml
```

Legacy sections in a nested file are scoped to that directory. A nested
`preview:` runs from that project directory. Nested `adversarial_review`
criteria, `visual_review`, `coverage`, and `hooks.post_checkout` apply when
the project is affected. Nested `prepare`, `formatters`, `generated`, and
`grade` compile into project targets for graph diagnostics and target-aware
selection.

Important runtime caveat: normal workflow validation still materializes the
root `grade:` plan today. Nested `grade:` entries are useful target graph
declarations and dependency-analysis hints, but they are not a replacement for
root validation until nested-grader execution policy is wired. Keep the root
graders that actually protect review, landing, and CI, and use nested grader
entries to document the project checks Syrus should understand.

Web app example:

```yaml
# apps/web/.syrus.yml
preview:
  setup:
    - npm ci
  start: npm run dev -- --host 0.0.0.0 --port $PORT
  health_check: /

visual_review:
  enabled: true
  when_files_changed:
    - "src/**/*.tsx"
    - "src/**/*.css"

grade:
  # Graph declaration for this project. Keep an executable root grader such as
  # `npm --prefix apps/web run typecheck` until nested grader execution lands.
  - name: typecheck
    run: npm run typecheck
    when_files_changed:
      - "src/**/*.ts"
      - "src/**/*.tsx"
```

CLI example:

```yaml
# cli/.syrus.yml
prepare:
  - go mod download

formatters:
  - command: gofmt -w .
    files: ["**/*.go"]

grade:
  # Graph declaration for this project. Keep `go test ./cli/...` or an
  # equivalent wrapper in root validation until nested grader execution lands.
  - name: tests
    run: go test ./...
```

Desktop example:

```yaml
# desktop/.syrus.yml
preview:
  setup:
    - npm ci
  start: npm run dev -- --host 0.0.0.0 --port $PORT
  health_check: /

grade:
  # Graph declarations for this project. Keep executable desktop validation in
  # the root `grade:` plan until nested grader execution lands.
  - name: desktop-typecheck
    run: npm run typecheck
  - name: package-smoke
    run: npm run build
    phases: [landing]
```

iOS example:

```yaml
# apps/ios/.syrus.yml
grade:
  # Graph declaration for this project. Keep the executable xcodebuild wrapper
  # in root validation until nested grader execution lands.
  - name: swift-tests
    run: xcodebuild test -scheme MobileApp -destination 'platform=iOS Simulator,name=iPhone 15'
    phases: [landing, ci]
    timeout_minutes: 30

coverage:
  sources:
    - artifact: build/reports/coverage.lcov
      format: lcov
  threshold:
    lines: 75
```

Android example:

```yaml
# apps/android/.syrus.yml
grade:
  # Graph declarations for this project. Keep executable Gradle wrappers in
  # root validation until nested grader execution lands.
  - name: unit-tests
    run: ./gradlew testDebugUnitTest
    phases: [review, landing]
  - name: assemble
    run: ./gradlew assembleDebug
    phases: [landing, ci]
```

Keep actual validation in the root file while adopting Level 1:

```yaml
# /.syrus.yml
grade:
  - name: web-typecheck
    run: npm --prefix apps/web run typecheck
    when_files_changed: ["apps/web/**"]
  - name: cli-tests
    run: go test ./cli/...
    when_files_changed: ["cli/**"]
  - name: android-unit-tests
    run: ./gradlew :apps:android:testDebugUnitTest
    when_files_changed: ["apps/android/**"]
```

Stay at Level 1 when directory scoping and legacy commands are clear enough.
Many medium monorepos never need explicit targets, and they should not move
validation out of the root plan until Syrus executes nested graders directly.

## Operator Checklist

Use this checklist when reviewing a repository that has moved beyond a single
root `.syrus.yml`:

- **Project boundaries**: each operator-facing app or product that needs its
  own preview, coverage policy, checkout hook, or review criteria has a nested
  `.syrus.yml` with a recognizable `project.label`. Shared libraries can be
  targets without becoming projects when they do not need their own operator
  surface.
- **Implementation setup**: root `prepare:` remains the automatic baseline.
  Nested `prepare:` entries become explicit prepare targets. Implementation
  agents see them as `Target prepare options` and must request one with
  `run_target_prepare(label:, reason:)` when they need that project-specific
  environment.
- **Checkout hooks**: root `hooks.post_checkout` always runs after `syrus
  checkout`; nested hooks run only for affected projects, with an all-project
  fallback when the CLI cannot compute the diff. Keep local-machine setup here,
  not agent sandbox setup.
- **Visual review and previews**: put each product's `preview:` and
  `visual_review:` next to the project that owns it. Operators and visual
  review agents should choose among affected preview-capable projects rather
  than starting an unrelated root preview.
- **Adversarial review**: root criteria are repo-wide. Nested criteria are
  unioned only for affected projects. Use nested criteria for project-specific
  contracts, not for generic repository rules that every review should see.
- **Coverage**: root coverage is repository-wide. Nested coverage is scoped to
  affected projects, with artifact paths resolved relative to the declaring
  `.syrus.yml`. Make sure the grader that runs for that project actually
  produces the configured artifact.
- **Target health**: a target-health skip means Syrus found a healthy proof for
  the target's current input, command, and environment fingerprints. If a skip
  looks wrong, inspect the Job Target Graph explanation before changing code;
  the usual fix is a missing or too-narrow `sources`, `when_files_changed`, or
  `deps:` declaration.

None of these surfaces performs magical project inference. If a project, target,
dependency edge, preview, coverage source, CI mapping, or hook matters, declare
it in `.syrus.yml` or import it through a trusted build-system provider.

## Root-Only To Nested Config Checklist

Use this checklist when converting a repository from root-only graders to
project-aware configuration. The compatibility goal is to keep the existing
validation surface intact while adding project metadata in small, reversible
steps.

1. **Freeze the current root contract.** Keep the root `.syrus.yml` and confirm
   which root `prepare:`, `grade:`, `coverage:`, `preview:`, `deploy:`, and
   `deployment_stages:` entries are protecting review, landing, CI, and release
   tracking today.
2. **Choose only real project boundaries.** Add nested `.syrus.yml` files for
   apps, CLIs, mobile packages, desktop clients, or other products an operator
   would naturally preview or reason about separately. Do not add a file just
   because a directory contains a package manifest.
3. **Move operator-facing metadata first.** Put project-specific `project:`,
   `preview:`, `visual_review:`, `adversarial_review.criteria`, `coverage:`,
   and `hooks.post_checkout` next to the project that owns them.
4. **Keep executable validation at the root.** Add nested `grade:` entries as
   graph declarations and dependency-analysis hints, but leave critical review,
   landing, and CI commands in the root `grade:` plan until nested-grader
   execution policy lands.
5. **Use root wrapper commands during the transition.** Scope root graders with
   `when_files_changed` and call project commands through package-aware
   wrappers such as `npm --prefix apps/web run typecheck`, `go test ./cli/...`,
   or `./gradlew :apps:android:testDebugUnitTest`.
6. **Add explicit targets only when they explain something.** Use `targets:`
   for shared libraries, generated contracts, prepare actions, or dependency
   edges that affect selection, target-health reuse, or graph debugging.
7. **Verify the compiled graph.** Inspect the target graph UI/API after each
   stage. If a target ran, skipped, or reused health unexpectedly, look for
   missing or too-narrow `sources`, `when_files_changed`, `deps:`, or
   `ci_checks` declarations.
8. **Leave deployment scoped to the repository.** Keep `deploy:` and
   `deployment_stages:` in the root file. Nested deployment stages are rejected
   in this release, and project-scoped deployment workflows remain an open
   design area.

Before:

```yaml
# /.syrus.yml
prepare:
  - npm ci

preview:
  start: npm --prefix apps/web run dev -- --host 0.0.0.0 --port $PORT
  health_check: /

coverage:
  sources:
    - artifact: apps/web/coverage/lcov.info
      format: lcov

grade:
  - name: web-typecheck
    run: npm --prefix apps/web run typecheck
    when_files_changed: ["apps/web/**"]
  - name: cli-tests
    run: go test ./cli/...
    when_files_changed: ["cli/**"]
```

After, keep the root validation commands that still guard workflows:

```yaml
# /.syrus.yml
prepare:
  - npm ci

grade:
  - name: web-typecheck
    run: npm --prefix apps/web run typecheck
    when_files_changed: ["apps/web/**"]
  - name: cli-tests
    run: go test ./cli/...
    when_files_changed: ["cli/**"]
```

Then add project metadata and graph declarations next to the project:

```yaml
# apps/web/.syrus.yml
project:
  id: web
  label: Web App
  kind: web_app

preview:
  setup:
    - npm ci
  start: npm run dev -- --host 0.0.0.0 --port $PORT
  health_check: /

visual_review:
  enabled: true
  when_files_changed:
    - "src/**/*.tsx"
    - "src/**/*.css"

coverage:
  sources:
    - artifact: coverage/lcov.info
      format: lcov
  threshold:
    lines: 75

grade:
  # Graph declaration for this project. Keep executable protection in the
  # root `grade:` plan until nested grader execution lands.
  - name: typecheck
    run: npm run typecheck
    when_files_changed:
      - "src/**/*.ts"
      - "src/**/*.tsx"
```

And declare a non-previewable project only when its target relationships are
useful:

```yaml
# cli/.syrus.yml
project:
  id: cli
  label: CLI
  kind: cli

targets:
  - name: sources
    kind: binary
    sources: ["**/*.go"]

grade:
  # Graph declaration. The root `cli-tests` grader remains the executable
  # workflow check during staged adoption.
  - name: tests
    run: go test ./...
    deps: [":sources"]
```

## Level 2: Explicit Projects And Executable Targets

Move to Level 2 when implicit directory-derived projects or legacy sections no
longer explain the real relationships.

Use `project:` to name the operator-facing boundary. Use `targets:` to name
execution graph nodes, source scopes, and dependencies. A project answers "what
should an operator recognize or preview?" A target answers "what files and
commands affect what?"

The same runtime caveat applies here: explicit targets and nested legacy
graders can describe executable project checks before every workflow path knows
how to materialize them. Until that execution policy exists, wire critical
review/landing/CI validation through root `grade:` entries that depend on the
explicit targets.

```yaml
# desktop/.syrus.yml
project:
  id: desktop
  label: Desktop App
  kind: desktop_app

targets:
  - name: renderer
    kind: library
    sources:
      - "src/**/*.ts"
      - "src/**/*.tsx"

  - name: main-process
    kind: binary
    sources:
      - "electron/**/*.ts"
    deps: [":renderer"]

  - name: node-deps
    kind: prepare
    run: npm ci

grade:
  - name: typecheck
    run: npm run typecheck
    deps:
      - ":node-deps"
      - ":renderer"
      - ":main-process"
```

Shared API/client code example:

```yaml
# shared/api/.syrus.yml
project:
  id: shared-api
  label: Shared API Contract
  kind: library

targets:
  - name: schema
    kind: library
    sources:
      - "openapi/**/*.yaml"
      - "proto/**/*.proto"

  - name: generated-clients
    kind: generator
    run: npm run generate-clients
    sources:
      - "openapi/**/*.yaml"
      - "proto/**/*.proto"
    deps: [":schema"]
```

Then products can point at that shared target:

```yaml
# apps/web/.syrus.yml
project:
  id: web
  label: Web App
  kind: web_app

targets:
  - name: app
    kind: application
    sources: ["src/**"]
    deps: ["//shared/api:schema"]

grade:
  - name: contract-tests
    run: npm run test:contracts
    deps:
      - ":app"
      - "//shared/api:schema"
```

```yaml
# apps/android/.syrus.yml
project:
  id: android
  label: Android App
  kind: android_app

targets:
  - name: app
    kind: application
    sources: ["app/src/**"]
    deps: ["//shared/api:schema"]

grade:
  - name: api-client-tests
    run: ./gradlew testDebugUnitTest
    deps:
      - ":app"
      - "//shared/api:schema"
```

Mixed-product layout example:

```text
.
|-- .syrus.yml
|-- apps
|   |-- web/.syrus.yml
|   |-- ios/.syrus.yml
|   `-- android/.syrus.yml
|-- desktop/.syrus.yml
|-- cli/.syrus.yml
`-- packages
    |-- api-contract/.syrus.yml
    `-- ui/.syrus.yml
```

In a layout like this, keep the root file small:

```yaml
# /.syrus.yml
prepare:
  - mise install

targets:
  - name: api-contract
    kind: library
    sources: ["packages/api-contract/**"]

grade:
  - name: repo-shape
    run: bin/check-repo-shape
    phases: [review, landing, ci]
  - name: web-contract-tests
    run: npm --prefix apps/web run test:contracts
    when_files_changed:
      - "apps/web/**"
      - "packages/api-contract/**"
    deps: [":api-contract"]
```

Root graders are repository-wide because they are declared at the repository
root. A sophisticated monorepo should usually keep only true whole-repository
invariants there, such as migration collision checks, generated baseline
checks, security policy checks, or config lint.

## Level 3: Imported Buck/Bazel-Style Graphs With Syrus Overlays

Move to Level 3 when an existing build system already owns the precise graph.
Do not copy thousands of Buck, Bazel, Pants, Nx, or Turbo relationships into
`.syrus.yml` by hand. Import them through a build-system graph provider and
layer Syrus-specific workflow metadata on top.

```yaml
# /.syrus.yml
target_graph:
  imports:
    - provider: bazel
      failures: strict
      config:
        query: //...
```

The imported graph is the structural base. The provider owns imported target
labels, source scopes, kinds, commands, and dependency edges. Syrus overlays
should stay narrow:

```yaml
# apps/web/.syrus.yml
targets:
  - name: bundle
    phases: [review, landing]
    required: true
    timeout_minutes: 20

grade:
  - name: web-build
    run: bazel build //apps/web:bundle
    deps: ["//apps/web:bundle"]
    phases: [landing, ci]
```

Use overlays for:

- Workflow phases, requiredness, and timeouts.
- Syrus-only prepare targets.
- Syrus-only graders with JUnit output, inherited-failure policy, or custom
  reporting.
- Preview, visual review, adversarial review, coverage, and local checkout
  hooks.
- Operator-facing project labels that build-system labels do not express well.

Do not use overlays to redefine imported structure. If the build system says
`//apps/web:bundle` has certain sources and dependencies, Syrus should treat
that as the source of truth.

## When Not To Add Explicit Targets

Explicit targets are most useful when they name relationships that affect
selection, caching, or operator explanations. Avoid them when they only add
ceremony.

Do not add an explicit target when:

- A root legacy `grade:` entry with `when_files_changed` is enough for actual
  validation.
- A nested legacy `grade:` entry already documents the intended project target
  for graph diagnostics, and no other target needs to depend on a named source
  node yet.
- The command has no meaningful dependency relationship.
- The target would have the same source glob as the grader and no dependents.
- The repository changes too quickly for target names to remain stable.
- The build system already owns the graph and should be imported instead.
- A broad landing check is intentionally supposed to run for every change.

Prefer this for a simple web package:

```yaml
# apps/web/.syrus.yml
grade:
  - name: typecheck
    run: npm run typecheck
    when_files_changed: ["src/**"]
```

Over this:

```yaml
# apps/web/.syrus.yml
targets:
  - name: source
    kind: library
    sources: ["src/**"]

grade:
  - name: typecheck
    run: npm run typecheck
    deps: [":source"]
```

The explicit target becomes worthwhile only when another target also depends
on `:source`, or when the name makes target-health reuse and graph debugging
clearer.

## A Conservative Rollout Plan

1. Start at Level 0 and make root behavior reliable.
2. Add Level 1 nested `.syrus.yml` files for one or two obvious project
   boundaries.
3. Move project previews, visual review, coverage, and checkout hooks into
   those nested files.
4. Add nested grader entries as graph declarations, while keeping executable
   validation in the root `grade:` plan.
5. Remove or narrow root graders only after nested grader execution is
   supported and the project checks are proven.
6. Add Level 2 targets for shared libraries, generated clients, and prepare
   actions that more than one executable target depends on.
7. Adopt Level 3 imports only when a real build graph exists and is trusted.

At every level, verify the compiled graph in the target graph UI or API. The
useful question is not "does every folder have a target?" It is "can an
operator see why Syrus selected, skipped, cached, previewed, or graded this
work?" When the answer is unclear, use the troubleshooting guide in
`target_graph.md` for target selection, target-health reuse, preview ambiguity,
missed-edge events, and common configuration fixes.
