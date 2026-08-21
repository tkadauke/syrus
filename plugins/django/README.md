# django

`django` is a Syrus plugin gem that bundles Django-framework-specific intelligence into a single `PluginRegistry.register` call. It lives at `plugins/django/` inside the Syrus repository and `depends_on: [ "python" ]`: enabling `django` in Admin → Plugins cascades to enable `python`, and disabling `python` while `django` is enabled surfaces a confirm-and-cascade-disable prompt. See `config/syrus_docs/plugins.md` for the general `depends_on` mechanism.

Python-generic capabilities that aren't specific to Django — uv/poetry/pip
prepare detection, pytest grader failure detail, and the venv/uv activation
prompt reminder — live in the separate `python` plugin (`plugins/python/`)
instead, so non-Django Python projects (Flask, FastAPI, plain scripts) can use
them too.

## What it provides

| Extension point | What it does |
|---|---|
| `:preview_provider` | Boots `python manage.py runserver 0.0.0.0:<port>`, migrates and optionally seeds the database, and detects Django repos via `manage.py` plus an importable settings module. |

## Auto-detection

`Django::PreviewProvider#detect?` requires:

- `manage.py` at the repo root
- A settings module resolvable from `manage.py`'s
  `os.environ.setdefault("DJANGO_SETTINGS_MODULE", "<module>")` call — either
  `<module_path>.py` or `<module_path>/__init__.py` must exist, where
  `<module_path>` is the dotted module name with dots replaced by `/`.

## Preview hosting

- **Setup**: installs dependencies using the same priority order as the
  `python` plugin's `:prepare_detector` (`uv.lock` → `uv sync`, `poetry.lock`
  → `poetry install`, `requirements.txt` → `pip install -r requirements.txt`,
  else bare `pyproject.toml` → `pip install -e .`), implemented independently
  as its own shell conditional per the `:preview_provider` interface's own
  `setup_commands`.
- **Seed**: runs `python manage.py migrate`, then — Syrus's own convention,
  since Django has no bundled seed mechanism like Rails' `db:seed` — loads
  `fixtures/seed.json` via `python manage.py loaddata` if that file exists in
  the repo.
- **Health check**: Django has no Rails-style built-in health endpoint, so
  this plugin falls back to `/`. That only succeeds if the app maps a root
  URL returning a 2xx/3xx response. Repos without one should set
  `preview.health_check` in `.syrus.yml`, which takes priority over this
  plugin's default (see `PreviewCommandSource#from_syrus_yml`).
- **Logs**: `manage.py runserver` logs to stdout/stderr by default, which the
  preview host otherwise discards; the start command redirects both into
  `log/django.log` so `read_preview_log` and the preview log API can tail it.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "django", path: "plugins/django"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/django/
```
