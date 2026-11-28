import { registerEagerModules } from "./builtInPluginContributions"

type PluginModule = {
  default?: unknown
}

// Built-in plugin agent provider connect panels, registered eagerly because pluginAgentProviderConnectPanels.tsx reads them
// synchronously while rendering. Only that consumer imports this file;
// startup imports builtInPluginContributions.ts, which registers loaders only.
// These modules therefore arrive with the first chunk that renders them and
// are registered before its first render.
const agentProviderConnectPanelModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/agentProviderConnectPanels/*.tsx", "!../../plugins/*/app/frontend/agentProviderConnectPanels/*.test.tsx"],
  { eager: true }
)

registerEagerModules("agent_provider_connect_panel", "agentProviderConnectPanels", agentProviderConnectPanelModules)
