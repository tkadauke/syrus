import { registerPluginContribution } from "./pluginContributionRegistry"

type PluginModule = { default?: unknown }

function registerGlob(kind: "workspace_tab" | "admin_page" | "sidebar_page", modules: Record<string, () => Promise<PluginModule>>, pathPattern: RegExp) {
  Object.entries(modules).forEach(([path, loader]) => {
    const match = path.match(pathPattern)
    if (!match) return

    const pluginName = match[1]
    const key = `${pluginName}/${match[2]}`
    registerPluginContribution(kind, pluginName, key, loader)
  })
}

const workspaceTabModules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/workspaceTabs/*.tsx",
  "!../../plugins/*/app/frontend/workspaceTabs/*.test.tsx"
])
const routeModules = import.meta.glob<PluginModule>(["../../plugins/*/app/frontend/routes/*.tsx", "!../../plugins/*/app/frontend/routes/*.test.tsx"])

registerGlob("workspace_tab", workspaceTabModules, /^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/workspaceTabs\/([^/.]+)\.tsx$/)
registerGlob("admin_page", routeModules, /^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/routes\/([^/.]+)\.tsx$/)
registerGlob("sidebar_page", routeModules, /^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/routes\/([^/.]+)\.tsx$/)
