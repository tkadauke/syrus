import type { ComponentType } from "react"
import type { RuntimeControlLease, RuntimeSession } from "./api/chats"

export type RuntimeSessionViewConnectionState = {
  connected: boolean
  ended: boolean
}

export type PluginRuntimeSessionViewProps = {
  session: RuntimeSession
  inputEnabled: boolean
  onConnectionChange?: (state: RuntimeSessionViewConnectionState) => void
}

export type PluginRuntimeSessionView = {
  providerKey: string
  component: ComponentType<PluginRuntimeSessionViewProps>
}

type PluginModule = {
  default?: PluginRuntimeSessionView
}

const viewModules = import.meta.glob<PluginModule>(
  [
    "../../plugins/*/app/frontend/runtimeSessionViews/*.tsx",
    "!../../plugins/*/app/frontend/runtimeSessionViews/*.test.tsx"
  ],
  { eager: true }
)

const registeredViews = Object.entries(viewModules).flatMap(([ path, mod ]) => {
  const view = mod.default
  if (!view?.providerKey || !view.component) {
    console.warn(`[pluginRuntimeSessionViews] Skipping ${path}: default export is not a valid PluginRuntimeSessionView`)
    return []
  }

  return [ view ]
})

export function pluginRuntimeSessionViewComponentFor(providerKey: string | null | undefined) {
  if (!providerKey) return null
  return registeredViews.find((view) => view.providerKey === providerKey)?.component ?? null
}

export function runtimeSessionInputEnabled(session: RuntimeSession, myLease: RuntimeControlLease | null) {
  return Boolean(myLease && myLease.owner === "user" && myLease.mode === "input" && !session.active_agent_input_lease)
}
