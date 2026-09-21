# Go

The `go` plugin (`plugins/go/`) provides Go-generic intelligence for any Go
project — services, CLIs, libraries, and mixed-language repositories with a
Go component. It is default-ON, disableable, category `language`,
`prepare_priority: 40`. There is no framework-specific split the way `django`
splits out of `python`: `net/http`, Gin, Echo, and friends don't share a
single web-serving convention worth modeling as its own plugin.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects `go.mod` at the repo root and contributes `go mod download` (`prepare_priority: 40`). Go modules have a single package-manifest signal, unlike `javascript`/`python`'s multi-lockfile priority lists — one signal, one command. Also declares `.go-version` as the `mise` version file, and labels `go test`/`go vet`/`go build` command spans for worker-health diagnostics. |
| `:grader_type` | Expands `type: go-test` into a `go test ./...` grader (`Go::TestGraderType`). Nested project configs can set `path: cli` (or another module directory) and Syrus runs the command from the repository root with the correct `cd`. |
| `:review_criteria_provider` | Seeds a default adversarial-review checklist item — "Flag swallowed errors (`_ = err`)" — when `go.mod` is present (same signal as `:prepare_detector`). |
| `:autofix_command` | `Go::GofmtAutofix` runs `gofmt -w .` whenever `go.mod` is present. `gofmt` has no configuration surface to gate on the way rubocop/eslint/ruff do, so presence of a Go module is the only signal needed. |
| `:dependency_audit_command` | Runs `govulncheck ./...` when `go.sum` is present. `go.sum` is the lockfile signal — `go.mod` is the manifest `:prepare_detector` keys off, but by itself doesn't reflect a resolved dependency version an audit tool can check. |

## Self-suggestion

`suggests_enabling` nudges an admin who hasn't enabled `go` yet when
`signals.repositories_detecting("go")` reports repositories whose file layout
matched the plugin's own detector — see `config/syrus_docs/plugins.md`'s
"Telling an admin a plugin exists" section for the general mechanism.

## What this plugin intentionally does NOT provide

No custom `:test_result_parser`. `gotestsum --junitfile=report.xml ./...`
output is already parsed by core's `JunitXmlParser` fallback
(`app/services/junit_xml_parser.rb`) via `.syrus.yml`'s `junit_output:` — same
reasoning as the `python` plugin's `pytest --junitxml=` case. No custom
`.syrus.yml` parsing code is needed.

No custom `:coverage_analyzer`. This is a genuine gap unlike Python:
`go test -coverprofile=coverage.out` produces a bespoke text format with no
built-in XML/lcov export, unlike `coverage.py`'s native `coverage xml`.
Convert it to a format a core parser already understands instead of writing
new Ruby:

- **Cobertura** (handled by `CoverageAnalysis::Parsers::Cobertura`,
  `app/services/coverage_analysis/parsers/cobertura.rb`): pipe through
  [`gocov`](https://github.com/axw/gocov) +
  [`gocov-xml`](https://github.com/AlekSi/gocov-xml):

  ```sh
  go test -coverprofile=coverage.out ./...
  gocov convert coverage.out | gocov-xml > coverage.xml
  ```

- **lcov**: convert with
  [`gcov2lcov`](https://github.com/jandelgado/gcov2lcov):

  ```sh
  go test -coverprofile=coverage.out ./...
  gcov2lcov -infile=coverage.out -outfile=coverage.lcov
  ```

Wire whichever output you produce into `.syrus.yml`'s
`coverage.sources[].format` (`cobertura` or `lcov`) — zero new Ruby code
required for either path. A native Go coverage-profile `:coverage_analyzer`
(parsing `coverage.out`'s own text format directly, dropping the extra
converter-tool dependency from target repos) is a reasonable follow-up if
operators push back on requiring `gocov`/`gcov2lcov`, but is out of scope
today.

No `:preview_provider` — there's no single universal Go web-serving
convention at the language level (`net/http`, Gin, Echo, etc. all differ).

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once
`gem "go", path: "plugins/go"` is bundled — no manual `register!` call
needed.
