# Python

The `python` plugin (`plugins/python/`) provides Python-generic intelligence
for any Python repository — Flask, FastAPI, plain WSGI apps, scripts, and
mixed-language repositories with a Python component. It is default-ON,
disableable, category `language`, `prepare_priority: 30`. Framework-specific
behavior that isn't generic to every Python project (preview hosting,
migrations, fixture seeding) lives in the separate `django` plugin, which
`depends_on: [ "python" ]` for this shared support.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects a Python package-manager signal at the repo root and contributes exactly one install command, in priority order: `uv.lock` → `uv sync`, `poetry.lock` → `poetry install`, `requirements.txt` → `pip install -r requirements.txt`, else bare `pyproject.toml` → `pip install -e .` (`prepare_priority: 30`). Also declares `.python-version` as the `mise` version file used to select the Python toolchain version, and labels `pytest`/`ruff`/`mypy` command spans for worker-health diagnostics. |
| `:grader_augmentor` | Reads pytest's [pytest-json-report](https://pypi.org/project/pytest-json-report/) output under `.syrus/pytest-json/*.json` and appends compact `FAILED: test_name — message` lines to a failed grader's log when the grader command contains `"pytest"`. Tolerates a partially-written/corrupt JSON file by skipping it rather than failing the whole augmentation. |
| `:prompt_injector` | Light, unconditional reminder to the implementing agent to activate/use a virtual environment or dependency-manager run-prefix (`.venv`, `uv run`, `poetry run`) instead of assuming a global interpreter has the right packages installed. |
| `:review_criteria_provider` | Seeds a default adversarial-review checklist item — "Flag missing type hints on new public functions" — when a Python package-manager signal is present (same signal as `:prepare_detector`). |
| `:autofix_command` | Two providers: `Python::RuffFormatAutofix` runs `ruff format .`, gated on a `.ruff.toml`/`ruff.toml` file or a `[tool.ruff]` table in `pyproject.toml`; `Python::BlackAutofix` runs `black .`, gated on a `[tool.black]` table in `pyproject.toml` (black has no standalone config file convention). Either, both, or neither can apply depending on repo config. |
| `:dependency_audit_command` | Runs `pip-audit` when `uv.lock`, `poetry.lock`, or `requirements.txt` is present. A bare `pyproject.toml` with no lockfile is excluded — there is nothing pinned for `pip-audit` to check. |

## Self-suggestion

`suggests_enabling` nudges an admin who hasn't enabled `python` yet when
`signals.repositories_detecting("python")` reports repositories whose file
layout matched the plugin's own detector — see
`config/syrus_docs/plugins.md`'s "Telling an admin a plugin exists" section
for the general mechanism.

## Enabling the pytest grader augmentor

The augmentor only has something to read if the repo's grader command writes
a JSON report. Add `--json-report` to the pytest invocation in `.syrus.yml`:

```yaml
graders:
  pytest: "pytest --json-report --json-report-file=.syrus/pytest-json/report.json"
```

## What this plugin intentionally does NOT provide

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
convention across Flask/FastAPI/plain WSGI at the language level. The
`django` plugin adds one for Django specifically, since `manage.py runserver`
is a real framework-wide convention.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once
`gem "python", path: "plugins/python"` is bundled — no manual `register!`
call needed.
