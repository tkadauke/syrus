# ruby

`ruby` is a Syrus plugin gem that bundles Ruby-generic capabilities — not specific to Rails — into a single `PluginRegistry.register` call. It lives at `plugins/ruby/` inside the Syrus repository and applies to any Ruby project: gems, Sinatra apps, plain Ruby scripts, and Rails apps alike.

## What it provides

| Extension point | What it does |
|---|---|
| `:grader_augmentor` | Reads RSpec's per-worker JSON output under `.syrus/rspec-json/` and appends compact failure details to a failed grader's log when the grader command contains `"rspec"`. |
| `:coverage_analyzer` | Parses SimpleCov's `.resultset.json` into the coverage artifact shape `Steps::CoverageAnalyze` expects. |
| `:prepare_detector` | Detects a `Gemfile` at the repo root and contributes `bundle install` to the prepare plan (`prepare_priority: 10`). |

`plugins/rails` (`syrus_rails`) provides the Rails-specific extension points (preview hosting, schema/migration tooling, MCP tools, prompt injection) on top of this plugin.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "ruby", path: "plugins/ruby"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/ruby/
```
