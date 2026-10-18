# go

`go` is a Syrus plugin gem that bundles Go-generic intelligence into a single `PluginRegistry.register` call. It lives at `plugins/go/` inside the Syrus repository and applies to any Go project — there's no framework-specific split here the way `django` splits out of `python`, since net/http, Gin, Echo, etc. don't share a single web-serving convention.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects `go.mod` at the repo root and contributes `GOWORK=off go mod download` (`prepare_priority: 40`). Go modules have a single package-manifest signal, unlike `javascript`/`python`'s multi-lockfile priority lists. |
| `:grader_type` | Expands `type: go-test` into a `go test ./...` grader. Nested project configs can set `path: cli` (or another module directory) and Syrus runs the command from the repository root with the correct `cd`. |
| `:review_criteria_provider` | Seeds a default adversarial-review checklist item — "Flag swallowed errors (`_ = err`)" — when `go.mod` is present (same signal as `:prepare_detector`). |
| `:coverage_analyzer` | Parses native `go test -coverprofile` output into repository and changed-line coverage without converter tools. |

### What this plugin intentionally does NOT provide

No custom `:test_result_parser`. `gotestsum --junitfile=report.xml ./...` output
is already parsed by core's `JunitXmlParser` fallback
(`app/services/junit_xml_parser.rb`) via `.syrus.yml`'s `junit_output:` — same
reasoning as the `python` plugin's `pytest --junitxml=` case. No custom
`.syrus.yml` parsing code is needed.

### Native coverage profiles

Use Go's built-in profile writer; no `gocov`, `gocov-xml`, or `gcov2lcov`
installation is needed:

```yaml
grade:
  - name: go-tests
    run: go test -covermode=atomic -coverprofile=coverage.out ./...
coverage:
  sources:
    - artifact: coverage.out
      format: go-cover
```

`go-cover` accepts the current native modes (`set`, `count`, and `atomic`). It
maps each statement block onto the source lines it spans, merges overlapping
blocks, retains zero-count executable lines, and normalizes Windows path
separators before Syrus applies its repository/project path normalization.

No `:preview_provider` — there's no single universal Go web-serving
convention at the language level (net/http, Gin, Echo, etc. all differ).

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "go", path: "plugins/go"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/go/
```
