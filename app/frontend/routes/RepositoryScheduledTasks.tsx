import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { routePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { NoticeToast } from "../components/NoticeToast"
import {
  deleteRepositoryScheduledTask,
  fetchRepositoryScheduledTasks,
  updateRepositoryScheduledTask,
  type RepositoryScheduledTask,
  type RepositoryScheduledTasksPayload
} from "../api/scheduledTasks"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { toRomanDate } from "../lib/romanCalendar"
import { useT } from "../hooks/useT"
import { PanelMessage } from "../components/PanelMessage"
import { errorMessage } from "../lib/errorMessage"

export function RepositoryScheduledTasksRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const params = useParams()
  const repositoryId = params.repositoryId || ""
  const tasks = useQuery({
    queryKey: ["repositories", repositoryId, "scheduled_tasks"],
    queryFn: () => fetchRepositoryScheduledTasks(repositoryId),
    enabled: repositoryId.length > 0
  })

  return (
    <main aria-label={t("aria_repo_scheduled_tasks")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {tasks.isPending ? <PanelMessage>{t("scheduled_tasks.loading")}</PanelMessage> : null}
      {tasks.isError ? <RepositoryScheduledTasksError error={tasks.error} /> : null}
      {tasks.isSuccess ? <RepositoryScheduledTasksView payload={tasks.data} prefix={routePrefix(location.pathname)} /> : null}
    </main>
  )
}

function RepositoryScheduledTasksView({ payload, prefix }: { payload: RepositoryScheduledTasksPayload; prefix: string }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const queryKey = ["repositories", String(payload.repository.id), "scheduled_tasks"] as const
  const toggle = useMutation({
    mutationFn: ({ task, enabled }: { task: RepositoryScheduledTask; enabled: boolean }) => updateRepositoryScheduledTask(payload.repository.id, task.id, enabled),
    onSuccess: (updated) => {
      setNotice(updated.message || null)
      queryClient.setQueryData(queryKey, updated)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
    }
  })
  const destroy = useMutation({
    mutationFn: (task: RepositoryScheduledTask) => deleteRepositoryScheduledTask(payload.repository.id, task.id),
    onSuccess: (updated) => {
      setNotice(updated.message || null)
      queryClient.setQueryData(queryKey, updated)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
    }
  })

  return (
    <>
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">{payload.repository.slug}</h1>
        </div>
      </header>

      <RepositoryTabs active="scheduled_tasks" prefix={prefix} tabs={payload.tabs} />

      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("scheduled_tasks.heading")}</h2>
        <Link className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500" to={`${prefix}/repositories/${payload.repository.id}/scheduled_tasks/new`}>{t("scheduled_tasks.new_task")}</Link>
      </div>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {toggle.isError ? <PanelMessage tone="error">{errorMessage(toggle.error, t("scheduled_tasks.error_update"))}</PanelMessage> : null}
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, t("scheduled_tasks.error_delete"))}</PanelMessage> : null}

      {payload.tasks.length === 0 ? (
        <section className="rounded border border-dashed border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 p-8 text-center text-sm text-gray-500 dark:text-gray-400">
          {t("scheduled_tasks.no_tasks")}
        </section>
      ) : (
        <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-3">{t("scheduled_tasks.name")}</th>
                <th className="px-4 py-3">{t("scheduled_tasks.schedule")}</th>
                <th className="px-4 py-3">{t("scheduled_tasks.next_window")}</th>
                <th className="px-4 py-3">{t("scheduled_tasks.state")}</th>
                <th className="px-4 py-3 text-right">{t("scheduled_tasks.actions")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {payload.tasks.map((task) => (
                <tr key={task.id}>
                  <td className="px-4 py-3">
                    <Link className="font-medium text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${prefix}/scheduled_tasks/${task.id}`}>{task.name}</Link>
                    <div className="mt-1 max-w-xl truncate text-xs text-gray-500 dark:text-gray-400">{task.prompt}</div>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs text-gray-700 dark:text-gray-300">{task.schedule_label || t("scheduled_tasks.none")}</td>
                  <td className="px-4 py-3 text-gray-700 dark:text-gray-300">
                    {task.next_fire_at
                      ? <span title={toRomanDate(task.next_fire_at)}><RelativeTimestamp value={task.next_fire_at} /></span>
                      : t("scheduled_tasks.none")}
                  </td>
                  <td className="px-4 py-3"><StatePill state={task.state} /></td>
                  <td className="px-4 py-3">
                    <div className="flex justify-end gap-2">
                      <button
                        className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:cursor-not-allowed disabled:text-gray-300 dark:disabled:text-gray-600"
                        disabled={toggle.isPending}
                        onClick={() => toggle.mutate({ task, enabled: !task.active })}
                        type="button"
                      >
                        {task.active ? t("scheduled_tasks.disable") : t("scheduled_tasks.enable")}
                      </button>
                      <button
                        className="rounded border border-red-200 dark:border-red-800 px-3 py-1 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
                        disabled={destroy.isPending}
                        onClick={() => {
                          if (window.confirm(t("scheduled_tasks.confirm_delete"))) destroy.mutate(task)
                        }}
                        type="button"
                      >
                        {t("scheduled_tasks.delete")}
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  )
}

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    scheduled: "bg-green-100 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    paused: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400",
    auto_paused: "bg-amber-100 dark:bg-amber-950/40 text-amber-700 dark:text-amber-300",
    fired: "bg-blue-100 dark:bg-blue-950/40 text-blue-700 dark:text-blue-300"
  }
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300"}`}>{state}</span>
}

function RepositoryScheduledTasksError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, t("scheduled_tasks.error_load"))}</PanelMessage>
}


