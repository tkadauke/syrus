# Plugins

Syrus plugins are Rails Engine gems that register extension point providers at
boot through `Syrus::PluginRegistry`. The registry currently supports:

- `agent_provider`
- `mcp_tool_set`
- `input_source`
- `test_result_parser`
- `coverage_analyzer`
- `preview_provider`
- `artifact_renderer`

Operators can inspect the registered plugins from **Admin → Plugins**
(`/admin/plugins`). The page is read-only: it shows each plugin's name,
version, enabled state, author/source metadata when available, and every class
registered for an extension point.

Availability is reported per extension point. Agent providers run the provider
class's `.available?` check. Input sources show how many repository
`InputSource` records use that source class. MCP tool sets are listed as
registered because their runtime availability depends on the repository context
that invokes the sidecar. Test result parsers and coverage analyzers are listed
as registered parser classes.

## `artifact_renderer`

Maps agent-submitted artifact types to a core frontend renderer. Include
`Syrus::Plugin::ArtifactRenderer` and implement two class methods:

| Method | Returns | Description |
|---|---|---|
| `.artifact_type` | `String` | Artifact type identifier (e.g. `"rails_schema_erd"`) |
| `.renderer_type` | `Symbol` | One of `:erd_diagram`, `:migration_diff`, `:data_table`, `:before_after_diff` |
| `.payload_schema` | `Hash\|nil` | Optional JSON Schema for the payload (documentation only, not validated) |

A plugin may register multiple renderer classes by passing an array to the
`:artifact_renderer` key:

```ruby
Syrus::PluginRegistry.register(
  name: "syrus_rails", version: "1.0.0",
  provides: { artifact_renderer: [SchemaErdRenderer, MigrationDiffRenderer] }
)
```

When a job's workflow contains `typed_artifacts`, the job detail page annotates
each entry with the matching `renderer_type` from registered renderers and
displays them in the **Artifacts** tab. Artifacts with no registered renderer
fall back to a raw JSON display.

## Plugin install and uninstall

Plugin install and uninstall remain manual operations: edit the Gemfile, run
Bundler, run migrations if the plugin ships any, and restart the Rails
processes so plugin engine initializers register with the in-memory registry.
