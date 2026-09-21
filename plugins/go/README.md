# go

`go` is a Syrus plugin gem that bundles Go-generic intelligence into a single `PluginRegistry.register` call. It lives at `plugins/go/` inside the Syrus repository and applies to any Go project — there's no framework-specific split here the way `django` splits out of `python`, since net/http, Gin, Echo, etc. don't share a single web-serving convention.

See [`docs/syrus_docs/go.md`](docs/syrus_docs/go.md) for the full operator-facing writeup of what this plugin provides (also the copy surfaced by the admin Plugins detail page and `search_syrus_docs`). This README stays focused on developing the plugin itself.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "go", path: "plugins/go"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/go/
```
