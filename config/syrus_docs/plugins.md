# Syrus Plugin System

Syrus supports bundled plugins that extend its behavior for specific language ecosystems. Plugins live under `plugins/` in the Syrus repository and are loaded on startup.

## Extension points

Each extension point has an interface module under `lib/syrus/plugin/` and a registry entry in `Syrus::PluginRegistry`.

| Extension point | Interface module | Purpose |
|---|---|---|
| `:preview_provider` | `Syrus::Plugin::PreviewProvider` | Preview server start/seed/health/log config |
| `:mcp_tool_set` | _(upcoming)_ | Language-specific MCP tools for agents |
| `:artifact_renderer` | _(upcoming)_ | Custom artifact visualizations |
| `:test_result_parser` | _(upcoming)_ | Raw runner output → normalized test records |
| `:coverage_analyzer` | _(upcoming)_ | Coverage output → normalized file coverage |
| `:prompt_injector` | _(upcoming)_ | Language-specific agent system prompt additions |

## `:preview_provider`

Preview providers tell Syrus how to start, seed, and health-check a preview application for a repository. The provider is selected at runtime by calling `detect?` on each registered provider in order; the first match is used.

### Interface (`Syrus::Plugin::PreviewProvider`)

```ruby
def detect?(repo_path)     # bool — true if this provider handles the repo
def start_command(port:)   # String — shell command to start the server
def seed_command           # String | nil — command to set up the database
def health_check_path      # String — URL path polled to determine readiness
def log_paths              # Array<String> — log paths (relative to repo root) to tail
```

### Selecting a provider programmatically

```ruby
provider = Syrus::PreviewProviderResolver.for(repo_path)
# => SyrusRails::PreviewProvider instance, or nil if nothing matches
```

## Bundled plugins

### `syrus_rails` (Rails plugin)

Located at `plugins/rails/`. Loaded automatically in production; activated by calling `SyrusRails.register!` in an initializer.

**Provides:**
- `:preview_provider` — starts `bin/rails server -p <port> -b 0.0.0.0 -e development`, seeds via `db:create db:migrate db:seed`, health-checks `/up`, and tails `log/development.log`.

**Auto-detection:** activates for repositories containing all three of: `Gemfile`, `config/application.rb`, and `bin/rails`.

**SQLite requirement:** the preview host launches the Rails server in a long-lived child process. For the preview database to work without a companion Postgres container, the repo's `config/database.yml` must use `adapter: sqlite3` for the `development` environment. Postgres preview environments are not yet supported.

Example `config/database.yml` for SQLite-backed preview hosting:

```yaml
default: &default
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000

development:
  <<: *default
  database: db/development.sqlite3
```

## Adding a plugin

1. Create a gem directory under `plugins/<name>/`.
2. Define your provider class and `include Syrus::Plugin::<InterfaceModule>`.
3. Implement a `register!` class method that calls `Syrus::PluginRegistry.register(extension_point, YourProvider.new)`.
4. Add a spec under `spec/plugins/<name>/` covering `detect?`, primary methods, and the registry integration.
5. Load the plugin by calling `YourPlugin.register!` from a Rails initializer or at Syrus boot.
