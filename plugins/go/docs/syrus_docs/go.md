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
| `:prepare_detector` | Detects `go.mod` at the repo root and contributes `GOWORK=off go mod download` (`prepare_priority: 40`). Go modules have a single package-manifest signal, unlike `javascript`/`python`'s multi-lockfile priority lists — one signal, one command. Also declares `.go-version` as the `mise` version file, and labels `go test`/`go vet`/`go build` command spans for worker-health diagnostics. |
| `:review_criteria_provider` | Seeds a default adversarial-review checklist item — "Flag swallowed errors (`_ = err`)" — when `go.mod` is present (same signal as `:prepare_detector`). |
| `:autofix_command` | `Go::GofmtAutofix` runs `gofmt -w .` whenever `go.mod` is present. `gofmt` has no configuration surface to gate on the way rubocop/eslint/ruff do, so presence of a Go module is the only signal needed. |
| `:dependency_audit_command` | Runs `govulncheck ./...` when `go.sum` is present. `go.sum` is the lockfile signal — `go.mod` is the manifest `:prepare_detector` keys off, but by itself doesn't reflect a resolved dependency version an audit tool can check. |
| `:coverage_analyzer` | Parses native `go test -coverprofile` output into repository and changed-line coverage without converter tools. |

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

## Native coverage profiles

The recommended grader command uses Go's built-in profile writer directly:

```yaml
grade:
  - name: go-tests
    run: go test -covermode=atomic -coverprofile=coverage.out ./...
coverage:
  sources:
    - artifact: coverage.out
      format: go-cover
```

No converter dependency is required. `go-cover` supports the native `set`,
`count`, and `atomic` modes. Statement blocks are projected onto their source
lines for repository coverage, changed-line coverage, and grader evidence;
overlapping blocks are merged, zero-count lines remain executable, and Windows
path separators are normalized before project-relative path handling. Aggregate
and per-file percentages use the profile's native statement weights, while the
line projection drives changed-line annotations. Import-qualified paths are
resolved through the nearest `go.mod`, including nested modules.

No `:preview_provider` — there's no single universal Go web-serving
convention at the language level (`net/http`, Gin, Echo, etc. all differ).

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once
`gem "go", path: "plugins/go"` is bundled — no manual `register!` call
needed.
