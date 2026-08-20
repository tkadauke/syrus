# python

`python` is a Syrus plugin gem that bundles Python-generic intelligence into a single `PluginRegistry.register` call. It lives at `plugins/python/` inside the Syrus repository and applies to any Python project (Flask, FastAPI, plain WSGI, scripts) — framework-specific tooling (e.g. Django) belongs in its own plugin.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects a Python package-manager signal at the repo root and contributes exactly one install command, in priority order: `uv.lock` → `uv sync`, `poetry.lock` → `poetry install`, `requirements.txt` → `pip install -r requirements.txt`, else bare `pyproject.toml` → `pip install -e .` (`prepare_priority: 30`). |
| `:grader_augmentor` | Reads pytest's [pytest-json-report](https://pypi.org/project/pytest-json-report/) output under `.syrus/pytest-json/*.json` and appends compact `FAILED: test_name — message` lines to a failed grader's log when the grader command contains `"pytest"`. |
| `:prompt_injector` | Light, unconditional reminder to the implementing agent to activate/use a virtual environment or dependency-manager run-prefix (`.venv`, `uv run`, `poetry run`) instead of assuming a global interpreter. |

### Enabling the pytest grader augmentor

The augmentor only has something to read if the repo's grader command writes
a JSON report. Add `--json-report` to the pytest invocation in `.syrus.yml`:

```yaml
graders:
  pytest: "pytest --json-report --json-report-file=.syrus/pytest-json/report.json"
```

### What this plugin intentionally does NOT provide

No custom `:test_result_parser` or `:coverage_analyzer`. Core already handles
the common cases:

- `pytest --junitxml=<path>` output is parsed by core's `JunitXmlParser`
  fallback (`app/services/junit_xml_parser.rb`) via `.syrus.yml`'s
  `junit_output:`.
- `coverage xml` (coverage.py) emits Cobertura-format XML, handled by
  `CoverageAnalysis::Parsers::Cobertura`
  (`app/services/coverage_analysis/parsers/cobertura.rb`) via
  `.syrus.yml`'s `coverage.sources[].format: cobertura`.

No `.syrus.yml` custom parsing code is needed for either.

No `:preview_provider` — there's no single universal "how do I run this"
convention across Flask/FastAPI/plain WSGI at the language level.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "python", path: "plugins/python"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/python/
```
