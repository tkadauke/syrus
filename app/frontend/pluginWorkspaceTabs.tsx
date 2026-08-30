import { lazy, type ComponentType } from "react"
import type { ChatPayload, ChatWorkspaceTab } from "./api/chats"

// Discovers plugin-supplied chat workspace tab components, the same
// import.meta.glob-based convention pluginAdminPages.tsx uses for admin
// pages: a plugin declares tab metadata (id, label, component key) via the
// :workspace_tab extension point (see Syrus::Plugin::WorkspaceTab), and the
// component itself lives at plugins/<name>/app/frontend/workspaceTabs/<Name>.tsx,
// keyed here as "<name>/<Name>".
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

const workspaceTabModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/workspaceTabs/*.tsx")

const componentLoaders = Object.fromEntries(
  Object.entries(workspaceTabModules).map(([path, loader]) => {
    const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/workspaceTabs\/([^/.]+)\.tsx$/)
    if (!match) return []

    return [ `${match[1]}/${match[2]}`, loader ]
  }).filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType<PluginWorkspaceTabProps>>()

export function pluginWorkspaceTabComponentKeys() {
  return Object.keys(componentLoaders).sort()
}

export function pluginWorkspaceTabComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin workspace tab component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}
