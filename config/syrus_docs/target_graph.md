# Target Graph Compilation

Syrus has an internal `TargetGraph` model (`app/services/target_graph.rb` and
`app/services/target_graph/`) that represents a repository's configuration as
canonically labeled `Project`s and `Target`s (`//package:name`, e.g.
`//:repo`, `//:grade/tests`). It exists so later project-aware workflow work
has one real graph to build on instead of a model nothing populates.

**This is internal plumbing, not a feature yet.** Today `TargetGraph::Compiler`
only reads a repository's root `.syrus.yml` legacy sections (`prepare`,
`formatters`, `generated`, `grade`) and compiles them into targets under an
implicit root project (`//:repo`). Nothing in the runtime prepare, format,
generate, or grader pipelines reads from the compiled graph, and compiling it
does not change what those pipelines run. Nested `.syrus.yml` discovery,
explicit `project:`/`targets:` declarations, and build-system plugin import
(the later adoption levels in `DOC-20`) do not exist yet — do not describe
them as available.

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
