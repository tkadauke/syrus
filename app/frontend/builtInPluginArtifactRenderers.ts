import { registerEagerModules } from "./builtInPluginContributions"

type PluginModule = {
  default?: unknown
}

// Built-in plugin artifact renderers, registered eagerly because pluginArtifactRenderers.tsx reads them
// synchronously while rendering. Only that consumer imports this file;
// startup imports builtInPluginContributions.ts, which registers loaders only.
// These modules therefore arrive with the first chunk that renders them and
// are registered before its first render.
const artifactRendererModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/artifact_renderers/*.tsx", "!../../plugins/*/app/frontend/artifact_renderers/*.test.tsx"],
  { eager: true }
)

registerEagerModules("artifact_renderer", "artifact_renderers", artifactRendererModules)
