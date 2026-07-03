import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import {
  clearAdminSettingSecret,
  fetchAdminSettings,
  updateAdminSettings,
  type AdminSettingsPayload,
  type ClearableSecret
} from "../api/adminSettings"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"

const queryKey = ["admin", "settings"] as const

export function AdminSettings() {
  const [notice, setNotice] = useState<string | null>(null)
  const settings = useQuery({
    queryKey,
    queryFn: fetchAdminSettings
  })

  return (
    <main aria-label="Admin settings" className="mx-auto max-w-3xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">App settings</h1>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {settings.isPending ? <PanelMessage>Loading app settings...</PanelMessage> : null}
      {settings.isError ? <SettingsError error={settings.error} /> : null}
      {settings.isSuccess ? <SettingsView onNotice={setNotice} payload={settings.data} /> : null}
    </main>
  )
}

function SettingsView({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  return (
    <>
      {payload.settings.clearable_secrets.length > 0 && (
        <section className="divide-y divide-gray-200 dark:divide-gray-700 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          {payload.settings.clearable_secrets.map((secret) => (
            <SecretRow key={secret.key} onNotice={onNotice} secret={secret} />
          ))}
        </section>
      )}

      <SettingsForm onNotice={onNotice} payload={payload} />
    </>
  )
}

function SecretRow({ secret, onNotice }: { secret: ClearableSecret; onNotice: (message: string | null) => void }) {
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
          {secret.set ? "Currently set. Blank update fields will not clear it." : "Not set."}
        </div>
      </div>
      {secret.set ? (
        <button
          className="self-start rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:cursor-not-allowed disabled:text-red-300 sm:self-auto"
          disabled={clearSecret.isPending}
          onClick={() => {
            if (window.confirm(`Clear ${secret.label}? Telegram delivery will fail until you add a new value or set the ENV fallback.`)) {
              onNotice(null)
              clearSecret.mutate()
            }
          }}
          type="button"
        >
          {clearSecret.isPending ? "Clearing..." : "Clear"}
        </button>
      ) : null}
      {clearSecret.isError ? <div className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(clearSecret.error, "Unable to clear secret.")}</div> : null}
    </div>
  )
}

function SettingsForm({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [signupsOpen, setSignupsOpen] = useState(payload.settings.signups_open)
  const [telegramBotToken, setTelegramBotToken] = useState("")
  const [telegramWebhookSecret, setTelegramWebhookSecret] = useState("")
  const update = useMutation({
    mutationFn: () => updateAdminSettings({
      signups_open: signupsOpen,
      telegram_bot_token: telegramBotToken,
      telegram_webhook_secret: telegramWebhookSecret
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setTelegramBotToken("")
      setTelegramWebhookSecret("")
      onNotice(updated.message || "Settings updated.")
    }
  })

  useEffect(() => {
    setSignupsOpen(payload.settings.signups_open)
  }, [payload.settings.signups_open])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <form className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-6" onSubmit={submit}>
      <p className="text-sm text-gray-600 dark:text-gray-300">Leaving secret fields blank keeps the stored value unchanged. Use the Clear controls above to remove a secret.</p>

      <div className="flex items-start gap-3">
        <input
          id="admin-settings-signups-open"
          checked={signupsOpen}
          className="mt-1 rounded border-gray-400"
          onChange={(event) => setSignupsOpen(event.target.checked)}
          type="checkbox"
        />
        <span>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-signups-open">Open signups</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">
            When enabled, anyone can create an account at /users/new. When disabled, signup is invitation-only, but invitation links still work either way.
          </span>
        </span>
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-telegram-bot-token">Telegram bot token</label>
        <p className="mt-1 text-xs font-normal text-gray-500 dark:text-gray-400">Optional app-wide fallback for Telegram operator chat. ENV TELEGRAM_BOT_TOKEN still takes precedence.</p>
        <input
          id="admin-settings-telegram-bot-token"
          autoComplete="off"
          className="mt-2 block w-full rounded border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
          onChange={(event) => setTelegramBotToken(event.target.value)}
          type="password"
          value={telegramBotToken}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-telegram-webhook-secret">Telegram webhook secret</label>
        <p className="mt-1 text-xs font-normal text-gray-500 dark:text-gray-400">Optional app-wide fallback for validating Telegram webhook requests. ENV TELEGRAM_WEBHOOK_SECRET still takes precedence.</p>
        <input
          id="admin-settings-telegram-webhook-secret"
          autoComplete="off"
          className="mt-2 block w-full rounded border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
          onChange={(event) => setTelegramWebhookSecret(event.target.value)}
          type="password"
          value={telegramWebhookSecret}
        />
      </div>

      <button
        className="rounded bg-blue-600 dark:bg-blue-500 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
        disabled={update.isPending}
        type="submit"
      >
        {update.isPending ? "Saving..." : "Save"}
      </button>
      {update.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, "Unable to update settings.")}</p> : null}
    </form>
  )
}

function SettingsError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load app settings.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
