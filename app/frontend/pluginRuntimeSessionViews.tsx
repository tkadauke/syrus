import type { ComponentType } from "react"
import type { RuntimeControlLease, RuntimeSession } from "./api/chats"
import { getEagerPluginContributions } from "./pluginContributionRegistry"
import { withPluginErrorBoundary } from "./components/PluginErrorBoundary"
import "./builtInPluginRuntimeSessionViews"

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

function registeredViews() {
  return getEagerPluginContributions<PluginModule>("runtime_session_view").flatMap(({ pluginName, key, value: mod }) => {
    const view = mod.default
    if (!view?.providerKey || !view.component) {
      console.warn(`[pluginRuntimeSessionViews] Skipping ${pluginName}/${key}: default export is not a valid PluginRuntimeSessionView`)
      return []
    }

    return [{ ...view, component: withPluginErrorBoundary(pluginName, view.component) }]
  })
}

export function pluginRuntimeSessionViewComponentFor(providerKey: string | null | undefined) {
  if (!providerKey) return null
  return registeredViews().find((view) => view.providerKey === providerKey)?.component ?? null
}

function capabilityStrings(value: unknown): string[] {
  if (typeof value === "string") return [value]
  if (Array.isArray(value)) return value.filter((candidate): candidate is string => typeof candidate === "string")
  if (value && typeof value === "object") return Object.values(value).flatMap(capabilityStrings)

  return []
}

export function runtimeSessionInputEnabled(session: RuntimeSession, myLease: RuntimeControlLease | null) {
  const inputCapabilities = capabilityStrings(session.capabilities.input).map((value) => value.toLowerCase())
  return Boolean(inputCapabilities.length > 0 && myLease && myLease.owner === "user" && myLease.mode === "input" && !session.active_agent_input_lease)
}
