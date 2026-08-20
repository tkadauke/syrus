# javascript

`javascript` is a Syrus plugin gem that bundles Node/JS (and TS) prepare detection into a single `PluginRegistry.register` call. It lives at `plugins/javascript/` inside the Syrus repository. Named for language parity with `ruby`/`python` rather than `node`, since npm/yarn/pnpm/bun + `package.json` detection is identical for JS and TS repos.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects a Node/JS lockfile at the repo root and contributes exactly one package-manager install command, in priority order: `yarn.lock` → `pnpm-lock.yaml` → `package-lock.json` → `package.json` (`prepare_priority: 20`). |

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "javascript", path: "plugins/javascript"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/javascript/
```
