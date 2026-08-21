# go

`go` is a Syrus plugin gem that bundles Go-generic intelligence into a single `PluginRegistry.register` call. It lives at `plugins/go/` inside the Syrus repository and applies to any Go project — there's no framework-specific split here the way `django` splits out of `python`, since net/http, Gin, Echo, etc. don't share a single web-serving convention.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects `go.mod` at the repo root and contributes `go mod download` (`prepare_priority: 40`). Go modules have a single package-manifest signal, unlike `javascript`/`python`'s multi-lockfile priority lists. |

### What this plugin intentionally does NOT provide

No custom `:test_result_parser`. `gotestsum --junitfile=report.xml ./...` output
is already parsed by core's `JunitXmlParser` fallback
(`app/services/junit_xml_parser.rb`) via `.syrus.yml`'s `junit_output:` — same
reasoning as the `python` plugin's `pytest --junitxml=` case. No custom
`.syrus.yml` parsing code is needed.

No custom `:coverage_analyzer`. This is a genuine gap unlike Python:
`go test -coverprofile=coverage.out` produces a bespoke text format with no
built-in XML/lcov export, unlike `coverage.py`'s native `coverage xml`. Convert
it to a format a core parser already understands instead of writing new Ruby:

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
required for either path.

A native Go coverage-profile `:coverage_analyzer` (parsing
`coverage.out`'s own text format directly, dropping the extra converter-tool
dependency from target repos) is a reasonable follow-up if operators push
back on requiring `gocov`/`gcov2lcov`, but is out of scope here.

No `:preview_provider` — there's no single universal Go web-serving
convention at the language level (net/http, Gin, Echo, etc. all differ).

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "go", path: "plugins/go"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/go/
```
