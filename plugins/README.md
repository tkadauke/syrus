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
  name:     "my_plugin",
  version:  MyPlugin::VERSION,
  provides: {
    agent_provider: MyPlugin::AgentProvider,
    mcp_tool_set:   MyPlugin::McpToolSet,
  }
)
```

`PluginRegistry.register` validates that each provided class includes the
corresponding interface module and raises `Syrus::PluginRegistry::RegistrationError`
if not.

## Install / uninstall flow

**Install:** `bundle add syrus_enterprise_x && bin/rails db:migrate && restart`

**Uninstall:** remove the gem from `Gemfile`, run `bundle install`, restart. The
registry is populated at boot time only, so removing the gem removes the extension
point implementations automatically.

## Querying the registry

```ruby
Syrus::PluginRegistry.all_plugins          # → [Syrus::Plugin::Manifest, ...]
Syrus::PluginRegistry.providers_for(:agent_provider)  # → [Class, ...]
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
