import { registerPluginContribution, type PluginContributionKind } from "./pluginContributionRegistry"

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
const toolCardModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/tool_cards/*.tsx", "!../../plugins/*/app/frontend/tool_cards/*.test.tsx"],
  { eager: true }
)
const chatMessageRendererModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/chat_message_renderers/*.tsx", "!../../plugins/*/app/frontend/chat_message_renderers/*.test.tsx"],
  { eager: true }
)
const artifactRendererModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/artifact_renderers/*.tsx", "!../../plugins/*/app/frontend/artifact_renderers/*.test.tsx"],
  { eager: true }
)
const agentProviderConnectPanelModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/agentProviderConnectPanels/*.tsx", "!../../plugins/*/app/frontend/agentProviderConnectPanels/*.test.tsx"],
  { eager: true }
)
const runtimeSessionViewModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/runtimeSessionViews/*.tsx", "!../../plugins/*/app/frontend/runtimeSessionViews/*.test.tsx"],
  { eager: true }
)

function registerModules(kind: PluginContributionKind, directory: string, modules: Record<string, PluginModuleLoader>) {
  const pattern = new RegExp(`^\\.\\.\\/\\.\\.\\/plugins\\/([^/]+)\\/app\\/frontend\\/${directory}\\/([^/]+)\\.tsx$`)

  Object.entries(modules).forEach(([path, loader]) => {
    const match = path.match(pattern)
    if (match) registerPluginContribution(kind, match[1], match[2], loader)
  })
}

function registerEagerModules(kind: PluginContributionKind, directory: string, modules: Record<string, EagerPluginModule>) {
  const pattern = new RegExp(`^\\.\\.\\/\\.\\.\\/plugins\\/([^/]+)\\/app\\/frontend\\/${directory}\\/([^/]+)\\.tsx$`)
  Object.entries(modules).forEach(([path, module]) => {
    const match = path.match(pattern)
    if (match) registerPluginContribution(kind, match[1], match[2], module)
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
registerEagerModules("tool_card", "tool_cards", toolCardModules)
registerEagerModules("chat_message_renderer", "chat_message_renderers", chatMessageRendererModules)
registerEagerModules("artifact_renderer", "artifact_renderers", artifactRendererModules)
registerEagerModules("agent_provider_connect_panel", "agentProviderConnectPanels", agentProviderConnectPanelModules)
registerEagerModules("runtime_session_view", "runtimeSessionViews", runtimeSessionViewModules)
