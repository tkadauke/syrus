# Ruby

`ruby` is a Syrus plugin gem that bundles Ruby-generic capabilities — not specific to Rails — into a single `PluginRegistry.register` call. It lives at `plugins/ruby/` inside the Syrus repository and applies to any Ruby project: gems, Sinatra apps, plain Ruby scripts, and Rails apps alike.

## What it provides

| Contribution | What it does |
|---|---|
| `ecosystem.grader_diagnostics` | Registers two providers: `Ruby::GraderAugmentor` reads RSpec's per-worker JSON output under `.syrus/rspec-json/` and appends compact failure details to a failed grader's log when the grader command contains `"rspec"`; `Ruby::RubocopGraderAugmentor` reads RuboCop's `--format json` output under `.syrus/rubocop-json/` and appends compact `file:line: cop_name: message` lines when the grader command contains `"rubocop"`. |
| `ecosystem.analyze_coverage` | Parses SimpleCov's `.resultset.json` into the coverage artifact shape `Steps::CoverageAnalyze` expects. |
| `ecosystem.detect_prepare` | Detects a `Gemfile` at the repo root and contributes `bundle install` to the prepare plan (`prepare_priority: 10`). |
| `ecosystem.review_criteria` | Seeds a default adversarial-review checklist item — "Flag new N+1 query patterns in ActiveRecord code" — when a `Gemfile` is present (same signal as `ecosystem.detect_prepare`). |

`plugins/rails` (`syrus_rails`) provides the Rails-specific extension points (preview hosting, schema/migration tooling, MCP tools, prompt injection) on top of this plugin.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "ruby", path: "plugins/ruby"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/ruby/
```
