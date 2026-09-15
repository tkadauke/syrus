import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { fetchCredentials, savePartialCredentials } from "../api/credentials"
import { Button } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { useT } from "../hooks/useT"
import { GeminiSetupSheet } from "./GeminiSetupSheet"
import { errorMessage } from "../lib/errorMessage"
import { Modal } from "./Modal"
import { StatusBox } from "@plugins/claude_agent/app/frontend/components/credentials/ClaudeConnect"
import { AgentProviderConnectPanel } from "./AgentProviderConnectPanel"

type AgentTab = "claude" | "gemini" | "agy"

export function ConfigureAgentModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  // settings namespace is the default (bare `configure_agent.*` keys); the
  // Gemini setup sheet's copy lives in the chat namespace (shared with Chat.tsx).
  const { t } = useT(["settings", "chat"])
  const queryClient = useQueryClient()
  const credentials = useQuery({
    queryKey: ["credentials"],
    queryFn: fetchCredentials
  })
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
  const [tab, setTab] = useState<AgentTab>("claude")
  const [geminiSheetOpen, setGeminiSheetOpen] = useState(false)
  const [geminiConfigured, setGeminiConfigured] = useState(false)
  const agyConfigured = geminiConfigured ||
    Boolean(credentials.data?.credential_status.gemini_api_key) ||
    Boolean(credentials.data?.options?.agent_providers?.includes("agy")) ||
    Boolean(credentials.data?.options?.chat_providers?.includes("agy"))
  const agySelected = credentials.data?.user.agent_provider === "agy"
  const useAgy = useMutation({
    mutationFn: () => savePartialCredentials({ agent_provider: "agy" }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["credentials"] })
      await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      onSaved?.()
    }
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

          {/* Provider tabs. Codex lands in a follow-up step. */}
          <div className="flex flex-wrap border-b border-gray-200 dark:border-gray-700" role="tablist">
            <button
              aria-selected={tab === "claude"}
              className={tabClass(tab === "claude")}
              onClick={() => setTab("claude")}
              role="tab"
              type="button"
            >
              {t('configure_agent.tab_claude')}
            </button>
            <button
              aria-disabled="true"
              aria-selected={false}
              className="cursor-not-allowed px-4 py-2 text-sm font-medium text-gray-400 dark:text-gray-600"
              disabled
              role="tab"
              title={t('configure_agent.codex_title')}
              type="button"
            >
              {t('configure_agent.tab_codex')}
              <span className="ml-2 rounded bg-gray-100 px-1.5 py-0.5 text-2xs font-semibold uppercase text-gray-400 dark:bg-gray-800 dark:text-gray-500">{t('configure_agent.soon')}</span>
            </button>
            <button
              aria-selected={tab === "gemini"}
              className={tabClass(tab === "gemini")}
              onClick={() => setTab("gemini")}
              role="tab"
              title={t('configure_agent.gemini_title')}
              type="button"
            >
              {t('configure_agent.tab_gemini')}
              <span className="ml-2 rounded bg-gray-100 px-1.5 py-0.5 text-2xs font-semibold uppercase text-gray-400 dark:bg-gray-800 dark:text-gray-500">{t('configure_agent.soon')}</span>
            </button>
            {agyConfigured ? (
              <button
                aria-selected={tab === "agy"}
                className={tabClass(tab === "agy")}
                onClick={() => setTab("agy")}
                role="tab"
                title={t('configure_agent.agy_title')}
                type="button"
              >
                {t('configure_agent.tab_agy')}
              </button>
            ) : null}
          </div>

          {tab === "agy" && agyConfigured ? (
            <div className="space-y-4">
              <StatusBox tone="ok">
                {agySelected ? t('configure_agent.agy_tab_selected') : t('configure_agent.agy_tab_ready')}
              </StatusBox>
              {useAgy.isError ? (
                <StatusBox tone="error">
                  {errorMessage(useAgy.error, t('configure_agent.agy_tab_save_error'))}
                </StatusBox>
              ) : null}
              <div className="flex items-center justify-end gap-2">
                <Button onClick={onClose} variant="secondary">
                  {agySelected ? t('configure_agent.done') : t('configure_agent.skip_for_now')}
                </Button>
                {!agySelected ? (
                  <Button disabled={useAgy.isPending} onClick={() => useAgy.mutate()}>
                    {useAgy.isPending ? t('configure_agent.agy_tab_saving') : t('configure_agent.agy_tab_use')}
                  </Button>
                ) : null}
              </div>
            </div>
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
          {/* The Claude flow stays MOUNTED (display: none) while the Gemini
              tab is active: unmounting it mid-authorization would reset
              authStarted/code and, worse, tempt a re-Authorize that rotates
              the session's PKCE verifier — invalidating the code the user
              already copied. Pre-extraction this state lived at modal level
              and survived tab flips; keeping the component alive preserves
              that without giving up the shared extraction. */}
          <div className={tab === "claude" ? undefined : "hidden"}>
            <AgentProviderConnectPanel
              onCancel={onClose}
              onSaved={onSaved}
              provider="claude"
              secondaryAction={(ambientReady) => (
                <Button onClick={onClose} variant="secondary">
                  {ambientReady ? t('configure_agent.skip_for_now') : t('configure_agent.cancel')}
                </Button>
              )}
            />
          </div>
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
