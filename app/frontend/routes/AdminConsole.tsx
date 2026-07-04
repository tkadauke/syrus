import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useState } from "react"
import {
  clearGithubCache,
  fetchAdminConsole,
  reapStaleRuns,
  runConsoleCommand,
  type AdminConsolePayload,
  type ConsoleAction,
  type ConsoleCommand,
  type ConsoleSettings
} from "../api/adminConsole"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { useT } from "../hooks/useT"

export function AdminConsole() {
  const { t } = useT("admin")
  const consoleQuery = useQuery({
    queryKey: ["admin", "console"],
    queryFn: fetchAdminConsole
  })

  return (
    <main aria-label="Admin console" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("console.heading")}</h1>
      </header>

      {consoleQuery.isPending ? <PanelMessage>{t("console.loading")}</PanelMessage> : null}
      {consoleQuery.isError ? <ConsoleError error={consoleQuery.error} /> : null}
      {consoleQuery.isSuccess ? <ConsoleView payload={consoleQuery.data} /> : null}
    </main>
  )
}

function ConsoleView({ payload }: { payload: AdminConsolePayload }) {
  return (
    <>
      <section className="grid gap-4 md:grid-cols-2">
        <TogglePanel
          command={payload.settings.polling_paused ? "unpause_polling" : "pause_polling"}
          description="Stops recurring fan-out jobs from enqueueing per-Job pollers while leaving manual poll buttons available."
          label={payload.settings.polling_paused ? "Resume polling" : "Pause polling"}
          title="Polling"
          value={payload.settings.polling_paused ? "paused" : "running"}
          warning={payload.settings.polling_paused}
        />
        <TogglePanel
          command={payload.settings.runs_paused ? "unpause_runs" : "pause_runs"}
          description="Defers new RunJob work at perform time. Already-running Runs continue."
          label={payload.settings.runs_paused ? "Resume runs" : "Pause runs"}
          title="RunJobs"
          value={payload.settings.runs_paused ? "paused" : "running"}
          warning={payload.settings.runs_paused}
        />
        <TogglePanel
          command={payload.settings.merge_train_enabled ? "disable_merge_train" : "enable_merge_train"}
          description="When on, an Epic's children land together as one atomic merge (graded once) instead of individually. While enabled, Epic children land only via the train, never via the per-Job path."
          label={payload.settings.merge_train_enabled ? "Disable merge-train" : "Enable merge-train"}
          title="Epic merge-train"
          value={payload.settings.merge_train_enabled ? "enabled" : "disabled"}
          warning={!payload.settings.merge_train_enabled}
        />
      </section>

      <section className="grid gap-4 md:grid-cols-2">
        <ReaperPanel />
        <GithubCachePanel payload={payload} />
      </section>

      <ActionsTable actions={payload.recent_admin_actions} />
    </>
  )
}

function TogglePanel({
  title,
  description,
  value,
  label,
  command,
  warning
}: {
  title: string
  description: string
  value: string
  label: string
  command: ConsoleCommand
  warning: boolean
}) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: () => runConsoleCommand(command),
    onSuccess: (payload) => {
      queryClient.setQueryData(["admin", "console"], payload)
      void queryClient.invalidateQueries({ queryKey: ["admin", "overview"] })
    }
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="font-medium text-gray-900 dark:text-gray-100">{title}</h2>
          <p className="mt-1 max-w-prose text-xs text-gray-600 dark:text-gray-300">{description}</p>
          <p className="mt-3 text-xs">
            {t("console.state")} <span className={`rounded px-2 py-0.5 font-mono uppercase ${warning ? "bg-amber-100 dark:bg-amber-950/60 text-amber-700 dark:text-amber-300" : "bg-emerald-100 dark:bg-emerald-950/60 text-emerald-700 dark:text-emerald-300"}`}>{value}</span>
          </p>
        </div>
        <button
          className={`rounded px-3 py-1.5 text-sm font-medium text-white disabled:cursor-not-allowed ${warning ? "bg-emerald-600 dark:bg-emerald-500 hover:bg-emerald-500 dark:hover:bg-emerald-400 disabled:bg-emerald-300 dark:disabled:bg-emerald-900" : "bg-amber-600 dark:bg-amber-500 hover:bg-amber-500 dark:hover:bg-amber-400 disabled:bg-amber-300 dark:disabled:bg-amber-900"}`}
          disabled={mutation.isPending}
          onClick={() => mutation.mutate()}
          type="button"
        >
          {mutation.isPending ? t("console.saving") : label}
        </button>
      </div>
    </section>
  )
}

function ReaperPanel() {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: reapStaleRuns,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["admin", "queue"] })
      void queryClient.invalidateQueries({ queryKey: ["admin", "overview"] })
      void queryClient.invalidateQueries({ queryKey: ["admin", "stuck"] })
    }
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="font-medium text-gray-900 dark:text-gray-100">{t("console.reap_heading")}</h2>
          <p className="mt-1 max-w-prose text-xs text-gray-600 dark:text-gray-300">{t("console.reap_description")}</p>
        </div>
        <button
          className="shrink-0 rounded bg-red-600 dark:bg-red-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-500 dark:hover:bg-red-400 disabled:cursor-not-allowed disabled:bg-red-300 dark:disabled:bg-red-900"
          disabled={mutation.isPending}
          onClick={() => mutation.mutate()}
          type="button"
        >
          {mutation.isPending ? t("console.running") : t("console.reap_now")}
        </button>
      </div>
      {mutation.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{t("console.reap_error")}</p> : null}
    </section>
  )
}

function GithubCachePanel({ payload }: { payload: AdminConsolePayload }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [userId, setUserId] = useState("")
  const mutation = useMutation({
    mutationFn: () => clearGithubCache(userId),
    onSuccess: (updated) => {
      queryClient.setQueryData(["admin", "console"], updated)
    }
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="font-medium text-gray-900 dark:text-gray-100">{t("console.github_cache_heading")}</h2>
      <p className="mt-1 max-w-prose text-xs text-gray-600 dark:text-gray-300">{t("console.github_cache_description")}</p>
      <div className="mt-4 flex flex-col gap-2 sm:flex-row sm:items-center">
        <select
          className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-700 dark:text-gray-200"
          onChange={(event) => setUserId(event.target.value)}
          value={userId}
        >
          <option value="">{t("console.all_users")}</option>
          {payload.users.map((user) => (
            <option key={user.id} value={user.id}>{user.email_address}</option>
          ))}
        </select>
        <button
          className="rounded bg-blue-600 dark:bg-blue-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
          disabled={mutation.isPending}
          onClick={() => mutation.mutate()}
          type="button"
        >
          {mutation.isPending ? t("console.clearing") : t("console.clear_cache")}
        </button>
      </div>
      <NoticeToast message={mutation.data?.message || null} onDismiss={() => mutation.reset()} />
      {mutation.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{t("console.clear_error")}</p> : null}
    </section>
  )
}

function ActionsTable({ actions }: { actions: ConsoleAction[] }) {
  const { t } = useT("admin")

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <div className="border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 px-4 py-2 text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("console.recent_actions")}</div>
      {actions.length === 0 ? (
        <PanelMessage>{t("console.no_actions")}</PanelMessage>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">{t("console.col_when")}</th>
                <th className="px-4 py-2">{t("console.col_operator")}</th>
                <th className="px-4 py-2">{t("console.col_action")}</th>
                <th className="px-4 py-2">{t("console.col_params")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {actions.map((action) => (
                <tr key={action.id}>
                  <td className="whitespace-nowrap px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{formatDate(action.performed_at)}</td>
                  <td className="px-4 py-2 text-xs text-gray-700 dark:text-gray-200">{action.user_email}</td>
                  <td className="px-4 py-2 font-mono text-xs">{action.action}</td>
                  <td className="px-4 py-2 font-mono text-xs text-gray-500 dark:text-gray-400">{JSON.stringify(action.params).slice(0, 200)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function ConsoleError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("console.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function formatDate(value: string) {
  return new Date(value).toLocaleString()
}
