# Target Graph Compilation

Syrus has an internal `TargetGraph` model (`app/services/target_graph.rb` and
`app/services/target_graph/`) that represents a repository's configuration as
canonically labeled `Project`s and `Target`s (`//package:name`, e.g.
`//:repo`, `//:grade/tests`, `//cli:grade/tests`). It exists so later
project-aware workflow work has one real graph to build on instead of a model
nothing populates.

`TargetGraph::Compiler`
reads a repository's root `.syrus.yml` legacy sections (`prepare`,
`formatters`, `generated`, `grade`) and compiles them into targets under an
implicit root project (`//:repo`), then does the same for every nested
`.syrus.yml` it discovers below the root (see "Nested `.syrus.yml`
discovery" below). `Steps::GraderFanout` reads the compiled graph through
`TargetGraph#affected`/`#affected_targets` to decide which root grader is
affected by the current diff: a grader is affected when it declares no
source scope at all (repo-wide, the legacy no-`when_files_changed`
default), when its own source scope (`when_files_changed`) matches a
changed file, or — transitively, through `deps:` — when a dependency
target's source scope matches a changed file (a dependency with an empty
source scope, such as the implicit root target every legacy declaration
depends on, never counts as a match on its own). Any transitive `prepare`
target still executes before that grader command — see "Prepare target
execution" below for how that's kept to once per workflow workspace.
`#affected`/
`#affected_targets` are kind-agnostic (`grader`, `formatter`, `generator`,
`builder`, ...) and work across the whole graph, root and nested projects
alike, so they're the one place this selection logic lives. Today
`Steps::GraderFanout` wires root graders through that selection, and
`Steps::BuilderFanout` wires explicit builder targets through it for
opportunistic main-branch warming. Nested explicit builder commands run from
their owning project directory; nested formatter/generator/grader runtime
materialization is still pending a separate execution policy. Grader fanout
logs both outcomes by name and target label — `[grader_fanout] selected rspec
(repo-wide (no source scope declared)) [//:grade/rspec]` / `... skipped
website-build (no matching files changed) [//:grade/website-build]` — so an
operator can see why a grader ran or didn't without reading `.syrus.yml`.
Formatter/generator runtime selection (`Steps::Format`/`Steps::Generate`) is
still legacy-config driven and root-only; their graph nodes carry dependency
metadata for diagnostics and later target-aware execution. Workflow
implementation agents also see the compiled prepare targets in their
environment snapshot and may run one explicitly through `run_target_prepare`
when they discover that a project-scoped dependency install is needed (see
"Agent-requested prepare targets" below).

Explicit `targets:` declarations are available for hand-authored dependency
nodes. Build-system plugin imports are also available, but only as explicit
repository declarations under `target_graph.imports`; Syrus never guesses
Buck/Bazel/Pants-style targets from repository structure on its own. When an
import is active, the imported Buck/Bazel/Pants graph is the precise base graph:
Syrus adds its workflow nodes and metadata on top, but it does not reinterpret
or replace imported dependency edges. The `project:` primitive described below
names/labels the project that owns a config file's targets.

## Adoption paths

DOC-20's target-graph model is intentionally staged. Repositories do not need
to jump from a root-only `.syrus.yml` to a fully explicit build graph in one
change:

1. **Root legacy config**: keep one root `.syrus.yml` with `prepare:`,
   `formatters:`, `generated:`, and `grade:`. Syrus compiles these existing
   sections into the implicit root project (`//:repo`) and synthetic targets
   such as `//:prepare`, `//:format/0`, `//:generate/0`, and
   `//:grade/rspec`.
2. **Nested legacy config**: add `.syrus.yml` files only in directories that
   are real operator-facing project boundaries. Each nested file gets its own
   implicit project and its legacy sections compile into that package's
   targets, with file selectors resolved relative to the declaring directory.
3. **Explicit project names**: add `project:` when the directory-derived id,
   label, or kind is not the right operator-facing identity. This renames the
   project boundary; it does not make commands run differently.
4. **Explicit targets**: add `targets:` when the repo needs reusable graph
   nodes or dependency edges that legacy sections cannot express clearly:
   libraries, applications, binaries, prepare actions, builders, repo checks,
   or shared generated artifacts. Existing legacy graders/formatters/generators
   can point at those nodes through `deps:`.
5. **Imported build-system graph**: add `target_graph.imports` when a build
   system such as Buck, Bazel, or Pants already owns the precise graph. The
   plugin import becomes the structural base graph; `.syrus.yml` remains useful
   for Syrus-only workflow metadata, prepare/check commands, and overlays on
   imported labels.

Each stage is a valid stopping point. A small repository can stay at stage 1
permanently. A monorepo with a handful of independent apps often stops at
stages 2-4. A repository whose build system already knows every dependency edge
should prefer stage 5 over copying that graph by hand into `.syrus.yml`.

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

## Explicit `targets:`

A config file can declare explicit target nodes. Relative dependency labels
(`:renderer`) resolve within the same `.syrus.yml` package; absolute labels
(`//desktop:renderer`) resolve from the repository root.

```yaml
targets:
  - name: renderer
    kind: library
    sources: ["src/**/*.ts", "src/**/*.tsx"]

  - name: deps
    kind: prepare
    run: npm ci

  - name: typecheck
    kind: grader
    run: npm run typecheck
    sources: ["src/**/*.ts", "src/**/*.tsx"]
    phases: [review, landing]
    required: true
    timeout_minutes: 10

grade:
  - name: legacy-typecheck
    run: npm run typecheck
    when_files_changed: ["src/**/*.ts", "src/**/*.tsx"]
    deps: [":renderer", ":deps"]
```

Supported target kinds are `default`, `library`, `binary`, `application`,
`formatter`, `builder`, `grader`, `prepare`, `generator`, and `repo_check`.
Dependencies use one edge only: `deps` (or the equivalent spelling
`dependencies`). Missing labels, duplicate labels, and dependency cycles are
reported as `TargetGraph::ValidationError` messages naming the target label
and owning `.syrus.yml` path where possible.

Explicit target fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | yes | — | Target name within the declaring package; the canonical label is `//package:name`. |
| `kind` | no | `library` | One of the supported target kinds above. |
| `sources` | no | — | Glob or array of globs, resolved relative to the declaring `.syrus.yml` directory. Absolute paths and `..` segments are rejected so a nested file cannot claim files outside its scope. `source_scope` is accepted as an alias. |
| `deps` | no | `[]` | Label string or array of label strings. `:name` resolves within the same package; `//package:name` is absolute. `dependencies` is accepted as an alias. |
| `run` / `command` | no | — | Shell command metadata for executable targets. Pure dependency nodes normally omit it. |
| `phases` | no | `[]` | Optional phase metadata for executable validation targets. Values use the grader phase vocabulary: `review`, `landing`, `ci`, `promotion`. |
| `required` | no | `false` | Optional requiredness metadata for executable validation targets. |
| `timeout_minutes` | no | — | Optional positive integer timeout metadata. |

Unlike legacy executable declarations, explicit `targets:` do **not** gain an
implicit dependency on `//:repo`; the only edges they declare initially are the
labels listed in `deps`.

### Explicit target examples

Use explicit targets to name the things other workflow nodes depend on. Pure
dependency nodes usually have `sources` and no `run`; executable nodes may carry
`run`/`command`, but only the currently wired workflow primitives execute
automatically today.

```yaml
targets:
  - name: auth-lib
    kind: library
    sources:
      - "app/models/auth/**/*.rb"
      - "app/services/auth/**/*.rb"

  - name: worker-cli
    kind: binary
    sources:
      - "cli/**/*.go"
      - "cmd/syrus-worker/**/*.go"
    deps: [":auth-lib"]

  - name: web-app
    kind: application
    sources:
      - "app/frontend/**"
      - "app/controllers/**"
    deps: [":auth-lib"]

  - name: install-node-deps
    kind: prepare
    run: npm ci

  - name: frontend-bundle
    kind: builder
    run: npm run build
    sources: ["app/frontend/**"]
    deps: [":install-node-deps", ":web-app"]

  - name: eslint
    kind: formatter
    run: npm run lint -- --fix app/frontend
    sources:
      - "app/frontend/**/*.ts"
      - "app/frontend/**/*.tsx"
    deps: [":install-node-deps", ":web-app"]

  - name: api-client
    kind: generator
    run: bin/rails runner scripts/generate_api_client.rb
    sources: ["app/controllers/api/**/*.rb"]
    deps: [":auth-lib"]

  - name: typecheck
    kind: grader
    run: npm run typecheck
    sources:
      - "app/frontend/**/*.ts"
      - "app/frontend/**/*.tsx"
    deps: [":install-node-deps", ":frontend-bundle"]
    phases: [review, landing]
    required: true
    timeout_minutes: 10
```

The equivalent legacy executable sections can also depend on explicit nodes.
This is the most useful adoption step while formatter/generator runtime
selection is still legacy-config driven and root-only:

```yaml
targets:
  - name: frontend
    kind: application
    sources: ["app/frontend/**"]

  - name: node-deps
    kind: prepare
    run: npm ci

formatters:
  - command: npm run lint -- --fix app/frontend
    files:
      - "app/frontend/**/*.ts"
      - "app/frontend/**/*.tsx"
    deps: [":frontend", ":node-deps"]

generated:
  - command: npm run generate-client
    sources: ["schema/**/*.json"]
    generates: ["app/frontend/generated/**"]
    deps: [":frontend"]

grade:
  - name: frontend-tests
    run: npm test
    when_files_changed: ["app/frontend/**"]
    deps: [":frontend", ":node-deps"]
```

In today's runtime, root legacy `grade:` entries use their dependency closure
for affected-file selection and execute transitive `kind: prepare` dependencies
before the grader command. Legacy `formatters:` and `generated:` entries compile
their `deps:` into the graph for diagnostics and future target-aware execution,
but `Steps::Format` and `Steps::Generate` still choose commands from the legacy
sections directly. Explicit `kind: builder` nodes are metadata unless a legacy
grader (or another currently wired executable path) depends on them; no separate
builder Step materializes yet.

### Dependency-only edges

The target graph has one edge vocabulary: `deps` (or `dependencies`). A
dependency edge means "this target depends on that target for source-affecting
selection and prepare ordering." It does not mean "run this target first" in the
general case, and it does not encode edge kinds such as runtime dependency,
test dependency, build dependency, generated-output dependency, or ownership.

That limited model is deliberate:

- A changed file can affect a target through its own `sources` or through any
  target in its transitive dependency closure.
- A transitive executable `kind: prepare` dependency on a materialized grader
  runs before that grader, at most once per workflow workspace.
- Other executable dependencies are graph metadata until a workflow step knows
  how to materialize that target kind. A grader depending on a `builder` target
  can be selected when the builder's source scope changes, but the builder
  command itself does not automatically run as a separate build step today.
- Dependency direction is always from consumer to prerequisite:
  `//app:tests` depends on `//app:lib`, not the reverse.

Prefer explicit dependency nodes when widening a file glob would hide the real
relationship. For example, an app test target depending on `//api:schema` is
clearer than adding `api/**` to every app grader's `when_files_changed` list.
Use widened legacy globs when the relationship is temporary, coarse, or not
worth naming yet.

## Imported build-system graphs

Repositories can ask an enabled plugin to import target nodes and dependency
edges from an external build system:

```yaml
target_graph:
  imports:
    - provider: bazel
      failures: strict
      config:
        query: //...
```

`provider` is the registered `:build_system_graph_provider` key. `config` is a
free-form mapping passed to that provider so the repository, not Syrus core,
declares what should be imported. Providers return `TargetGraph::Import`
fragments containing normal `TargetGraph::Project` and `TargetGraph::Target`
objects. The compiler merges imports before Syrus-authored targets, validates
the imported fragment's own duplicate-label, missing-dependency, and cycle
rules, then layers `.syrus.yml` declarations over that base graph. Imported
targets carry `metadata["provenance"]` with the provider key, provider class,
and owning import declaration, and `TargetGraph::Compiler.diagnose` includes
one `import_diagnostics` entry per provider call.

Imported graph providers are expected to be exact for the labels they return:
canonical labels, source scopes, target kinds, and dependency edges should come
from the build system query, not from Syrus guesses. If a provider cannot
produce a complete graph for the requested query, it should fail the import or
return diagnostics that explain the precision gap. A graph-backed repository
should keep build-system labels stable enough for `.syrus.yml` dependencies and
overlays to refer to them directly.

Syrus overlays are intentionally narrow. A `targets:` entry whose canonical
label already exists in an imported graph may add only Syrus execution metadata:
`phases`, `required: true`, and `timeout_minutes`. It must not declare
`sources`, `deps`, or `run`/`command`, and it must not change the imported
target's kind except for the parser's default `library` value. Structural
redefinitions fail graph compilation with a conflict message naming both the
Syrus declaration and the imported target. Separate Syrus-only targets such as
prepare targets, graders, repo checks, preview setup nodes, and metadata-only
workflow helpers should use distinct labels and may depend on imported labels.
Legacy `grade:`, `formatters:`, and `generated:` entries are also distinct
Syrus-owned targets; if one collides with an imported label, that collision is
reported rather than silently replacing the build-system node.

```yaml
target_graph:
  imports:
    - provider: bazel
      config:
        query: //frontend:all
```

```yaml
# frontend/.syrus.yml
# Overlay Syrus metadata onto an imported Bazel target. The provider still owns
# kind, sources, command, and deps for //frontend:bundle.
targets:
  - name: bundle
    phases: [review, landing]
    required: true
    timeout_minutes: 20
```

```yaml
# /.syrus.yml
# Add a separate Syrus-only workflow node that depends on the imported target.
grade:
  - name: frontend-build
    run: bazel build //frontend:bundle
    when_files_changed: ["frontend/**"]
    deps: ["//frontend:bundle"]
```

When an external graph exists, `.syrus.yml` remains useful for metadata the
build system does not know and should not own:

- Syrus workflow phase metadata (`review`, `landing`, `ci`, `promotion`),
  requiredness, and timeouts.
- Syrus-only prepare targets for dependency installation or cache warmup that
  are not build-system targets.
- Grader commands and failure policy, especially checks that wrap a build
  target in Syrus-specific reporting, JUnit ingestion, or inherited-failure
  handling.
- Formatter and generator commands that are repository policy rather than
  native build graph nodes.
- `project:` labels/kinds that make operator UI boundaries readable even when
  imported labels are optimized for the build tool.

`failures` controls what happens when the configured provider is unavailable or
raises while importing: `strict` (default) fails graph compilation, while `warn`
records the error in diagnostics and continues with the rest of the graph.

Legacy executable declarations (`grade:`, `formatters:`, and `generated:`)
also accept `deps:`. For graders, runtime fanout uses those dependency
targets to decide whether the grader is affected by the diff. For explicit
builders, `builder_fanout` uses the same dependency-aware affected-target and
target-health-reuse logic. If a dependency chain includes an executable
`kind: prepare` target, the materialized grader step or selected builder run
executes that prepare command before its own command — see "Prepare target
execution" below for what "runs" means once more than one executable target
depends on the same prepare target.

### Prepare target execution

`Steps::GraderFanout`/`Steps::PreflightGraderFanout` snapshot each
materialized grader Step's transitive `kind: prepare` target dependencies
(`TargetGraph#prepare_dependencies_for`) onto its own `Step#details` as
`prepare_targets` — one entry per target, each an ordered list of commands
plus the declaring project path for nested targets. `Steps::BuilderFanout`
computes the same prepare-target list for each selected builder target before
running the builder command. Root prepare targets run from the repository
root; nested prepare targets run from their project directory, matching the
`run_target_prepare` MCP tool.
At execution time (`Steps::PrepareTargetExecution`, included into
`Steps::Grader` and `Steps::BuilderFanout`), a prepare target's commands run
**at most once per workflow workspace**, not once per dependent target: a
workspace-local marker under `.syrus/prepare-targets/` records that a target
has already run in this workspace, so a second grader or builder later in the
same workflow that depends on the same target reuses the marker instead of
re-running the commands. If the workspace gets rebuilt from scratch
mid-workflow (a worker hop onto a machine with no existing clone), there is no
marker there either, so the commands safely rerun — safe precisely because
prepare targets are declared idempotent environment setup (see "Prepare
Semantics" above) and must not modify tracked source files. An OS `flock` on
a sibling per-target lock file (held only for the duration of that target's
commands) keeps executable targets dispatched in parallel from the same
workflow from running the same target's commands concurrently.

Each grader Step records what it did with its own prepare targets on its
own `Step#details["prepare_target_results"]` — one entry per target with
`status` (`"ran"` or `"reused"`) and a human-readable `reason` (which grader
first triggered the run, and when). Root `prepare:` (and a nested
`.syrus.yml`'s own `prepare:`) is untouched by any of this — it stays the
unconditional pre-implementation baseline `Steps::Prepare` always runs (see
"Prepare Semantics" above).

Just like grader side-effect detection, a prepare target's commands are
checked for tracked-file mutations (`git status --porcelain` before/after);
a target that leaves uncommitted changes records a
`kind: "prepare_target_side_effect"` `WorkflowWarning` instead of failing
the grader Step — see `workflow_warnings.md`.

### Target health records

Executable target status is persisted in `TargetHealthRecord`, not only in a
workflow artifact. The initial producer is `grader_collect`: every real
materialized `grader` Step with a target label writes or updates one record for
the tuple of repository, target label, commit SHA, input fingerprint, command
fingerprint, and environment fingerprint. That lookup key is intentionally
workflow-independent so main-branch scheduling and later target selection can
reuse status across workflow attempts.

Target health statuses include `passed`, `failed`, `stale`, `unknown`,
`timed_out`, `cancelled`, `skipped`, and `inconclusive`. The model exposes
healthy/unhealthy scopes for selection code, while keeping `stale` and
`unknown` separate from hard failures. Timing, exit code, log path/size, and
other artifact references live on the target health row. Workflow artifacts
store only `target_health_record_refs` with record ids plus target label,
project id, commit SHA, and status; they are navigation breadcrumbs, not the
source of truth.

For distributed grader Steps, the input fingerprint is stable across workflows:
`grader_fanout` and `preflight_grader_fanout` stamp materialized grader Step
details with a `target_fingerprints` payload before execution. The target input
fingerprint covers declared source files for the target and its dependency
closure plus each owning `.syrus.yml`; changing a source file, dependency
target source, or config file changes the input key. The command fingerprint
covers command text and execution config such as dependencies, phases,
requiredness, timeout, file scope, owner config path, and target metadata. The
environment fingerprint covers relevant local runtime metadata, prepare target
dependencies and commands, and common toolchain files such as `Gemfile.lock`,
`package-lock.json`, `pnpm-lock.yaml`, `go.sum`, `.ruby-version`, and
`.tool-versions`.

`grader_collect` copies those stamped fingerprints into the target-health row.
The older source-snapshot behavior is now only a compatibility fallback for
historical or already-materialized grader Steps without `target_fingerprints`:
input fingerprint falls back to source snapshot fingerprint, then tree SHA,
then source SHA, then commit SHA. Syrus still never uses the source snapshot
database id, because that id is scoped to one workflow and would make the same
source input look different in another workflow.
### Reusing target health at runtime

Before running an explicit executable target, Syrus checks whether the same
target input, command, and environment fingerprints already have reusable
target health. The lookup intentionally ignores the producing commit SHA: the
target-health row still records that commit for provenance, but identical
fingerprints mean the relevant inputs are the same even when unrelated files
changed on a newer branch.

`format` checks explicit `formatter` targets compiled from `formatters:` as
`//:format/<index>`, and `generate` checks explicit `generator` targets
compiled from `generated:` as `//:generate/<index>`. Plugin-default
formatters from `formatters: []` do not currently have stable target labels,
so they are not target-health skipped. `grader_fanout` checks each selected
`grader` target before materializing its `grader` Step. The `builder` kind is
reserved in the graph model, but no `.syrus.yml` primitive materializes a
builder target yet.

A target is skipped only when its latest matching health record is healthy
(`passed` or `skipped`) and every executable dependency in its dependency
closure is also healthy for its own current fingerprints. Unknown, stale,
failed, timed-out, cancelled, or inconclusive target health is treated as a
miss, so required targets still run. Skip decisions are recorded in workflow
logs and artifacts: `format_target_health_skips`,
`generate_target_health_skips`, and `target_health_skipped_targets` for
grader fanout. Each entry includes the skipped target label, reason, producing
commit SHA, checked timestamp, and target-health record references.

### Agent-requested prepare targets

The agent environment snapshot includes a "Target prepare options" line built
from the same `TargetGraph::Compiler` output. Each entry names the target
label, owning `.syrus.yml`, project id, and command list, for example
`//cli:prepare (cli/.syrus.yml, project=cli): "go mod download"`. This is
informational only: Syrus still automatically runs only the root
`Steps::Prepare` before implementation unless a later policy explicitly opts
into intent-based pre-prepare.

Implementation-style workflow agents (`implement`, rebase-conflict repair, and
manual workflow agents) can explicitly call the workflow MCP tool
`run_target_prepare(label:, reason:)` when code exploration proves they need a
specific project environment. The tool accepts only executable
`kind: prepare` targets from the compiled graph. It runs the target's command
list in that target project's directory (root target in the repository root,
nested target in the nested config's directory) using the same scrubbed
dependency environment as `Steps::Prepare`.

Every call is auditable. The tool writes JobLog lines for the request and each
command, registers the spawned subprocesses as `kind: "prepare"`, and appends a
`Workflow#artifacts["target_prepare_requests"]` entry containing the label,
reason, commands, workdir, owner config path, project id, run id, status,
timestamps, command results, and output tail. A failed command returns an MCP
error response and leaves the failed audit entry in place; it does not change
which prepare commands Syrus will run automatically on future workflows.

### Explicit `builder` targets

`TargetGraph::Target::KINDS` already lists `builder` alongside
`formatter`/`generator`/`grader`/`prepare`. Repositories can declare builder
targets through the explicit `targets:` list:

```yaml
targets:
  - name: assets
    kind: builder
    run: npm run build
    sources: ["app/frontend/**/*"]
    cost: expensive
    artifacts: ["dist/**/*"]
```

`TargetGraph::Compiler` compiles these like other executable explicit targets:
they belong to the declaring project, use the same directory-based source
scope rules, and can depend on other labels through `deps:`/`dependencies:`.
There is still no legacy `build:` section; builders are declared through
`targets:` today.

Builder metadata controls opportunistic main-branch warming. A builder is
eligible when it is explicitly opted in (`opportunistic_build: true` or
`main_build: true`) or marked valuable by metadata such as `hot: true`,
`critical: true`, `cost: expensive`, positive `downstream_dependents`,
positive `recent_failures`, or `release_relevance: true`. Set
`opportunistic_build: false` or `main_build: false` to disable warming for a
builder even if other metadata would otherwise make it eligible.

`Workflows::MainGrader` runs `builder_fanout` after `prepare` and before
grader fanout. It selects only eligible builder targets affected by the main
branch change, skips targets with reusable healthy target-health records, runs
any transitive prepare target dependencies, then runs the builder command
fail-soft from the owning project directory. The result is recorded in
`TargetHealthRecord`. Declared `artifacts:` paths are resolved relative to the
owning project directory and stored as repository-relative references on the
target-health row (`declared_paths` and any currently existing paths);
workflow artifacts keep only target-health references.

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
discovery, per-declaration file-selector scoping, and optional explicit
`targets:` dependency nodes — compose into a small set of concrete layouts.
Most layouts below do not need explicit `targets:` at all; they work with
legacy sections alone.

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
subtree it actually validates. If those subtrees need reusable dependency
nodes, declare them with `targets:` and point the legacy graders at them with
`deps:`; otherwise per-subtree scoping via `when_files_changed`/`files` is
enough to keep unrelated checks from running.

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

This layout can express dependency edges with explicit target labels, for
example `deps: ["//api:client-contract"]` from an iOS or Android grader to an
API target. A project that does not declare those dependency nodes yet can
still react to a shared directory's changes by widening its own
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
