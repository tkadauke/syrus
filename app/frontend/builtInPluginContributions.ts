import { registerPluginContribution, type PluginContributionKind } from "./pluginContributionRegistry"

type PluginModule = {
  default?: unknown
}

type PluginModuleLoader = () => Promise<PluginModule>

const routeModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/routes/*.tsx",
  "!../../plugins/*/app/frontend/routes/*.test.tsx"
])
const workspaceTabModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/workspaceTabs/*.tsx",
  "!../../plugins/*/app/frontend/workspaceTabs/*.test.tsx"
])

function registerModules(kind: PluginContributionKind, directory: string, modules: Record<string, PluginModuleLoader>) {
  const pattern = new RegExp(`^\\.\\.\\/\\.\\.\\/plugins\\/([^/]+)\\/app\\/frontend\\/${directory}\\/([^/.]+)\\.tsx$`)

  Object.entries(modules).forEach(([path, loader]) => {
    const match = path.match(pattern)
    if (match) registerPluginContribution(kind, match[1], match[2], loader)
  })
}

registerModules("admin_page", "routes", routeModules)
registerModules("sidebar_page", "routes", routeModules)
registerModules("workspace_tab", "workspaceTabs", workspaceTabModules)
