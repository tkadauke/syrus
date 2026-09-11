import type { ComponentType, ReactNode } from "react"

export type AgentProviderConnectPanelProps = {
  autoFocus?: boolean
  onConnected: (result: { message?: string | null }) => void
  onPreflight?: (ready: boolean) => void
  secondaryAction?: ReactNode
}

export type PluginAgentProviderConnectPanel = {
  provider: string
  component: ComponentType<AgentProviderConnectPanelProps>
}

type PluginModule = {
  default?: PluginAgentProviderConnectPanel
}

const panelModules = import.meta.glob<PluginModule>(
  [
    "../../plugins/*/app/frontend/agentProviderConnectPanels/*.tsx",
    "!../../plugins/*/app/frontend/agentProviderConnectPanels/*.test.tsx"
  ],
  { eager: true }
)

const registeredPanels = Object.entries(panelModules).flatMap(([path, mod]) => {
  const panel = mod.default
  if (!panel?.provider || !panel.component) {
    console.warn(`[pluginAgentProviderConnectPanels] Skipping ${path}: default export is not a valid PluginAgentProviderConnectPanel`)
    return []
  }

  return [panel]
})

export function pluginAgentProviderConnectPanelComponentFor(provider: string | null | undefined) {
  if (!provider) return null
  return registeredPanels.find((panel) => panel.provider === provider)?.component ?? null
}

export function pluginAgentProviderConnectPanelProviders() {
  return registeredPanels.map((panel) => panel.provider).sort()
}
