# syrus_rails

`syrus_rails` is a Syrus plugin gem that bundles Rails-*framework*-specific capabilities into a single `PluginRegistry.register` call (registered manifest name `syrus-rails`). It lives at `plugins/rails/` inside the Syrus repository and is the primary integration point for Ruby on Rails repositories.

Ruby-generic capabilities that aren't specific to Rails — RSpec grader
failure detail, RSpec output parsing, SimpleCov coverage analysis, and
Gemfile prepare detection — live in the separate `ruby` plugin
(`plugins/ruby/`) instead, so non-Rails Ruby projects (gems, Sinatra apps,
plain scripts) can use them too. `syrus_rails` declares
`depends_on: [ "ruby" ]`: enabling `syrus_rails` in Admin → Plugins cascades
to enable `ruby`, and disabling `ruby` while `syrus_rails` is enabled
surfaces a confirm-and-cascade-disable prompt. See
`config/syrus_docs/plugins.md` for the general `depends_on` mechanism.

## What it provides

| Extension point | What it does |
|---|---|
| `:preview_provider` | Configures the Syrus preview host to run `bin/rails server`, seed via `db:create db:migrate db:seed`, health-check `/up` (falling back to `/` when the repo's `config/routes.rb` doesn't map `rails/health#show`), and tail `log/development.log` |
| `:mcp_tool_set` | Rails schema/migration/route introspection tools for workflow agents |
| `:artifact_renderer` | `SchemaErdRenderer` and `MigrationDiffRenderer`, mapping `submit_artifact` payload types to reviewer-facing ERD/migration-diff views |
| `:prompt_injector` | Adds Rails-specific guidance (schema/migration awareness) to the implementing agent's system prompt |

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

Rails previews install JavaScript dependencies when a package-manager lockfile
is present and start `npm run dev` alongside `bin/rails server` when the repo's
`package.json` actually defines a `dev` script (a `package.json` present for
other tooling, with no `dev` script, is left alone rather than launching a
doomed `npm run dev`). They also set `VITE_RUBY_SKIP_PROXY=false` so vite-ruby
generates same-origin asset URLs. Without those preview-specific guardrails,
apps can leak `http://localhost:<vite-port>` asset URLs that point at the
operator's browser machine instead of the preview host and render as a blank
page.

The provider exposes `log/development.log` and `log/vite.log` to the preview
log API and the `read_preview_log` MCP tool.

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
