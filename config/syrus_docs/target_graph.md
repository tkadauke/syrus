# Target Graph Compilation

Syrus has an internal `TargetGraph` model (`app/services/target_graph.rb` and
`app/services/target_graph/`) that represents a repository's configuration as
canonically labeled `Project`s and `Target`s (`//package:name`, e.g.
`//:repo`, `//:grade/tests`, `//cli:grade/tests`). It exists so later
project-aware workflow work has one real graph to build on instead of a model
nothing populates.

**This is internal plumbing, not a feature yet.** `TargetGraph::Compiler`
reads a repository's root `.syrus.yml` legacy sections (`prepare`,
`formatters`, `generated`, `grade`) and compiles them into targets under an
implicit root project (`//:repo`), then does the same for every nested
`.syrus.yml` it discovers below the root (see "Nested `.syrus.yml`
discovery" below). Nothing in the runtime prepare, format, generate, or
grader pipelines reads from the compiled graph — root or nested — and
compiling it does not change what those pipelines run. Explicit `targets:`
declarations and build-system plugin import (later adoption levels in
`DOC-20`) do not exist yet — do not describe them as available. The
`project:` primitive described below does exist, but it only names/labels a
project; it carries no targets of its own yet.

## Projects vs. targets

DOC-20 draws a hard line between the two graph concepts, and it matters when
deciding whether something belongs in `project:` or in a future `targets:`
block:

- **Project** — an operator-facing *workflow* boundary. A project answers
  "what would an operator call this part of the repository," and later
  becomes the thing that decides which preview to start, which hooks to run
  on checkout, and which visual review/coverage policy applies. Declaring a
  project does not run anything.
- **Target** — an execution graph node: a grader, formatter, generator,
  prepare action, or (eventually) a build node. Targets answer "what
  command runs, depending on what." Every executable thing Syrus already
  runs from `.syrus.yml` (`grade:`, `formatters:`, `generated:`, `prepare:`)
  compiles into targets, whether or not the file that declared them also
  declares a `project:` block.

A `.syrus.yml` file's `project:` block just gives its implicit project (the
root project for the root file, or the directory-derived project for a
nested file) a stable identity — it does not change which targets that file
compiles into, or what those targets do.

## Explicit `project:`

Level 0/1 (root-only repos, and nested `.syrus.yml` files with no `project:`
block) need no configuration: every project is implicit, with an id/label
derived from the file's position (`repo` for the root, the directory path
for a nested file — e.g. `apps/desktop/.syrus.yml` implies id
`apps-desktop`, label `apps/desktop`).

An explicit `project:` block overrides that derivation for layouts where the
default isn't the right operator-facing boundary — a directory-derived id
that collides with another directory, or a label an operator would rather
see than a raw path:

```yaml
# desktop/.syrus.yml
project:
  id: desktop
  label: Desktop App
  kind: desktop_app
```

All fields are optional and independently overridable:

- `id` — must match `[A-Za-z0-9_-]+`. Overrides the directory-derived id.
  Two files (nested or root) that resolve to the same id — whether by
  directory derivation, explicit declaration, or one of each — raise
  `TargetGraph::ValidationError` naming both owning files; nothing is
  silently merged or overwritten.
- `label` — free-form operator-facing display text. Defaults to the
  directory path (nested) or `"Repository"` (root).
- `kind` — free-form, e.g. `desktop_app`. No default.
- `path` — overrides the project's scope metadata, which otherwise defaults
  to the directory containing the file. This is metadata only in the
  current implementation slice: it does not change which directory's files
  compile into this file's targets, and does not affect target labels
  (`//<package>:<name>` package segments always match the file's actual
  directory) — see "Projects vs. targets" above for why label/kind/path on
  a project never touches target compilation.

The root `.syrus.yml` may also declare `project:`, but only to customize
`label`/`kind` — the root project's `id` (`repo`) and `path` (empty) are
structural, since there is exactly one repository root. An explicit
`project.id`/`project.path` in the root file that disagrees with that raises
`TargetGraph::ValidationError` naming the root config, the same way a
nested id collision does.

## Nested `.syrus.yml` discovery

`TargetGraph::NestedConfigDiscovery` (`app/services/target_graph/nested_config_discovery.rb`)
walks a workspace below its root looking for `.syrus.yml` files in
subdirectories. A nested `.syrus.yml` is discovered purely by its literal
presence on disk — discovery never infers a project boundary from
`package.json`, `go.mod`, Rails directory conventions, or any other
repository-structure signal.

The walk excludes directories that are never real project configuration: VCS
internals (`.git`), the workspace's own scratch directory (`.syrus`), and
common dependency/vendor caches and build outputs (`node_modules`, `vendor`,
`.bundle`, `tmp`, `log`, `coverage`, `dist`, `build`, `.next`, `.cache`).
Discovered directories are always returned sorted, so nested config is always
compiled in the same deterministic order regardless of filesystem iteration
order — and always after the root `.syrus.yml`, which `TargetGraph::Compiler`
compiles first.

Each discovered nested `.syrus.yml` becomes its own directory-scoped
`Project` (id and label derived from its relative path by default, e.g.
`cli` for `cli/.syrus.yml`, `apps-desktop` for `apps/desktop/.syrus.yml` —
see "Explicit `project:`" above for overriding that derivation), and its
`prepare`/`formatters`/`generated`/`grade` sections compile into targets
under that project the exact same way the root file's sections do —
`//cli:prepare`, `//cli:format/0`, `//cli:grade/tests`, and so on. Root
`.syrus.yml` compilation is completely unaffected: a repository with no
nested config compiles exactly as it did before nested discovery existed.

### Affected-file scope defaults

`TargetGraph::Compiler#scoped_source_scope` gives every compiled
formatter/generator/grader target's `source_scope` (its affected-file
scope — a `formatter.files`, `generated.sources`, or grader
`when_files_changed` selector) a default based on where it was declared,
not on whether it's the root file:

- A declaration with an explicit file selector has that selector's globs
  resolved relative to the directory of the `.syrus.yml` that declared it
  — `files: ["**/*.go"]` in `cli/.syrus.yml` becomes `source_scope:
  ["cli/**/*.go"]`, not the literal (repo-rooted) `**/*.go`.
- A declaration with no explicit selector at all defaults to that entire
  directory — a nested `cli/.syrus.yml` grader with no `when_files_changed`
  gets `source_scope: ["cli/**/*"]` instead of the unscoped `[]` a legacy
  root grader with no selector gets.

The root `.syrus.yml`'s directory is the repository root, so both rules
collapse to the existing repo-wide behavior there: an explicit root
selector resolves unchanged (no `//`-rooted prefix to add), and a root
declaration with no selector stays unscoped (`source_scope: []`, meaning
"always runs," the same as before this default existed). This falls out of
resolving every selector relative to its own directory — there is no
dedicated "is this the root config" branch. Root and nested scopes compose
additively in the same graph: a repo-wide root grader and a
directory-scoped nested grader coexist with their own independent
`source_scope`, neither widening nor narrowing the other. `prepare:` is
never routed through this: it has no file-selector primitive and stays the
unconditional pre-implementation baseline in both the root and nested
case (see "Prepare Semantics" in DOC-20).

A broken nested `.syrus.yml` is reported, never silently dropped, but the two
ways it can be broken have different severity:

- **Invalid YAML/config in one nested file** (the same errors
  `SyrusYml::ParseError` already reports for the root file) is lenient: only
  that file's project and targets are skipped, compilation continues for the
  root and every other nested file, and the problem shows up in
  `Diagnostics#error` naming the offending file's path (e.g.
  `cli/.syrus.yml: formatters: must be an array`) — this never raises from
  `TargetGraph::Compiler#compile` or `#diagnose`.
- **A structural collision across files** — two different nested
  directories whose paths reduce to the same project id (a directory
  literally named `foo-bar` alongside a nested `foo/bar/.syrus.yml`, both of
  which need to become project id `foo-bar`), or any other pair of files
  (nested or root) that resolve to the same id once explicit `project.id`
  overrides are taken into account — is a real graph-construction problem
  and raises `TargetGraph::ValidationError` naming both files, the same way
  any other duplicate project/target declaration does.
  `TargetGraph::Compiler#compile` propagates this; `#diagnose` catches it
  (matching its documented never-raises contract) and reports it through
  `Diagnostics#error` instead.

## Monorepo layout patterns

DOC-20 lists a handful of representative monorepo layouts to prove the
`project:` primitive isn't just "one folder equals one project." Every
pattern below uses only what's implemented today — nested `.syrus.yml`
discovery, the `project:` id/label/kind/path fields, and each legacy
section's own file-glob scoping (`formatters[].files`, `generated[].sources`,
`grade[].when_files_changed`). None of it relies on explicit `targets:` or
dependency edges (DOC-20 "Level 2/3"), which don't exist yet.

The rule that decides every layout below: **one `.syrus.yml` file compiles
into exactly one project.** Two files can never share a project — two nested
files (or a nested file and the root) that resolve to the same `project.id`
fail compilation naming both files rather than merging (see "Nested
`.syrus.yml` discovery" above). So "how many projects does this repo have"
is really "how many `.syrus.yml` files does it have," and laying out a
project boundary that spans more than one subdirectory means putting a
single file where those subdirectories meet and scoping its entries with
globs — not adding a nested file inside each one.

### One root app, no subprojects

No config beyond the root `.syrus.yml`. Everything compiles into the
implicit root project (`//:repo`); an explicit `project:` block here is
optional, and only useful to override the default `"Repository"` label.

```yaml
# .syrus.yml
prepare:
  - bundle install
grade:
  - name: rspec
    run: bin/rspec-fast
```

### One folder per project

The common case: give each top-level directory its own `.syrus.yml`. Nested
discovery turns each into its own implicit project (id/label derived from
its path), no `project:` block required.

```yaml
# api/.syrus.yml
grade:
  - name: tests
    run: bin/rspec-fast

# web/.syrus.yml
grade:
  - name: tests
    run: npm test
```

Compiles to `//api:grade/tests` under implicit project `api` and
`//web:grade/tests` under implicit project `web`.

### Frontend and backend as one product project

Don't create `frontend/.syrus.yml` and `backend/.syrus.yml` — per the rule
above, two files can never resolve to the same project, so that layout would
always produce two projects, not one. Instead declare a single file at the
directory that contains both, and scope each grader to its half with its own
glob:

```yaml
# app/.syrus.yml
project:
  id: app
  label: App
  kind: web_app

grade:
  - name: backend-tests
    run: bin/rspec-fast
    when_files_changed: ["backend/**"]
  - name: frontend-tests
    run: npm test
    when_files_changed: ["frontend/**"]
```

`app/backend/` and `app/frontend/` get no `.syrus.yml` of their own.

### Desktop project with renderer, Electron main, packaging, and updater targets

Same shape as above, one level in: a single `desktop/.syrus.yml` with one
`project:` block and several grade/formatter entries, each scoped to its own
sub-area:

```yaml
# desktop/.syrus.yml
project:
  id: desktop
  label: Desktop App
  kind: desktop_app

formatters:
  - command: npx eslint --fix
    files: ["renderer/**/*.ts", "renderer/**/*.tsx"]

grade:
  - name: renderer-typecheck
    run: npm --prefix renderer run typecheck
    when_files_changed: ["renderer/**"]
  - name: main-typecheck
    run: npm --prefix electron run typecheck
    when_files_changed: ["electron/**"]
  - name: package
    run: npm run build:package
    when_files_changed: ["renderer/**", "electron/**", "package.json"]
  - name: updater-manifest
    run: bin/check-updater-manifest
    when_files_changed: ["updater/**"]
```

Renderer, Electron main, packaging, and the updater all stay part of one
operator-facing project even though they're four different subdirectories
with four different toolchains.

### Plugin ecosystems where many targets may belong to one project

If the plugins share one operator boundary (reviewed together, one coverage
policy), keep them as one project the same way: a single `plugins/.syrus.yml`
with one grade entry per plugin, each scoped to its own subdirectory.

```yaml
# plugins/.syrus.yml
project:
  id: plugins
  label: Plugins
  kind: plugin_ecosystem

grade:
  - name: claude_agent-tests
    run: bin/rspec-fast plugins/claude_agent
    when_files_changed: ["claude_agent/**"]
  - name: codex_agent-tests
    run: bin/rspec-fast plugins/codex_agent
    when_files_changed: ["codex_agent/**"]
```

If a plugin instead needs its own operator-facing boundary — its own
preview, its own coverage threshold — give it its own nested `.syrus.yml`
instead. That's "one folder per project" again, just applied one directory
deeper (`plugins/claude_agent/.syrus.yml`).

### Shared generated clients as targets but not projects

A generated client (an OpenAPI- or protobuf-generated SDK, for example) is a
target — the `generated:` entry that regenerates it, plus whatever grader
glob watches it — not a project: no operator picks it from a preview
selector or sets a coverage threshold on it by itself. Don't give it its own
nested `.syrus.yml`; declare it as a `generated:` entry in the project that
owns it:

```yaml
# api/.syrus.yml
generated:
  - command: buf generate --template buf.gen.yaml
    sources: "proto/**/*.proto"
    generates:
      - "clients/typescript/**"
      - "clients/go/**"
```

If more than one project consumes the generated output, repeat the relevant
`generated:` entry, or a `when_files_changed`/`sources` glob reaching into
the shared source directory, in each consuming project's own file — see the
next section for why that repetition is necessary today.

### iOS and Android as separate projects consuming shared API targets

Two nested files, one project each — this is "one folder per project" for
the platform-specific code:

```yaml
# ios/.syrus.yml
project:
  id: ios
  label: iOS
  kind: mobile_app

grade:
  - name: xctest
    run: bin/ios-test
    when_files_changed: ["ios/**", "shared/api/**"]

# android/.syrus.yml
project:
  id: android
  label: Android
  kind: mobile_app

grade:
  - name: gradle-test
    run: ./gradlew test
    when_files_changed: ["android/**", "shared/api/**"]
```

Because there's no dependency-edge primitive yet (DOC-20 "Level 2/3"), each
project has to name the shared API directory in its own
`when_files_changed` glob to be re-graded when it changes — Syrus doesn't
yet propagate "the shared target changed" from a shared target to the
projects that consume it.

### Implicit directory projects vs. explicit `project:`

- Use the implicit default (no `project:` block) whenever the directory name
  is already the right id and label — most one-folder-per-project layouts
  need nothing else.
- Declare `project.id` when two directories would otherwise derive colliding
  ids (a top-level `apps-mobile/` and a nested `apps/mobile/` both deriving
  id `apps-mobile`), or when the operator-facing boundary genuinely isn't
  one folder — frontend+backend, desktop's four sub-areas, a plugin
  ecosystem — and you're placing one file at the point where those
  subdirectories meet.
- Declare `project.label`/`project.kind` purely for a nicer operator-facing
  name even when the id would derive fine on its own (`apps/desktop` derives
  id `apps-desktop`, but the label "Desktop App" reads better).
- `project:` only ever applies to the one file that declares it. It cannot
  fuse two separately-discovered nested `.syrus.yml` files into one project
  — if a layout needs one project spanning several subdirectories, put a
  single file at their common point and scope its entries with globs instead
  of adding a nested file inside each subdirectory.

## Diagnostics

The `prepare` step compiles the workspace's target graph once per Run purely
for debuggability and logs a single low-noise summary line, e.g.:

```
[prepare] target graph: source=.syrus.yml targets=2 (//:grade/tests, //:repo)
```

For a repository with no `.syrus.yml` at all, `source` reads `none` and the
graph is just the implicit root target — one line, same as every other
`prepare` diagnostic (`source:`, `detected:`).

If the root `.syrus.yml` fails to parse (or, for a future explicit-target
graph, fails validation), the line instead names the owning config path and
the underlying error instead of silently compiling an empty graph:

```
[prepare] target graph compilation failed: .syrus.yml: formatters: must be an array
```

This never fails the `prepare` step or the workflow — `TargetGraph::Compiler.diagnose`
is diagnostics-only, matching the same non-fatal posture as `prepare`'s other
auto-detected diagnostics. The full structured result (source, owning config
path, compiled target labels, target/project counts, and any error) is also
recorded on the Workflow as the `target_graph_diagnostics` artifact for
tooling that wants it without re-parsing log lines.
