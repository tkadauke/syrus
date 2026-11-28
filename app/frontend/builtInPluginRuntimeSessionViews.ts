import { registerEagerModules } from "./builtInPluginContributions"

type PluginModule = {
  default?: unknown
}

// Built-in plugin runtime session views, registered eagerly because pluginRuntimeSessionViews.tsx reads them
// synchronously while rendering. Only that consumer imports this file;
// startup imports builtInPluginContributions.ts, which registers loaders only.
// These modules therefore arrive with the first chunk that renders them and
// are registered before its first render.
const runtimeSessionViewModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/runtimeSessionViews/*.tsx", "!../../plugins/*/app/frontend/runtimeSessionViews/*.test.tsx"],
  { eager: true }
)

registerEagerModules("runtime_session_view", "runtimeSessionViews", runtimeSessionViewModules)
