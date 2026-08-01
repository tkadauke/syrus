import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import {
  clearAdminSettingSecret,
  fetchAdminSettings,
  startPlatformPolling,
  updateAdminSettings,
  type AdminSettingsPayload,
  type ClearableSecret
} from "../api/adminSettings"
import { NoticeToast } from "../components/NoticeToast"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import * as pageReload from "../lib/pageReload"
import { useConfirm } from "../hooks/useConfirm"

const queryKey = ["admin", "settings"] as const

export function AdminSettings() {
  const { t } = useT("admin")
  const [notice, setNotice] = useState<string | null>(null)
  const settings = useQuery({
    queryKey,
    queryFn: fetchAdminSettings
  })

  return (
    <main aria-label={t("aria_settings")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("settings.heading")}</h1>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {settings.isPending ? <PanelMessage>{t("settings.loading")}</PanelMessage> : null}
      {settings.isError ? <SettingsError error={settings.error} /> : null}
      {settings.isSuccess ? <SettingsView onNotice={setNotice} payload={settings.data} /> : null}
    </main>
  )
}

function SettingsView({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const otherSecrets = payload.settings.clearable_secrets.filter(s => s.key !== "telegram_bot_token")
  return (
    <>
      <TelegramSection onNotice={onNotice} payload={payload} />

      {otherSecrets.length > 0 && (
        <section className="divide-y divide-gray-200 dark:divide-gray-700 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          {otherSecrets.map((secret) => (
            <SecretRow key={secret.key} onNotice={onNotice} secret={secret} />
          ))}
        </section>
      )}

      <SettingsForm onNotice={onNotice} payload={payload} />
    </>
  )
}

function SecretRow({ secret, onNotice }: { secret: ClearableSecret; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const clearSecret = useMutation({
    mutationFn: () => clearAdminSettingSecret(secret.key),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || `${secret.label} cleared.`)
    }
  })

  return (
    <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
      <div>
        <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{secret.label}</div>
        <div className={`mt-1 text-xs ${secret.set ? "text-gray-500 dark:text-gray-400" : "text-amber-700 dark:text-amber-300"}`}>
          {secret.set ? t("settings.currently_set") : t("settings.not_set")}
        </div>
      </div>
      {secret.set ? (
        <button
          className="self-start rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:cursor-not-allowed disabled:text-red-300 sm:self-auto"
          disabled={clearSecret.isPending}
          onClick={async () => {
            if (await confirm({ message: t("settings.confirm_clear", { label: secret.label }), destructive: true })) {
              onNotice(null)
              clearSecret.mutate()
            }
          }}
          type="button"
        >
          {clearSecret.isPending ? t("settings.clearing") : t("settings.clear")}
        </button>
      ) : null}
      {clearSecret.isError ? <div className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(clearSecret.error, t("settings.error_clear"))}</div> : null}
      {dialog}
    </div>
  )
}

function SettingsForm({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [signupsOpen, setSignupsOpen] = useState(payload.settings.signups_open)
  const [videoRetentionDays, setVideoRetentionDays] = useState(String(payload.settings.video_retention_days))
  const [videoBudgetMb, setVideoBudgetMb] = useState(String(payload.settings.video_storage_budget_mb))
  const [maxConcurrentAgentRuns, setMaxConcurrentAgentRuns] = useState(String(payload.settings.max_concurrent_agent_runs))
  const [proactiveRebaseThreshold, setProactiveRebaseThreshold] = useState(String(payload.settings.proactive_rebase_commit_threshold))
  const [mode, setMode] = useState<"advanced" | "simple">(payload.settings.mode)
  const update = useMutation({
    mutationFn: () => updateAdminSettings({
      signups_open: signupsOpen,
      video_retention_days: Number(videoRetentionDays),
      video_storage_budget_mb: Number(videoBudgetMb),
      max_concurrent_agent_runs: Number(maxConcurrentAgentRuns),
      proactive_rebase_commit_threshold: Number(proactiveRebaseThreshold),
      mode
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("settings.settings_updated"))
      if (updated.settings.mode !== payload.settings.mode) pageReload.reloadPage()
    }
  })

  useEffect(() => {
    setSignupsOpen(payload.settings.signups_open)
    setVideoRetentionDays(String(payload.settings.video_retention_days))
    setVideoBudgetMb(String(payload.settings.video_storage_budget_mb))
    setMaxConcurrentAgentRuns(String(payload.settings.max_concurrent_agent_runs))
    setProactiveRebaseThreshold(String(payload.settings.proactive_rebase_commit_threshold))
    setMode(payload.settings.mode)
  }, [payload.settings.signups_open, payload.settings.video_retention_days, payload.settings.video_storage_budget_mb, payload.settings.max_concurrent_agent_runs, payload.settings.proactive_rebase_commit_threshold, payload.settings.mode])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    if (mode !== payload.settings.mode) {
      const confirmed = await confirm({ message: modeChangeMessage(t, payload.settings.mode, mode) })
      if (!confirmed) {
        setMode(payload.settings.mode)
        return
      }
    }
    update.mutate()
  }

  return (
    <form className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-6" onSubmit={submit}>
      <div className="flex items-start gap-3">
        <input
          id="admin-settings-signups-open"
          checked={signupsOpen}
          className="mt-1 rounded border-gray-400"
          onChange={(event) => setSignupsOpen(event.target.checked)}
          type="checkbox"
        />
        <span>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-signups-open">{t("settings.signups_open_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">
            {t("settings.signups_open_help")}
          </span>
        </span>
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-video-retention">{t("settings.video_retention_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.video_retention_help")}</span>
        <input
          id="admin-settings-video-retention"
          className="mt-1 w-32 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
          min={1}
          onChange={(event) => setVideoRetentionDays(event.target.value)}
          type="number"
          value={videoRetentionDays}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-video-budget">{t("settings.video_budget_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.video_budget_help")}</span>
        <input
          id="admin-settings-video-budget"
          className="mt-1 w-32 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
          min={0}
          onChange={(event) => setVideoBudgetMb(event.target.value)}
          type="number"
          value={videoBudgetMb}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-max-agent-runs">{t("settings.max_concurrent_agent_runs_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.max_concurrent_agent_runs_help")}</span>
        <input
          id="admin-settings-max-agent-runs"
          className="mt-1 w-32 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
          min={0}
          onChange={(event) => setMaxConcurrentAgentRuns(event.target.value)}
          type="number"
          value={maxConcurrentAgentRuns}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-proactive-rebase-threshold">{t("settings.proactive_rebase_commit_threshold_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.proactive_rebase_commit_threshold_help")}</span>
        <input
          id="admin-settings-proactive-rebase-threshold"
          className="mt-1 w-32 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
          min={1}
          onChange={(event) => setProactiveRebaseThreshold(event.target.value)}
          type="number"
          value={proactiveRebaseThreshold}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-mode">{t("settings.mode_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.mode_help")}</span>
        <select
          id="admin-settings-mode"
          className="mt-1 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
          onChange={(event) => setMode(event.target.value as "advanced" | "simple")}
          value={mode}
        >
          <option value="advanced">{t("settings.mode_advanced")}</option>
          <option value="simple">{t("settings.mode_simple")}</option>
        </select>
      </div>

      <button
        className="rounded bg-blue-600 dark:bg-blue-500 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
        disabled={update.isPending}
        type="submit"
      >
        {update.isPending ? t("settings.saving") : t("settings.save")}
      </button>
      {update.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, t("settings.error_update"))}</p> : null}
      {dialog}
    </form>
  )
}

function TelegramSection({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const { confirm, dialog } = useConfirm()
  const [tokenInput, setTokenInput] = useState("")
  const [handleInput, setHandleInput] = useState(payload.settings.telegram_bot_handle)

  const telegramSecret = payload.settings.clearable_secrets.find(s => s.key === "telegram_bot_token")
  const tokenSet = telegramSecret?.set ?? false
  const telegramConfigured = tokenSet && handleInput.trim().length > 0

  const saveToken = useMutation({
    mutationFn: () => updateAdminSettings({
      telegram_bot_handle: handleInput,
      ...(tokenInput.trim() ? { telegram_bot_token: tokenInput } : {})
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setTokenInput("")
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  const clearToken = useMutation({
    mutationFn: () => clearAdminSettingSecret("telegram_bot_token"),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  const startPolling = useMutation({
    mutationFn: startPlatformPolling,
    onSuccess: (result) => {
      onNotice(result.started.length > 0 ? t("settings.telegram_polling_started") : t("settings.telegram_polling_already_running"))
    }
  })

  useEffect(() => {
    setHandleInput(payload.settings.telegram_bot_handle)
  }, [payload.settings.telegram_bot_handle])

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-6 space-y-4">
      <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("settings.telegram_heading")}</h2>

      <div className="text-xs text-gray-500 dark:text-gray-400">
        {tokenSet ? t("settings.currently_set") : t("settings.not_set")}
      </div>

      <div className="flex flex-wrap gap-2">
        <input
          aria-label={t("settings.telegram_handle_label")}
          autoComplete="off"
          className="min-w-48 flex-1 rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm dark:bg-gray-800 dark:text-gray-100"
          onChange={(e) => setHandleInput(e.target.value)}
          placeholder={t("settings.telegram_handle_placeholder")}
          type="text"
          value={handleInput}
        />
        <input
          aria-label={t("settings.telegram_token_label")}
          autoComplete="off"
          className="flex-1 min-w-48 rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm dark:bg-gray-800 dark:text-gray-100"
          onChange={(e) => setTokenInput(e.target.value)}
          placeholder={t("settings.telegram_token_placeholder")}
          type="password"
          value={tokenInput}
        />
        <button
          className="rounded bg-terracotta-600 px-3.5 py-1.5 text-sm font-medium text-white hover:bg-terracotta-500 disabled:cursor-not-allowed disabled:opacity-50"
          disabled={saveToken.isPending || (!tokenInput.trim() && handleInput === payload.settings.telegram_bot_handle)}
          onClick={() => { onNotice(null); saveToken.mutate() }}
          type="button"
        >
          {saveToken.isPending ? t("settings.saving") : t("settings.telegram_save_token")}
        </button>
        {tokenSet && (
          <button
            className="rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:cursor-not-allowed disabled:opacity-50"
            disabled={clearToken.isPending}
            onClick={async () => {
              if (await confirm({ message: t("settings.telegram_token_clear_confirm"), destructive: true })) {
                onNotice(null)
                clearToken.mutate()
              }
            }}
            type="button"
          >
            {clearToken.isPending ? t("settings.clearing") : t("settings.clear")}
          </button>
        )}
      </div>

      <button
        className="rounded bg-gray-100 dark:bg-gray-700 px-3.5 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-600 disabled:cursor-not-allowed disabled:opacity-50"
        disabled={startPolling.isPending || !telegramConfigured}
        onClick={() => { onNotice(null); startPolling.mutate() }}
        type="button"
      >
        {startPolling.isPending ? t("settings.telegram_polling_starting") : t("settings.telegram_start_polling")}
      </button>

      {saveToken.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(saveToken.error, t("settings.error_update"))}</p> : null}
      {clearToken.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(clearToken.error, t("settings.error_clear"))}</p> : null}
      {startPolling.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{t("settings.telegram_polling_error")}</p> : null}
      {dialog}
    </section>
  )
}

function modeChangeMessage(t: ReturnType<typeof useT<"admin">>["t"], from: "advanced" | "simple", to: "advanced" | "simple") {
  if (from === to) return ""
  return to === "advanced" ? t("settings.mode_confirm_to_advanced") : t("settings.mode_confirm_to_simple")
}

function SettingsError({ error }: { error: Error }) {
  const { t } = useT("admin")
  return <PanelMessage tone="error">{errorMessage(error, t("settings.error_load"))}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}
