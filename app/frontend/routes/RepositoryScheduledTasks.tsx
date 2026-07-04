import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
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

export function RepositoryScheduledTasksRoute() {
  const location = useLocation()
  const params = useParams()
  const repositoryId = params.repositoryId || ""
  const tasks = useQuery({
    queryKey: ["repositories", repositoryId, "scheduled_tasks"],
    queryFn: () => fetchRepositoryScheduledTasks(repositoryId),
    enabled: repositoryId.length > 0
  })

  return (
    <main aria-label="Repository scheduled tasks" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {tasks.isPending ? <PanelMessage>Loading scheduled tasks...</PanelMessage> : null}
      {tasks.isError ? <RepositoryScheduledTasksError error={tasks.error} /> : null}
      {tasks.isSuccess ? <RepositoryScheduledTasksView payload={tasks.data} prefix={routePrefix(location.pathname)} /> : null}
    </main>
  )
}

function RepositoryScheduledTasksView({ payload, prefix }: { payload: RepositoryScheduledTasksPayload; prefix: string }) {
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
        <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">Scheduled tasks</h2>
        <Link className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500" to={`${prefix}/repositories/${payload.repository.id}/scheduled_tasks/new`}>New scheduled task</Link>
      </div>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {toggle.isError ? <PanelMessage tone="error">{errorMessage(toggle.error, "Unable to update scheduled task.")}</PanelMessage> : null}
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete scheduled task.")}</PanelMessage> : null}

      {payload.tasks.length === 0 ? (
        <section className="rounded border border-dashed border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 p-8 text-center text-sm text-gray-500 dark:text-gray-400">
          No scheduled tasks for this repository.
        </section>
      ) : (
        <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-3">Name</th>
                <th className="px-4 py-3">Schedule</th>
                <th className="px-4 py-3">Next window</th>
                <th className="px-4 py-3">State</th>
                <th className="px-4 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {payload.tasks.map((task) => (
                <tr key={task.id}>
                  <td className="px-4 py-3">
                    <Link className="font-medium text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${prefix}/scheduled_tasks/${task.id}`}>{task.name}</Link>
                    <div className="mt-1 max-w-xl truncate text-xs text-gray-500 dark:text-gray-400">{task.prompt}</div>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs text-gray-700 dark:text-gray-300">{task.schedule_label || "none"}</td>
                  <td className="px-4 py-3 text-gray-700 dark:text-gray-300">
                    {task.next_fire_at
                      ? <span title={toRomanDate(task.next_fire_at)}>{formatDate(task.next_fire_at)}</span>
                      : "none"}
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
                        {task.active ? "Disable" : "Enable"}
                      </button>
                      <button
                        className="rounded border border-red-200 dark:border-red-800 px-3 py-1 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
                        disabled={destroy.isPending}
                        onClick={() => {
                          if (window.confirm("Delete this scheduled task?")) destroy.mutate(task)
                        }}
                        type="button"
                      >
                        Delete
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
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load repository scheduled tasks.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    success: "border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function formatDate(value: string | null) {
  return value ? new Date(value).toLocaleString() : null
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
