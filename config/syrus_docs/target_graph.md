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
