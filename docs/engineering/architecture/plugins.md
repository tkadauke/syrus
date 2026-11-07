# Plugins and extension points

`Syrus::PluginRegistry` is the single registration boundary for optional
capabilities. Core asks registries for implementations instead of referencing
bundled plugin constants. Extension points cover agent and content providers,
workflow kinds, execution backends, input sources, source control, MCP tools,
sidebars and repository tabs, runtime services, memory, search, domain events,
and other subsystem contracts.

Bundled plugins live under `plugins/<name>/`; third-party plugins are Rails
Engine gems. A plugin owns its models, migrations, services, jobs, routes,
frontend contribution, tests, and operator docs. Core may define the interface
and discover contributions, but deleting the plugin directory must not leave
core references that prevent boot.

Enablement and settings are durable, while manifests declare identity,
dependencies, extension points, and runtime services. Boot-time registration
must be deterministic and safe across reloads. Runtime subprocesses go through
`plugin_runtime` rather than being supervised from unrelated call sites.

Start with `lib/syrus/plugin_registry.rb`, `lib/syrus/plugin_api.rb`,
`lib/syrus/installer.rb`, `config/initializers/plugin_registry.rb`, and plugin
manifests under `plugins/`. Mandatory implementation and deletion-audit
rules are in [Plugin conventions](../conventions/plugins.md); operator-facing
plugin docs remain under `plugins/<name>/docs/`.
