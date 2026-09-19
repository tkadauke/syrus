# python

`python` is a Syrus plugin gem that bundles Python-generic intelligence into a single `PluginRegistry.register` call. It lives at `plugins/python/` inside the Syrus repository and applies to any Python project (Flask, FastAPI, plain WSGI, scripts) — framework-specific tooling (e.g. Django) belongs in its own plugin.

See [`docs/syrus_docs/python.md`](docs/syrus_docs/python.md) for the full operator-facing writeup of what this plugin provides (also the copy surfaced by the admin Plugins detail page and `search_syrus_docs`). This README stays focused on developing the plugin itself.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "python", path: "plugins/python"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/python/
```
