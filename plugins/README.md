# Syrus Plugins

This directory hosts bundled plugin gems. Each subdirectory is a self-contained
Rails Engine that registers one or more extension points with `Syrus::PluginRegistry`
at boot.

External (third-party) plugins are installed the same way as any gem: add them to
`Gemfile`, run `bundle install`, then restart the server.

Plugins have two separate states:

- **Installed** means the gem is in the bundle and the app has restarted. Ruby
  code, controllers, frontend modules, and locale files are available.
- **Enabled** means `PluginRecord.enabled` allows the registered extension
  points to be visible/usable at runtime. Disabling a plugin does not remove its
  compiled JavaScript or loaded locale strings.

## Quick start

Scaffold a new bundled plugin:

```
rails generate syrus:plugin my_plugin
```

This creates `plugins/my_plugin/` with a gemspec, version file, and a Rails Engine
that calls `Syrus::PluginRegistry.register` in its initializer. Then add a path
reference to `Gemfile`:

```ruby
gem "my_plugin", path: "plugins/my_plugin"
```

## Extension points

| Key               | Interface module                      | Must implement |
|-------------------|---------------------------------------|----------------|
| `:agent_provider` | `Syrus::Plugin::AgentProvider`        | `.provider_key`, `.display_name`, `.available?`, `#invoke` |
| `:chat_provider`  | `Syrus::Plugin::ChatProvider`         | `.provider_key`, `.display_name`, `.available?`, `#invoke`; inherits `ChatProviders::Base` construction/session-capture contract |
| `:mcp_tool_set`   | `Syrus::Plugin::McpToolSet`           | `.tool_definitions`, `.available_for?`, `#handle`; optionally `.available_for_context?` and `.tool_definitions(context:)` for role-aware workflow tools |
| `:input_source`   | `Syrus::Plugin::InputSource`          | `#poll!`, `#validate_credentials!`, `#config_schema`, `#dedup_key` |
| `:admin_page`     | `Syrus::Plugin::AdminPage`            | `.admin_pages` |
| `:chat_mcp_tool_set` | `Syrus::Plugin::ChatMcpToolSet`    | `.tool_definitions(tier:)`, `.available_for?(session, tier:)`, `#handle` |
| `:source_control_provider` | `Syrus::Plugin::SourceControlProvider` | `.provider_key`, `.display_name`, `.available_for?(repository)`, `.client_for(repository:, user:)` |
| `:grader_augmentor` | `Syrus::Plugin::GraderAugmentor`    | `.augment_grader_failure(name:, command:, workspace_path:)` → `Array<String>\|nil` |

`input_source` and `source_control_provider` are deliberately separate. A
source plugin can poll for new work without owning PR operations, and a
source-control provider can own branch/PR/merge operations without being a poll
source. The bundled `github_source` currently provides both and is marked
non-disableable until the remaining core GitHub behavior moves behind plugin
boundaries.

Admin page providers return page metadata:

```ruby
{
  id: "my_plugin.performance",
  label: "Performance",
  label_key: "my_plugin:nav_performance",
  path: "/admin/my_plugin/performance",
  paths: [ "/admin/my_plugin/performance" ],
  component: "my_plugin/AdminPerformance",
  order: 40
}
```

`label` is the fallback. `label_key` should resolve from a plugin locale file,
and `component` must match an installed frontend route module key.

A plugin can register any combination of extension points in a single call:

```ruby
Syrus::PluginRegistry.register(
  name:        "my_plugin",
  version:     MyPlugin::VERSION,
  description: "One-or-two sentence summary shown in the settings UI.",
  homepage:    "https://github.com/example/my_plugin",
  frontend:    {
    routes: {
      "my_plugin/AdminPerformance" => "app/frontend/routes/AdminPerformance.tsx"
    },
    i18n: [ "app/frontend/i18n/locales/*/my_plugin.json" ]
  },
  routes:      [
    { verb: "GET", path: "/admin/my_plugin/performance", controller: "spa#show" },
    { verb: "GET", path: "/api/v1/app/admin/my_plugin/performance", controller: "api/v1/app/admin/performance#show" }
  ],
  provides:    {
    agent_provider: MyPlugin::AgentProvider,
    chat_provider:  MyPlugin::ChatProvider,
    mcp_tool_set:   MyPlugin::McpToolSet,
    admin_page:     MyPlugin::AdminPages,
    source_control_provider: MyPlugin::SourceControl,
  }
)
```

`PluginRegistry.register` validates that each provided class includes the
corresponding interface module and raises `Syrus::PluginRegistry::RegistrationError`
if not. It also upserts a `PluginRecord` row so the operator can enable/disable
the plugin without touching the Gemfile (see below).

## Frontend and i18n

Plugin frontend code lives under `plugins/<name>/app/frontend`. The host Vite
build includes these files and discovers admin route components from
`plugins/*/app/frontend/routes/*.tsx`. A component file must default-export the
React component and is addressed as `<plugin>/<ComponentName>`.

Plugin frontend code should import host frontend APIs through `@app/*`, e.g.
`@app/hooks/useT`, instead of long relative paths.

Plugin locale files live under
`plugins/<name>/app/frontend/i18n/locales/<locale>/<namespace>.json` and are
merged into i18next whenever the plugin is installed. This does not depend on
the plugin being enabled.

Plugin Rails controllers can live under `plugins/<name>/app/controllers` and
inherit the host controller base classes. The host owns auth namespaces. Plugin
route metadata declares installed API/SPA routes: `/api/v1/app/*` and
`/api/v1/admin/*` metadata routes are served by the host plugin-route dispatcher
after concrete core routes, while `/admin/*` SPA metadata routes are accepted by
the SPA fallback. Runtime enable/disable checks happen in the controller or
extension point lookup.

## Install / uninstall flow

**Install:** `bundle add syrus_enterprise_x && bin/rails db:migrate && restart`

**Uninstall:** remove the gem from `Gemfile`, run `bundle install`, restart. The
registry is populated at boot time only, so removing the gem removes the extension
point implementations automatically.

## Enable / disable a plugin

`PluginRecord` is an ActiveRecord model backed by the `plugin_records` table.
Each registered plugin gets a row automatically on first boot. The manifest can
set `default_enabled:`, `disableable:`, and `category:`; existing enabled state
is preserved across restarts.

- **Disabling** (`PluginRecord#enabled = false`) takes effect immediately for new
  requests — `providers_for` re-queries the DB. The gem itself remains in memory
  until restart.
- **Re-enabling** a previously disabled installed plugin also takes effect
  immediately for new requests because the engine has already registered its
  providers in the current process.
- **Installing or removing** a plugin still requires changing the Gemfile,
  running Bundler, rebuilding frontend assets when applicable, and restarting
  Rails so the engine initializer runs or disappears.
- **Non-disableable** plugins are forced enabled. Avoid this for ordinary core
  runtime functionality; core behavior should generally live in the host app,
  with plugins used for capabilities that can genuinely be plugged out.

```ruby
PluginRecord.find_by!(name: "claude_agent").update!(enabled: false)
```

Bundled `syrus_dev` is disabled by default and owns Syrus-development-only
diagnostics, including the Performance admin page and the
`read_performance_diagnostics` / `read_syrus_logs` workflow MCP tools.

## Querying the registry

```ruby
Syrus::PluginRegistry.all_plugins          # → [Syrus::Plugin::Manifest, ...]
Syrus::PluginRegistry.providers_for(:agent_provider)  # → [Class, ...]

# Manifest now carries enabled state:
manifest = Syrus::PluginRegistry.all_plugins.first
manifest.enabled?   # → true / false
manifest.description
manifest.homepage
manifest.icon_url   # nil when not provided
```

## Testing plugins

Call `Syrus::PluginRegistry.reset!` in `around` blocks to isolate registry state
between examples:

```ruby
around do |ex|
  Syrus::PluginRegistry.reset!
  ex.run
  Syrus::PluginRegistry.reset!
end
```
