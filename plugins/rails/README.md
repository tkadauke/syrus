# syrus_rails

`syrus_rails` is a Syrus plugin gem that bundles Rails-specific capabilities into a single `PluginRegistry.register` call. It lives at `plugins/rails/` inside the Syrus repository and is the primary integration point for Ruby on Rails repositories.

## What it provides

| Extension point | What it does |
|---|---|
| `:preview_provider` | Configures the Syrus preview host to run `bin/rails server`, seed via `db:create db:migrate db:seed`, health-check `/up`, and tail `log/development.log` |

Additional extension points (MCP tool set, artifact renderer, test result parser, coverage analyzer, prompt injector) will be added in follow-on Jobs within the same epic.

## Auto-detection

The plugin activates for repositories that contain **all three** of:

- `Gemfile`
- `config/application.rb`
- `bin/rails`

Detection is handled by `SyrusRails::PreviewProvider#detect?`.

## Loading the plugin

Call `SyrusRails.register!` at Syrus boot time (e.g. in a Rails initializer or at the top of the worker entry point):

```ruby
require "syrus_rails"
SyrusRails.register!
```

After registration, `Syrus::PluginRegistry.providers_for(:preview_provider)` includes a `SyrusRails::PreviewProvider` instance. `Syrus::PreviewProviderResolver.for(repo_path)` returns that instance for any Rails repository and `nil` otherwise.

## Preview hosting with SQLite

The preview host runs the Rails server as a long-lived child process. Because no companion database container is available, the repository's `config/database.yml` must use `adapter: sqlite3` for the `development` environment:

```yaml
default: &default
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000

development:
  <<: *default
  database: db/development.sqlite3
```

Postgres preview environments are not yet supported.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/rails/ spec/syrus/plugin_registry_spec.rb
```

## Adding more extension points

Each new extension point follows the same pattern:

1. Add a class to `plugins/rails/lib/syrus_rails/<name>.rb` that includes the matching `Syrus::Plugin::<Interface>` module.
2. Add a `PluginRegistry.register(:<extension_point>, <ClassName>.new)` call inside `SyrusRails.register!`.
3. Add a spec under `spec/plugins/rails/`.
