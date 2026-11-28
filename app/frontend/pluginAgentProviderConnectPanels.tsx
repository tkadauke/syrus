import type { ComponentType, ReactNode } from "react"
import { getEagerPluginContributions } from "./pluginContributionRegistry"
import { withPluginErrorBoundary } from "./components/PluginErrorBoundary"
import "./builtInPluginAgentProviderConnectPanels"

export type AgentProviderConnectPanelProps = {
  autoFocus?: boolean
  deferBootstrapRefresh?: boolean
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

function registeredPanels() {
  return getEagerPluginContributions<PluginModule>("agent_provider_connect_panel").flatMap(({ pluginName, key, value: mod }) => {
    const panel = mod.default
    if (!panel?.provider || !panel.component) {
      console.warn(`[pluginAgentProviderConnectPanels] Skipping ${pluginName}/${key}: default export is not a valid PluginAgentProviderConnectPanel`)
      return []
    }

    return [{ ...panel, component: withPluginErrorBoundary(pluginName, panel.component) }]
  })
}

export function pluginAgentProviderConnectPanelComponentFor(provider: string | null | undefined) {
  if (!provider) return null
  return registeredPanels().find((panel) => panel.provider === provider)?.component ?? null
}

// Popular-to-less-popular display order for onboarding; any provider not
// listed here (a future plugin) sorts alphabetically after these.
const PROVIDER_DISPLAY_ORDER = ["claude", "codex", "agy", "muse"]

export function pluginAgentProviderConnectPanelProviders() {
  return registeredPanels()
    .map((panel) => panel.provider)
    .sort((a, b) => providerDisplayRank(a) - providerDisplayRank(b) || a.localeCompare(b))
}

function providerDisplayRank(provider: string) {
  const index = PROVIDER_DISPLAY_ORDER.indexOf(provider)
  return index === -1 ? PROVIDER_DISPLAY_ORDER.length : index
}
