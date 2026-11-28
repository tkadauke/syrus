import { registerPluginContribution, type PluginContributionKind } from "./pluginContributionRegistry"
import { warmableChunk } from "./lib/chunkWarmup"

// The built-in plugin feed for contributions that load on demand: routes,
// tabs, cards and slots. Startup imports this file; it only registers loaders.
//
// Contributions a consumer reads synchronously on first paint (tool cards,
// chat message and artifact renderers, provider connect panels, runtime
// session views) live in one builtInPlugin<Kind>.ts file per kind instead.
// Only their consumers import those files, so those modules -- and the chat
// infrastructure they share -- arrive with the first route that renders them
// rather than with startup, and are registered before its first render.
//
// Each lazy loader is warmable: background warm-up fetches plugin chunks after
// the core product routes and before administration (routes/routeChunks.ts).
const PLUGIN_CONTRIBUTION_WARMUP = { priority: 2 }
const PLUGIN_ROUTE_WARMUP = { priority: 3 }

type PluginModule = {
  default?: unknown
}

type PluginModuleLoader = () => Promise<PluginModule>
type EagerPluginModule = PluginModule

const routeModules = import.meta.glob<PluginModule>(["../../plugins/*/app/frontend/routes/*.tsx", "!../../plugins/*/app/frontend/routes/*.test.tsx"])
const workspaceTabModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/workspaceTabs/*.tsx",
  "!../../plugins/*/app/frontend/workspaceTabs/*.test.tsx"
])
const repoPageTabModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/repo_tabs/*.tsx",
  "!../../plugins/*/app/frontend/repo_tabs/*.test.tsx"
])
const slugPreviewCardModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/slugPreviewCards/*.tsx",
  "!../../plugins/*/app/frontend/slugPreviewCards/*.test.tsx"
])
const reviewContributionModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/review_contributions/*.tsx",
  "!../../plugins/*/app/frontend/review_contributions/*.test.tsx"
])
const reviewAnnotationModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/review_annotations/*.tsx",
  "!../../plugins/*/app/frontend/review_annotations/*.test.tsx"
])
const uiSlotModules = import.meta.glob<PluginModule>(["../../plugins/*/app/frontend/ui_slots/*.tsx", "!../../plugins/*/app/frontend/ui_slots/*.test.tsx"])
function registerModules(
  kind: PluginContributionKind,
  directory: string,
  modules: Record<string, PluginModuleLoader>,
  warmup: { priority: number } = PLUGIN_CONTRIBUTION_WARMUP
) {
  const pattern = new RegExp(`^\\.\\.\\/\\.\\.\\/plugins\\/([^/]+)\\/app\\/frontend\\/${directory}\\/([^/]+)\\.tsx$`)

  Object.entries(modules).forEach(([path, loader]) => {
    const match = path.match(pattern)
    // Keyed by module path, so a module registered under two kinds (a plugin
    // route is both an admin and a sidebar page candidate) shares one loader.
    if (match) registerPluginContribution(kind, match[1], match[2], warmableChunk(`plugin:${path}`, loader, warmup))
  })
}

export function registerEagerModules(kind: PluginContributionKind, directory: string, modules: Record<string, EagerPluginModule>) {
  const pattern = new RegExp(`^\\.\\.\\/\\.\\.\\/plugins\\/([^/]+)\\/app\\/frontend\\/${directory}\\/([^/]+)\\.tsx$`)
  Object.entries(modules).forEach(([path, module]) => {
    const match = path.match(pattern)
    if (match) registerPluginContribution(kind, match[1], match[2], module)
  })
}

registerModules("admin_page", "routes", routeModules, PLUGIN_ROUTE_WARMUP)
registerModules("sidebar_page", "routes", routeModules, PLUGIN_ROUTE_WARMUP)
registerModules("workspace_tab", "workspaceTabs", workspaceTabModules)
registerModules("repo_page_tab", "repo_tabs", repoPageTabModules)
registerModules("slug_preview_card", "slugPreviewCards", slugPreviewCardModules)
registerModules("review_contribution", "review_contributions", reviewContributionModules)
registerModules("review_annotation", "review_annotations", reviewAnnotationModules)
registerModules("ui_slot", "ui_slots", uiSlotModules)
