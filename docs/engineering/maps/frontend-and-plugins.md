# Frontend and plugin map

| Concern | Primary locations |
| --- | --- |
| React entry/router | `app/frontend/` route and application entry files |
| Feature routes | `app/frontend/routes/` |
| Shared components | `app/frontend/components/` |
| Query/API clients | `app/frontend/lib/`, feature query modules |
| Chat cards | `app/frontend/routes/chat/`, `app/frontend/routes/chat/tool_cards/` |
| Rails SPA shells | `config/routes.rb`, app controllers serving frontend entry points |
| API payloads | `app/services/app/`, `app/controllers/api/v1/app/` |
| Localization | frontend locale resources and Rails `config/locales/` |
| Plugin registry/loader | `lib/syrus/plugin_registry.rb`, `lib/syrus/plugin_api.rb`, `lib/syrus/installer.rb`, `config/initializers/plugin_registry.rb` |
| Bundled plugins | `plugins/<name>/` |
| Plugin frontend contributions | `plugins/<name>/app/frontend/` |
| Plugin operator docs | `plugins/<name>/docs/` |
| MCP registries/tools | `app/services/mcp_tool_registry.rb`, `app/services/mcp/`, `app/services/syrus_mcp/` |
| Sidecar entry points | `bin/syrus-mcp-daemon`, `bin/syrus-mcp-proxy`, `bin/syrus-mcp-sidecar` |

See [Frontend surfaces](../architecture/frontend.md) and
[Plugins](../architecture/plugins.md).
