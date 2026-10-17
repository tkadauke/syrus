import { useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { pluginAgentProviderConnectPanelComponentFor } from "../pluginAgentProviderConnectPanels"
import { Button } from "./Button"
import { useT } from "../hooks/useT"

export type ConnectableAgentProvider = string

export function agentProviderHasConnectPanel(provider: string): provider is ConnectableAgentProvider {
  return Boolean(pluginAgentProviderConnectPanelComponentFor(provider))
}

export function AgentProviderConnectPanel({
  provider,
  onCancel,
  onSaved,
  secondaryAction,
  autoFocus = false,
  deferBootstrapRefresh = false
}: {
  provider: ConnectableAgentProvider
  onCancel: () => void
  onSaved?: () => Promise<void> | void
  secondaryAction?: (ambientReady: boolean) => ReactNode
  autoFocus?: boolean
  deferBootstrapRefresh?: boolean
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [ambientReady, setAmbientReady] = useState(false)
  const [connected, setConnected] = useState<string | null>(null)
  const ProviderConnectPanel = pluginAgentProviderConnectPanelComponentFor(provider)

  if (!ProviderConnectPanel) return null

  if (connected) {
    return (
      <div className="space-y-5">
        <div className="rounded border px-3 py-2 text-sm border-green-200 bg-green-50 text-green-800 dark:border-green-900/60 dark:bg-green-950/30 dark:text-green-200">
          {connected}
        </div>
        <div className="flex justify-end">
          <Button onClick={onCancel}>
            {t('configure_agent.done')}
          </Button>
        </div>
      </div>
    )
  }

  return (
    <ProviderConnectPanel
      autoFocus={autoFocus}
      deferBootstrapRefresh={deferBootstrapRefresh}
      onConnected={async (result) => {
        await queryClient.invalidateQueries({ queryKey: ["dashboard"] })
        await queryClient.invalidateQueries({ queryKey: ["chats"] })
        await queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
        try {
          await onSaved?.()
          setConnected(result.message || t('configure_agent.connected_default'))
        } catch {
          // The host owns error presentation. In onboarding, keeping this
          // panel open avoids claiming success when provider selection failed.
        }
      }}
      onPreflight={setAmbientReady}
      secondaryAction={secondaryAction ? secondaryAction(ambientReady) : (
        <Button onClick={onCancel} variant="secondary">
          {ambientReady ? t('configure_agent.skip_for_now') : t('configure_agent.cancel')}
        </Button>
      )}
    />
  )
}
