import { useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { ClaudeConnect, StatusBox } from "@plugins/claude_agent/app/frontend/components/credentials/ClaudeConnect"
import { Button } from "./Button"
import { useT } from "../hooks/useT"

export type ConnectableAgentProvider = "claude"

export function agentProviderHasConnectPanel(provider: string): provider is ConnectableAgentProvider {
  return provider === "claude"
}

export function AgentProviderConnectPanel({
  provider,
  onCancel,
  onSaved,
  secondaryAction,
  autoFocus = false
}: {
  provider: ConnectableAgentProvider
  onCancel: () => void
  onSaved?: () => void
  secondaryAction?: (ambientReady: boolean) => ReactNode
  autoFocus?: boolean
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [ambientReady, setAmbientReady] = useState(false)
  const [connected, setConnected] = useState<string | null>(null)

  if (connected) {
    return (
      <div className="space-y-5">
        <StatusBox tone="ok">{connected}</StatusBox>
        <div className="flex justify-end">
          <Button onClick={onCancel}>
            {t('configure_agent.done')}
          </Button>
        </div>
      </div>
    )
  }

  return (
    <ClaudeConnect
      autoFocus={autoFocus}
      onConnected={async (result) => {
        setConnected(result.message || t('configure_agent.connected_default'))
        await queryClient.invalidateQueries({ queryKey: ["dashboard"] })
        await queryClient.invalidateQueries({ queryKey: ["chats"] })
        await queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
        onSaved?.()
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
