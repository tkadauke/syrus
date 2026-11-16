import { lazy, type ComponentType } from "react"
import type { ChatPayload, ChatWorkspaceTab } from "./api/chats"
import { loadPluginModule } from "./i18n"
import "./builtInPluginContributions"
import { getPluginContribution, getPluginContributions, pluginContributionLoader } from "./pluginContributionRegistry"

// Resolves plugin-supplied chat workspace tab components from the shared
// contribution registry. A plugin declares tab metadata (id, label, component
// key) via the :workspace_tab extension point (see
// Syrus::Plugin::WorkspaceTab), and the component itself lives at
// plugins/<name>/app/frontend/workspaceTabs/<Name>.tsx, keyed here as
// "<name>/<Name>".
//
// Unlike a standalone admin route (which derives its context from the URL),
// a workspace tab renders inside one specific chat, so its component
// receives the chat's payload as a prop instead of fetching by route param.
export type PluginWorkspaceTabProps = {
  payload: ChatPayload
  tab?: ChatWorkspaceTab
}

type PluginModule = {
  default?: ComponentType<PluginWorkspaceTabProps>
}

const componentCache = new Map<string, ComponentType<PluginWorkspaceTabProps>>()

export function pluginWorkspaceTabComponentKeys() {
  return getPluginContributions<PluginModule>("workspace_tab")
    .map(({ pluginName, key }) => `${pluginName}/${key}`)
    .sort()
}

export function pluginWorkspaceTabComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const [pluginName, componentKey] = key.split("/", 2)
  const contribution = getPluginContribution<PluginModule>("workspace_tab", pluginName, componentKey)
  if (!contribution) return null

  const Component = lazy(async () => {
    const mod = await loadPluginModule(pluginName, pluginContributionLoader(contribution))
    if (!mod.default) throw new Error(`Plugin workspace tab component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}
