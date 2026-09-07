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
compiling it does not change what those pipelines run. Explicit
`project:`/`targets:` declarations and build-system plugin import (later
adoption levels in `DOC-20`) do not exist yet — do not describe them as
available.

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
`Project` (id and label derived from its relative path, e.g. `cli` for
`cli/.syrus.yml`, `apps-desktop` for `apps/desktop/.syrus.yml`), and its
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
- **A structural collision across files** — most concretely, two different
  nested directories whose paths reduce to the same project id (a directory
  literally named `foo-bar` alongside a nested `foo/bar/.syrus.yml`, both of
  which need to become project id `foo-bar`) — is a real graph-construction
  problem and raises `TargetGraph::ValidationError` naming both files, the
  same way any other duplicate project/target declaration does.
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
