import { useState } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { connectOnboardingProvider } from "../api/credentials"
import { Button } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { useT } from "../hooks/useT"
import { GeminiSetupSheet } from "./GeminiSetupSheet"
import { Modal } from "./Modal"
import { StatusBox } from "./credentials/ConnectFlowUi"
import { pluginAgentProviderConnectPanelProviders } from "../pluginAgentProviderConnectPanels"
import { AgentProviderConnectPanel } from "./AgentProviderConnectPanel"

const AGENT_PROVIDER_TABS = pluginAgentProviderConnectPanelProviders()

export function ConfigureAgentModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  // settings namespace is the default (bare `configure_agent.*` keys); the
  // Gemini setup sheet's copy lives in the chat namespace (shared with Chat.tsx).
  const { t } = useT(["settings", "chat"])
  const queryClient = useQueryClient()
  const geminiSheetLabels = {
    title: t("chat:gemini_setup_title"),
    intro: t("chat:gemini_setup_intro"),
    getKey: t("chat:gemini_setup_get_key"),
    keyPlaceholder: t("chat:gemini_setup_placeholder"),
    validateAndSave: t("chat:gemini_setup_save"),
    validating: t("chat:gemini_setup_validating"),
    stageFormat: t("chat:gemini_stage_format"),
    stageReach: t("chat:gemini_stage_reach"),
    stageVideo: t("chat:gemini_stage_video"),
    saved: t("chat:gemini_setup_saved"),
    keyHelp: t("chat:gemini_setup_key_help")
  }
  const [tab, setTab] = useState<string>(AGENT_PROVIDER_TABS.includes("claude") ? "claude" : (AGENT_PROVIDER_TABS[0] ?? "gemini"))
  const [geminiSheetOpen, setGeminiSheetOpen] = useState(false)
  const [geminiConfigured, setGeminiConfigured] = useState(false)
  // Fires after a connect panel's own credential save/probe succeeds — the
  // one place onboarding auto-enables the plugin behind the provider the
  // operator just connected, so it doesn't have to be toggled on separately
  // from Admin -> Plugins. Settings' credential cards never call this.
  const connectProvider = useMutation({
    mutationFn: (provider: string) => connectOnboardingProvider(provider),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["credentials"] })
  })

  return (
    // When the nested Gemini sheet is open, closeOnEscape is disabled here so
    // ITS Escape handler closes the sheet only — otherwise both Modal
    // instances would react to the same keypress and tear down this modal too.
    <Modal
      className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
      closeOnEscape={!geminiSheetOpen}
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
              panel (pluginAgentProviderConnectPanelProviders), so a
              disabled-by-default provider is still reachable and
              connectable here — onboarding is the one place that must hold
              regardless of plugin enabled state. Gemini isn't an agent
              provider (it powers walkthrough-video analysis), so it stays a
              separate, hardcoded tab. */}
          <div className="flex flex-wrap border-b border-gray-200 dark:border-gray-700" role="tablist">
            {AGENT_PROVIDER_TABS.map((provider) => (
              <button
                aria-selected={tab === provider}
                className={tabClass(tab === provider)}
                key={provider}
                onClick={() => setTab(provider)}
                role="tab"
                type="button"
              >
                {providerTabLabel(t, provider)}
              </button>
            ))}
            <button
              aria-selected={tab === "gemini"}
              className={tabClass(tab === "gemini")}
              onClick={() => setTab("gemini")}
              role="tab"
              title={t('configure_agent.gemini_title')}
              type="button"
            >
              {t('configure_agent.tab_gemini')}
            </button>
          </div>

          {AGENT_PROVIDER_TABS.includes(tab) ? (
            <AgentProviderConnectPanel
              key={tab}
              onCancel={onClose}
              onSaved={() => {
                connectProvider.mutate(tab)
                onSaved?.()
              }}
              provider={tab}
              secondaryAction={(ambientReady) => (
                <Button onClick={onClose} variant="secondary">
                  {ambientReady ? t('configure_agent.skip_for_now') : t('configure_agent.cancel')}
                </Button>
              )}
            />
          ) : null}

          {tab === "gemini" ? (
            <div className="space-y-4">
              <p className="text-sm text-gray-600 dark:text-gray-400">
                {t('configure_agent.gemini_tab_intro')}
              </p>
              {geminiConfigured ? (
                <>
                  <StatusBox tone="ok">{t('configure_agent.gemini_tab_configured')}</StatusBox>
                  <div className="flex justify-end">
                    <Button onClick={onClose}>
                      {t('configure_agent.done')}
                    </Button>
                  </div>
                </>
              ) : (
                <div className="flex items-center justify-end gap-2">
                  <Button onClick={onClose} variant="secondary">
                    {t('configure_agent.skip_for_now')}
                  </Button>
                  <Button onClick={() => setGeminiSheetOpen(true)}>
                    {t('configure_agent.gemini_tab_add_key')}
                  </Button>
                </div>
              )}
            </div>
          ) : null}
        </div>
      {geminiSheetOpen ? (
        // Stop backdrop clicks in the nested sheet from bubbling to this
        // modal's own onClose — otherwise dismissing the sheet also closes
        // the whole Configure-agent modal.
        <div onClick={(event) => event.stopPropagation()}>
          <GeminiSetupSheet
            labels={geminiSheetLabels}
            onClose={() => setGeminiSheetOpen(false)}
            onConfigured={() => {
              setGeminiSheetOpen(false)
              setGeminiConfigured(true)
              onSaved?.()
            }}
          />
        </div>
      ) : null}
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
