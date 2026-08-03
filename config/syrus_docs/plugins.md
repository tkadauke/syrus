# Plugins

Syrus plugins are Rails Engine gems that register extension point providers at
boot through `Syrus::PluginRegistry`. The registry currently supports:

- `agent_provider`
- `mcp_tool_set`
- `input_source`

Operators can inspect the registered plugins from **Admin → Plugins**
(`/admin/plugins`). The page is read-only: it shows each plugin's name,
version, enabled state, author/source metadata when available, and every class
registered for an extension point.

Availability is reported per extension point. Agent providers run the provider
class's `.available?` check. Input sources show how many repository
`InputSource` records use that source class. MCP tool sets are listed as
registered because their runtime availability depends on the repository context
that invokes the sidecar.

Plugin install and uninstall remain manual operations: edit the Gemfile, run
Bundler, run migrations if the plugin ships any, and restart the Rails
processes so plugin engine initializers register with the in-memory registry.
