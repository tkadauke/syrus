# Syrus Plugins

This directory hosts bundled plugin gems. Each subdirectory is a self-contained
Rails Engine that registers one or more extension points with `Syrus::PluginRegistry`
at boot.

External (third-party) plugins are installed the same way as any gem: add them to
`Gemfile`, run `bundle install`, then restart the server.

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
| `:mcp_tool_set`   | `Syrus::Plugin::McpToolSet`           | `.tool_definitions`, `.available_for?`, `#handle` |
| `:input_source`   | `Syrus::Plugin::InputSource`          | `#poll!`, `#validate_credentials!`, `#config_schema`, `#dedup_key` |

A plugin can register any combination of extension points in a single call:

```ruby
Syrus::PluginRegistry.register(
  name:        "my_plugin",
  version:     MyPlugin::VERSION,
  description: "One-or-two sentence summary shown in the settings UI.",
  homepage:    "https://github.com/example/my_plugin",
  provides:    {
    agent_provider: MyPlugin::AgentProvider,
    mcp_tool_set:   MyPlugin::McpToolSet,
  }
)
```

`PluginRegistry.register` validates that each provided class includes the
corresponding interface module and raises `Syrus::PluginRegistry::RegistrationError`
if not. It also upserts a `PluginRecord` row so the operator can enable/disable
the plugin without touching the Gemfile (see below).

## Install / uninstall flow

**Install:** `bundle add syrus_enterprise_x && bin/rails db:migrate && restart`

**Uninstall:** remove the gem from `Gemfile`, run `bundle install`, restart. The
registry is populated at boot time only, so removing the gem removes the extension
point implementations automatically.

## Enable / disable a plugin

`PluginRecord` is an ActiveRecord model backed by the `plugin_records` table.
Each registered plugin gets a row automatically on first boot (via
`PluginRecord.find_or_create_by!(name:)` inside `register`).

- **Disabling** (`PluginRecord#enabled = false`) takes effect immediately for new
  requests — `providers_for` re-queries the DB. The gem itself remains in memory
  until restart.
- **Re-enabling** a previously disabled plugin requires a **restart**. The gem's
  engine won't have registered itself if it was never loaded into the current
  process; toggling `enabled` back to `true` without restarting will not restore
  its extension point implementations.

```ruby
PluginRecord.find_by!(name: "syrus-claude-agent").update!(enabled: false)
```

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
