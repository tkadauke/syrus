# django

`django` is a Syrus plugin gem that bundles Django-*framework*-specific capabilities into a single `PluginRegistry.register` call. It lives at `plugins/django/` inside the Syrus repository and is the primary integration point for Django repositories.

Python-generic capabilities that aren't specific to Django — `uv`/`poetry`/`pip` prepare detection, pytest JSON-report grader failure detail, and a venv/dependency-manager activation reminder — live in the separate `python` plugin (`plugins/python/`) instead, so non-Django Python projects (Flask, FastAPI, plain WSGI, scripts) can use them too. `django` declares `depends_on: [ "python" ]`: enabling `django` in Admin → Plugins cascades to enable `python`, and disabling `python` while `django` is enabled surfaces a confirm-and-cascade-disable prompt. See `config/syrus_docs/plugins.md` for the general `depends_on` mechanism.

## What it provides

| Extension point | What it does |
|---|---|
| `:preview_provider` | Configures the Syrus preview host to run `python manage.py runserver 0.0.0.0:<port>`, seed via `python manage.py migrate` plus a documented fixtures/seed convention, and health-check `/admin/login/` |

## Auto-detection

The plugin activates for repositories that contain `manage.py` *and* an importable Django settings module. `Django::PreviewProvider#detect?` parses `manage.py`'s `DJANGO_SETTINGS_MODULE` assignment (e.g. `os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'mysite.settings')`) and resolves the dotted module path to a real file on disk (`mysite/settings.py`, or `mysite/settings/__init__.py` for a settings package) — no `python` interpreter is required to answer `detect?`.

## The seed convention

`seed_command` first runs `python manage.py migrate`, then looks for a way to populate demo data, in priority order:

1. A custom `seed` management command (`<app>/management/commands/seed.py`) — run via `python manage.py seed` when present.
2. A `fixtures/seed.json` fixture file — loaded via `python manage.py loaddata fixtures/seed.json` when present and no `seed` command exists.

Neither is required; a repo with neither just runs `migrate` and starts with an empty database. Like Rails' `db/seeds.rb`, this script (or fixture) must be idempotent — it runs against a fresh checkout on every preview spin-up, not once. See `config/syrus_docs/preview_environments.md`'s "Seeding must be idempotent" section.

## Package-manager setup

`setup_commands` picks exactly one Python package-manager install command in the same priority order as the `python` plugin's `:prepare_detector` (`uv.lock` → `uv sync`, `poetry.lock` → `poetry install`, `requirements.txt` → `pip install -r requirements.txt`, else bare `pyproject.toml` → `pip install -e .`), evaluated fresh against the preview checkout rather than delegating to `Python::PrepareDetector` — the `:preview_provider` interface owns its own `setup_commands`, matching how `syrus_rails::PreviewProvider#setup_commands` branches on JS package managers independently of the `javascript` plugin's `:prepare_detector`.

## No built-in health check endpoint

Django ships no Rails-style built-in `/up`. `django.contrib.admin` is part of the default `startproject` scaffold, and its login view (`/admin/login/`) returns `200` without requiring authentication — so it doubles as a readiness signal any stock Django project answers, and is used as the default `health_check_path`. Repositories that don't enable `django.contrib.admin` should override `health_check_path` via `.syrus.yml`'s `preview.health_check` key.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "django", path: "plugins/django"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/django/
```
