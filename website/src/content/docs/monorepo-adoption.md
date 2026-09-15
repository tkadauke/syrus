---
title: Monorepo Adoption
description: A staged guide for adopting project-aware .syrus.yml configuration in small repos and medium monorepos.
---

# Monorepo Adoption

Syrus's project-aware configuration is staged on purpose. Small repositories
can keep one root `.syrus.yml` forever. Medium monorepos can add nested project
configuration, explicit targets, and build-system imports only when those
steps make workflow behavior clearer or cheaper.

For field-level reference, see [Configuration](/docs/configuration). For the
compiled graph model, see the in-app Target Graph docs.

## The Adoption Rule

Do not model the whole repository on day one. Add the smallest amount of
configuration that makes Syrus's behavior easier to understand, faster to run,
or less ambiguous for operators.

Move up a level when a change in one directory should not boot or grade an
unrelated product, operators need to choose between multiple previewable apps,
shared code affects several products, or an existing build system already owns
the dependency graph.

Stay lower when the repository merely has several directories, one root grader
is fast and reliable, or a simple `when_files_changed` glob tells the truth.

## Level 0: Root `.syrus.yml` Only

Level 0 is the default for small repositories and early monorepos. Keep one
`.syrus.yml` at the repository root. Syrus preserves the existing behavior:
root `prepare`, `preview`, `visual_review`, `hooks`, `adversarial_review`,
`formatters`, `generated`, `grade`, `coverage`, `deploy`, and
`deployment_stages` remain repository-wide.

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

Internally, Syrus compiles this into the TargetGraph under the implicit root
project, with labels such as `//:repo`, `//:prepare`, and `//:grade/rspec`.
Operators do not need to care unless they open the target graph inspector.

Stay at Level 0 when the repo behaves like one product, root preview is the
only useful preview, root graders are cheap enough, and file-based grader skips
are enough.

Small app:

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

Small CLI:

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
separate apps, a CLI beside a web app, mobile apps with different checks, or
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

Web app:

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

CLI:

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

Desktop:

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

iOS:

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

Android:

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

## Level 2: Explicit Projects And Executable Targets

Move to Level 2 when implicit directory-derived projects or legacy sections no
longer explain the real relationships.

Use `project:` to name the operator-facing boundary. Use `targets:` to name
execution graph nodes, source scopes, and dependencies. A project answers what
an operator should recognize or preview. A target answers what files and
commands affect what.

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

Shared API/client code:

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

Products can point at that shared target:

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

Mixed-product layout:

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

Use overlays for workflow phases, requiredness, timeouts, Syrus-only prepare
targets, Syrus-only graders, previews, visual review, adversarial review,
coverage, local checkout hooks, and operator-facing project labels.

Do not use overlays to redefine imported structure. If the build system says
`//apps/web:bundle` has certain sources and dependencies, Syrus should treat
that as the source of truth.

## When Not To Add Explicit Targets

Explicit targets are most useful when they name relationships that affect
selection, caching, or operator explanations. Avoid them when they only add
ceremony.

Do not add an explicit target when a root legacy `grade:` entry with
`when_files_changed` is enough for actual validation, or when a nested legacy
`grade:` entry already documents the intended project target and no other
target needs to depend on a named source node yet. Also avoid explicit targets
when the command has no meaningful dependency relationship, the target would
have the same source glob as the grader and no dependents, names are too
unstable, the build system should be imported instead, or a broad landing check
is intentionally supposed to run for every change.

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

## Conservative Rollout

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
work?"
