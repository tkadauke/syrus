# django

`django` is a Syrus plugin gem that bundles Django-framework-specific intelligence into a single `PluginRegistry.register` call. It lives at `plugins/django/` inside the Syrus repository and `depends_on: [ "python" ]`: enabling `django` in Admin → Plugins cascades to enable `python`, and disabling `python` while `django` is enabled surfaces a confirm-and-cascade-disable prompt. See `config/syrus_docs/plugins.md` for the general `depends_on` mechanism.

Python-generic capabilities that aren't specific to Django — uv/poetry/pip
prepare detection, pytest grader failure detail, and the venv/uv activation
prompt reminder — live in the separate `python` plugin (`plugins/python/`)
instead, so non-Django Python projects (Flask, FastAPI, plain scripts) can use
them too.

See [`docs/syrus_docs/django.md`](docs/syrus_docs/django.md) for the full operator-facing writeup of what this plugin provides (also the copy surfaced by the admin Plugins detail page and `search_syrus_docs`). This README stays focused on developing the plugin itself.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "django", path: "plugins/django"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/django/
```
