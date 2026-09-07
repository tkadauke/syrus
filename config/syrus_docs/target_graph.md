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

### The `builder` kind is reserved, not compiled

`TargetGraph::Target::KINDS` already lists `builder` alongside
`formatter`/`generator`/`grader`/`prepare` — DOC-20's Core Model names it as
one of the eventual target kinds — but no `.syrus.yml` primitive compiles
into it yet. There is no `build:` (or equivalent) legacy config section
today, and none of the runtime pipelines this compiler mirrors
(`RepoPrepPlan`, `Steps::Format`, `Steps::Generate`, `RepoGradePlan`) have a
build-command concept to carry over. Constructing a `TargetGraph::Target`
with `kind: "builder"` directly is supported by the model — the kind exists
precisely so a later compiler change and this graph model don't need to land
together — but `TargetGraph::Compiler` never produces one today.

Until a `build:` section exists, model an explicit build step as whichever
existing primitive matches its role: a `grade:` entry if a failed build
should fail the workflow like any other required check, or a `generated:`
entry if the build produces checked-in output that `Steps::Generate` should
keep in sync (see "Shared generated clients: targets, not projects" below).
A future `build:` section, if one is added, should compile the same way
`grade:`/`formatters:`/`generated:` already do: one `kind=builder` target per
declared entry, under whichever project (root or nested) declared it, with
the same directory-based `source_scope` defaulting described in
"Affected-file scope defaults" below.

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

The walk always excludes VCS internals (`.git`) and the workspace's own
scratch directory (`.syrus`) — neither is ever real project configuration,
regardless of what the repository's `.gitignore` says. Everything else is
excluded purely by asking git whether the containing directory is gitignored
(a single batched `git check-ignore --stdin -z` call, not one process per
candidate): a nested `.syrus.yml` sitting in a gitignored directory
(`node_modules/`, `vendor/`, `dist/`, a custom build-output directory, or
anything else the repository ignores) can never be committed, so it can
never be an effective declaration. A workspace that isn't a git checkout (or
has no `git` binary available) degrades to treating nothing as gitignored
rather than raising. Discovered directories are always returned sorted, so
nested config is always compiled in the same deterministic order regardless
of filesystem iteration order — and always after the root `.syrus.yml`,
which `TargetGraph::Compiler` compiles first.

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

## Common monorepo layouts

The pieces above — implicit/explicit `project:`, nested `.syrus.yml`
discovery, and per-declaration file-selector scoping — compose into a small
set of concrete layouts. None of the examples below need the still-unbuilt
`targets:` block or cross-project dependency edges (DOC-20 "Adoption Levels"
2/3); everything here works with what's implemented today.

The invariant that shapes every layout: **one `.syrus.yml` file compiles
into exactly one project.** There is no way for two files to share a
project id, and no parent/child relationship between projects. Grouping
several directories into a single operator-facing project means putting one
`.syrus.yml` in their common ancestor and scoping individual sections to
subdirectories with relative globs — not putting a `.syrus.yml` in each
subdirectory and hoping they merge.

### One root app, no subprojects (Level 0)

The common case, and the only one most repositories ever need: a single
root `.syrus.yml`, no nested files, no `project:` block. Everything compiles
under the implicit root project `//:repo`.

```yaml
# /.syrus.yml
prepare:
  - bundle install
grade:
  - name: rspec
    run: bin/rspec-fast
```

### One folder per project

The most direct nested-config mapping: each independently developed
subproject gets its own `.syrus.yml`, and nested discovery gives each one
its own implicit project keyed off its directory.

```yaml
# /cli/.syrus.yml
prepare:
  - mise install && go mod download
grade:
  - name: tests
    run: go test ./...
```

```yaml
# /web/.syrus.yml
prepare:
  - npm ci
grade:
  - name: tests
    run: npm test
```

This compiles to two directory-scoped projects (`cli`, `web`) alongside the
implicit root project, each with its own targets (`//cli:grade/tests`,
`//web:grade/tests`) and directory-relative affected-file scope by default
(see "Affected-file scope defaults" above). No `project:` block is needed
unless the directory-derived id or label isn't the right operator-facing
name.

### Frontend and backend as one product project

A layout where `frontend/` and `backend/` are reviewed and released as one
product, not two independent boundaries: don't put a `.syrus.yml` in each —
that produces two projects, and the one-file-one-project invariant above
means there's no way to merge them back afterward. Instead, put a single
`.syrus.yml` in their common parent directory and scope each grader to its
own subtree with a relative glob:

```yaml
# /web-app/.syrus.yml
project:
  id: web-app
  label: Web App

grade:
  - name: frontend-tests
    run: npm --prefix frontend test
    when_files_changed:
      - "frontend/**"
  - name: backend-tests
    run: bin/rspec-fast
    when_files_changed:
      - "backend/**"
```

Both graders compile under the single `web-app` project
(`//web-app:grade/frontend-tests`, `//web-app:grade/backend-tests`); their
`when_files_changed` globs resolve relative to `/web-app` (see "Affected-file
scope defaults" above), so `frontend/**` here means `web-app/frontend/**`
repo-relative, not the whole repository.

### Desktop project with renderer, main process, packaging, and updater

Same pattern — one project, several independently scoped targets. A desktop
app's constituent parts (renderer, Electron main process, packaging,
auto-updater) are one operator-facing boundary (one preview, eventually one
release), not four:

```yaml
# /desktop/.syrus.yml
project:
  id: desktop
  label: Desktop App
  kind: desktop_app

formatters:
  - command: npx prettier --write
    files: "renderer/**/*.ts"

grade:
  - name: renderer-typecheck
    run: npm run typecheck
    when_files_changed: ["renderer/**"]
  - name: main-typecheck
    run: npm run typecheck:main
    when_files_changed: ["main/**"]
  - name: packaging-smoke
    run: bin/package-smoke-test
    when_files_changed: ["packaging/**", "main/**"]
  - name: updater-smoke
    run: bin/updater-smoke-test
    when_files_changed: ["updater/**"]
```

All four graders share the `desktop` project; each is wired only to the
subtree it actually validates. There is no `targets:` block yet to declare
`renderer`/`electron`/`packaging`/`updater` as their own dependency-linked
nodes (DOC-20 Level 2) — until that lands, per-subtree scoping via
`when_files_changed`/`files` is the available tool for keeping them from
all running on every unrelated change inside the project.

### Plugin ecosystems where many targets belong to one project

A plugin host repository (many `plugins/<name>/` directories) whose plugins
are graded individually but don't need their own preview or operator-facing
identity: one `.syrus.yml` at the plugins root, one grader per plugin, one
project.

```yaml
# /plugins/.syrus.yml
project:
  id: plugins
  label: Plugins

grade:
  - name: claude-agent-tests
    run: bundle exec rspec plugins/claude_agent
    when_files_changed: ["claude_agent/**"]
  - name: github-source-tests
    run: bundle exec rspec plugins/github_source
    when_files_changed: ["github_source/**"]
```

If a particular plugin does need its own operator boundary — its own
preview, its own coverage policy — give that one plugin its own nested
`.syrus.yml` instead. It becomes its own project sitting alongside
`plugins`, not nested under it: there is no parent/child relationship
between projects today, only independent ones.

### Shared generated clients: targets, not projects

A generated artifact (an API client, a schema dump, a protobuf-generated
package) is a target, not a project — it has no operator-facing identity of
its own; it just needs to be regenerated when its source changes. Declare it
under the `generated:` section of whichever project's `.syrus.yml` owns the
source of truth, not as its own nested `.syrus.yml`:

```yaml
# /backend/.syrus.yml
generated:
  - command: bin/rails runner scripts/generate_api_client.rb
    sources: "app/controllers/api/**/*.rb"
    generates:
      - "packages/api-client/**"
```

This compiles one `//backend:generate/0` target; `packages/api-client/`
never becomes its own project or gets its own `.syrus.yml`, even though its
generated output lives outside `backend/`.

### iOS and Android as separate projects, sharing an API

Two platform-specific apps that both consume the same API surface: give each
its own nested `.syrus.yml` — its own operator boundary, its own future
preview/coverage policy — and, if the API lives in its own directory, give
that its own project too:

```yaml
# /ios/.syrus.yml
project:
  id: ios
  kind: ios_app
grade:
  - name: xcode-tests
    run: xcodebuild test -scheme App
```

```yaml
# /android/.syrus.yml
project:
  id: android
  kind: android_app
grade:
  - name: gradle-tests
    run: ./gradlew test
```

```yaml
# /api/.syrus.yml
project:
  id: api
grade:
  - name: contract-tests
    run: bin/rspec-fast spec/api
```

What this layout can't yet express: a real dependency edge saying "ios and
android depend on api," so that an api-only change automatically re-runs
ios's and android's graders too. Cross-project dependency edges are DOC-20
Level 2 (explicit `targets:` plus dependency edges) and don't exist in the
current implementation. Until they do, a project that needs to react to a
shared directory's changes has to say so itself, by widening its own
`when_files_changed`:

```yaml
# /ios/.syrus.yml (same project, wider trigger)
grade:
  - name: xcode-tests
    run: xcodebuild test -scheme App
    when_files_changed: ["ios/**", "api/**"]
```

### When to use implicit projects vs. explicit `project:`

Stay implicit (no `project:` block) when the directory-derived id and label
already are what an operator would call that part of the repository — most
one-folder-per-project layouts need nothing else.

Declare `project:` when:

- the directory path would produce an ugly or colliding id (`apps/desktop`
  derives `apps-desktop`; declare `id: desktop` if `desktop` doesn't collide
  with anything else)
- the directory name isn't what an operator would call the thing (`svc` ->
  `label: Payments Service`)
- several directories are deliberately merged under one `.syrus.yml`
  (frontend+backend, a desktop app's renderer/main/packaging/updater, a
  plugin ecosystem) and need a stable id/label independent of the file's own
  path
- recording a `kind` (`desktop_app`, `ios_app`, `android_app`) is useful for
  later project-aware features, even though nothing reads it yet

Don't reach for `project:` just to "declare structure" preemptively — an
unconfigured, directory-derived project is a fully valid, permanent end
state, not a placeholder waiting to be made explicit.

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
