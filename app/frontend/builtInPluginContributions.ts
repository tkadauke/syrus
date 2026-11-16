import { registerPluginContribution, type PluginContributionKind } from "./pluginContributionRegistry"

type PluginModule = {
  default?: unknown
}

type PluginModuleLoader = () => Promise<PluginModule>

const routeModules = import.meta.glob<PluginModule>(["../../plugins/*/app/frontend/routes/*.tsx", "!../../plugins/*/app/frontend/routes/*.test.tsx"])
const workspaceTabModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/workspaceTabs/*.tsx",
  "!../../plugins/*/app/frontend/workspaceTabs/*.test.tsx"
])
const repoPageTabModules = import.meta.glob<PluginModule>(["../../plugins/*/app/frontend/repo_tabs/*.tsx", "!../../plugins/*/app/frontend/repo_tabs/*.test.tsx"])
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

function registerModules(kind: PluginContributionKind, directory: string, modules: Record<string, PluginModuleLoader>) {
  const pattern = new RegExp(`^\\.\\.\\/\\.\\.\\/plugins\\/([^/]+)\\/app\\/frontend\\/${directory}\\/([^/]+)\\.tsx$`)

  Object.entries(modules).forEach(([path, loader]) => {
    const match = path.match(pattern)
    if (match) registerPluginContribution(kind, match[1], match[2], loader)
  })
}

registerModules("admin_page", "routes", routeModules)
registerModules("sidebar_page", "routes", routeModules)
registerModules("workspace_tab", "workspaceTabs", workspaceTabModules)
registerModules("repo_page_tab", "repo_tabs", repoPageTabModules)
registerModules("slug_preview_card", "slugPreviewCards", slugPreviewCardModules)
registerModules("review_contribution", "review_contributions", reviewContributionModules)
registerModules("review_annotation", "review_annotations", reviewAnnotationModules)
registerModules("ui_slot", "ui_slots", uiSlotModules)
