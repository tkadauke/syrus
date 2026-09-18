import { useState } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { connectOnboardingProvider } from "../api/credentials"
import { Button } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { useT } from "../hooks/useT"
import { Modal } from "./Modal"
import { StatusBox } from "./credentials/ConnectFlowUi"
import { pluginAgentProviderConnectPanelProviders } from "../pluginAgentProviderConnectPanels"
import { AgentProviderConnectPanel } from "./AgentProviderConnectPanel"

const AGENT_PROVIDER_TABS = pluginAgentProviderConnectPanelProviders()
const INITIAL_TAB = AGENT_PROVIDER_TABS.includes("claude") ? "claude" : (AGENT_PROVIDER_TABS[0] ?? "")

export function ConfigureAgentModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [tab, setTab] = useState<string>(INITIAL_TAB)
  // Every provider tab the operator has opened stays mounted (hidden, not
  // unmounted) once visited. Unmounting mid-OAuth-flow (Claude, Codex) would
  // reset that panel's local authStarted/pasted-code state and can force a
  // re-Authorize that rotates the session's PKCE verifier, invalidating a
  // code the operator already copied.
  const [visitedProviderTabs, setVisitedProviderTabs] = useState<string[]>(
    AGENT_PROVIDER_TABS.includes(INITIAL_TAB) ? [INITIAL_TAB] : []
  )
  // Fires after a connect panel's own credential save/probe succeeds — the
  // one place onboarding auto-enables the plugin behind the provider the
  // operator just connected, so it doesn't have to be toggled on separately
  // from Admin -> Plugins. Settings' credential cards never call this.
  const connectProvider = useMutation({
    mutationFn: (provider: string) => connectOnboardingProvider(provider),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["credentials"] })
  })

  function selectTab(nextTab: string) {
    setTab(nextTab)
    connectProvider.reset()
    if (AGENT_PROVIDER_TABS.includes(nextTab)) {
      setVisitedProviderTabs((current) => (current.includes(nextTab) ? current : [ ...current, nextTab ]))
    }
  }

  return (
    <Modal
      className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
      labelledBy="configure-agent-title"
      onClose={onClose}
      open
    >
        <div className="space-y-5 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="configure-agent-title">
                {t('configure_agent.title')}
              </h2>
              <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
                {t('configure_agent.description')}
              </p>
            </div>
            <button
              aria-label={t('configure_agent.close')}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300 focus:outline-none focus:ring-2 focus:ring-brand"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>

          {/* Provider tabs come from every plugin with a registered connect
              panel (pluginAgentProviderConnectPanelProviders), ordered
              popular-to-less-popular, so a disabled-by-default provider is
              still reachable and connectable here — onboarding is the one
              place that must hold regardless of plugin enabled state.
              Gemini isn't an agent provider (it only powers walkthrough-video
              analysis) and isn't shown here; it stays configurable from
              Settings. */}
          <div className="flex flex-wrap border-b border-gray-200 dark:border-gray-700" role="tablist">
            {AGENT_PROVIDER_TABS.map((provider) => (
              <button
                aria-selected={tab === provider}
                className={tabClass(tab === provider)}
                key={provider}
                onClick={() => selectTab(provider)}
                role="tab"
                type="button"
              >
                {providerTabLabel(t, provider)}
              </button>
            ))}
          </div>

          {visitedProviderTabs.map((provider) => (
            <div hidden={tab !== provider} key={provider}>
              <AgentProviderConnectPanel
                onCancel={onClose}
                onSaved={() => {
                  connectProvider.mutate(provider)
                  onSaved?.()
                }}
                provider={provider}
                secondaryAction={(ambientReady) => (
                  <Button onClick={onClose} variant="secondary">
                    {ambientReady ? t('configure_agent.skip_for_now') : t('configure_agent.cancel')}
                  </Button>
                )}
              />
            </div>
          ))}

          {connectProvider.isError && AGENT_PROVIDER_TABS.includes(tab) ? (
            <StatusBox tone="warning">{t('configure_agent.auto_enable_error')}</StatusBox>
          ) : null}
        </div>
    </Modal>
  )
}

function tabClass(active: boolean) {
  const base = "px-4 py-2 text-sm font-medium -mb-px border-b-2"
  return active
    ? `${base} border-brand text-brand dark:text-brand-emphasis`
    : `${base} border-transparent text-gray-500 dark:text-gray-400`
}

function providerTabLabel(t: (key: string, options?: { defaultValue: string }) => string, provider: string) {
  const fallback = provider.charAt(0).toUpperCase() + provider.slice(1)
  return t(`configure_agent.tab_${provider}`, { defaultValue: fallback })
}
