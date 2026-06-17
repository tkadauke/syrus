import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import { FilterBar } from "../components/FilterBar"
import {
  fetchAdminQueue,
  isQueueTab,
  queueTabs,
  reapStaleRuns,
  type ActiveQueuePayload,
  type AdminQueuePayload,
  type FailedQueuePayload,
  type PendingQueuePayload,
  type QueueFailure,
  type QueueJob,
  type QueueProcess,
  type QueueRecurringTask,
  type QueueTab,
  type QueueWorker,
  type RecurringQueuePayload,
  type WorkersQueuePayload
} from "../api/adminQueue"

const tabLabels: Record<QueueTab, string> = {
  active: "Active",
  pending: "Pending",
  failed: "Failed",
  recurring: "Recurring",
  workers: "Workers"
}

export function AdminQueueRoute() {
  const params = useParams()
  const tab = isQueueTab(params.tab) ? params.tab : "active"

  return <AdminQueue tab={tab} />
}

function AdminQueue({ tab }: { tab: QueueTab }) {
  const location = useLocation()
  const queryClient = useQueryClient()
  const queue = useQuery({
    queryKey: ["admin", "queue", tab, location.search],
    queryFn: () => fetchAdminQueue(tab, location.search)
  })
  const reaper = useMutation({
    mutationFn: reapStaleRuns,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["admin", "queue"] })
      void queryClient.invalidateQueries({ queryKey: ["admin", "overview"] })
    }
  })
  const basePath = location.pathname.startsWith("/app-shell") ? "/app-shell/admin/queue" : "/admin/queue"
  const prefix = routePrefix(location.pathname)

  return (
    <main aria-label="Admin queue" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex items-end justify-between gap-4 border-b border-gray-200 dark:border-gray-700 pb-4">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">Queue</h1>
        </div>
        <button
          className="inline-flex shrink-0 items-center justify-center rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:cursor-not-allowed disabled:text-gray-400 dark:disabled:text-gray-500"
          disabled={reaper.isPending}
          onClick={() => reaper.mutate()}
          type="button"
        >
          {reaper.isPending ? "Running..." : "Run stale-run reaper"}
        </button>
      </header>

      <nav aria-label="Queue tabs" className="flex flex-wrap gap-2">
        {queueTabs.map((candidate) => (
          <Link
            className={`rounded border px-3 py-1.5 text-sm ${
              candidate === tab
                ? "border-gray-900 dark:border-gray-100 bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900"
                : "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
            }`}
            key={candidate}
            to={`${basePath}/${candidate}`}
          >
            {tabLabels[candidate]}
          </Link>
        ))}
      </nav>

      {reaper.isSuccess ? (
        <p className="rounded border border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40 px-3 py-2 text-sm text-emerald-800 dark:text-emerald-200">{reaper.data.message}</p>
      ) : null}
      {reaper.isError ? (
        <p className="rounded border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 px-3 py-2 text-sm text-red-700 dark:text-red-300">Unable to run stale-run reaper.</p>
      ) : null}

      {queue.isPending ? <PanelMessage>Loading queue...</PanelMessage> : null}
      {queue.isError ? <QueueError error={queue.error} /> : null}
      {queue.isSuccess ? (
        <QueueContent basePath={basePath} pathname={location.pathname} payload={queue.data} prefix={prefix} search={location.search} tab={tab} />
      ) : null}
    </main>
  )
}

function QueueContent({ basePath, pathname, payload, prefix, search, tab }: { basePath: string; pathname: string; payload: AdminQueuePayload; prefix: string; search: string; tab: QueueTab }) {
  const smartFolders = "smart_folders" in payload ? payload.smart_folders : []
  const filterBar = isFilteredQueuePayload(payload) ? (
    <FilterBar
      filter={payload.filter}
      filterSchema={payload.controls.filter_schema}
      pathname={pathname}
      search={search}
    />
  ) : null

  return (
    <AdminFiltersLayout
      filterBar={filterBar}
      smartFolders={smartFolders.length > 0 ? (
        <AdminSmartFolderNav
          activeSmartFolderId={"active_smart_folder_id" in payload ? payload.active_smart_folder_id : null}
          allLabel="All queue"
          allPath={`${basePath}/${tab}`}
          ariaLabel="Admin queue smart folders"
          folders={smartFolders}
          heading="Queues"
          prefix={prefix}
          subjectType="admin_queue"
        />
      ) : null}
    >
      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <QueueTabPanel tab={tab} payload={payload} />
      </section>
    </AdminFiltersLayout>
  )
}

function isFilteredQueuePayload(payload: AdminQueuePayload): payload is ActiveQueuePayload | PendingQueuePayload | FailedQueuePayload {
  return "filter" in payload && "controls" in payload
}

function QueueTabPanel({ tab, payload }: { tab: QueueTab; payload: unknown }) {
  switch (tab) {
    case "active":
      return <JobsTable emptyLabel="No active claimed executions." jobs={(payload as ActiveQueuePayload).jobs} showClaimed />
    case "pending":
      return <PendingTable payload={payload as PendingQueuePayload} />
    case "failed":
      return <FailuresTable payload={payload as FailedQueuePayload} />
    case "recurring":
      return <RecurringTable tasks={(payload as RecurringQueuePayload).tasks} />
    case "workers":
      return <WorkersPanel payload={payload as WorkersQueuePayload} />
  }
}

function PendingTable({ payload }: { payload: PendingQueuePayload }) {
  return (
    <>
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300">Showing {payload.jobs.length} of {payload.total}</div>
      <JobsTable emptyLabel="No queued jobs." jobs={payload.jobs} />
    </>
  )
}

function JobsTable({ jobs, showClaimed = false, emptyLabel }: { jobs: QueueJob[]; showClaimed?: boolean; emptyLabel: string }) {
  if (jobs.length === 0) return <PanelMessage>{emptyLabel}</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Class</th>
            <th className="px-4 py-2">Queue</th>
            <th className="px-4 py-2">Arguments</th>
            <th className="px-4 py-2">Created</th>
            {showClaimed ? <th className="px-4 py-2">Claimed</th> : null}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {jobs.map((job) => (
            <tr key={job.id}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{job.class_name}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{job.queue_name}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{formatArguments(job.arguments)}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(job.created_at)}</td>
              {showClaimed ? <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(job.claimed_at)}</td> : null}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function FailuresTable({ payload }: { payload: FailedQueuePayload }) {
  if (payload.failures.length === 0) return <PanelMessage>No failures since {formatDate(payload.since)}.</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Created</th>
            <th className="px-4 py-2">Class</th>
            <th className="px-4 py-2">Exception</th>
            <th className="px-4 py-2">Message</th>
            <th className="px-4 py-2">Arguments</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {payload.failures.map((failure: QueueFailure) => (
            <tr key={failure.id}>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(failure.created_at)}</td>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{failure.class_name || "-"}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{failure.exception_class || "-"}</td>
              <td className="max-w-md px-4 py-2 text-gray-700 dark:text-gray-200">{failure.message || "-"}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{formatArguments(failure.arguments)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function RecurringTable({ tasks }: { tasks: QueueRecurringTask[] }) {
  if (tasks.length === 0) return <PanelMessage>No recurring tasks registered.</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Key</th>
            <th className="px-4 py-2">Class</th>
            <th className="px-4 py-2">Schedule</th>
            <th className="px-4 py-2">Last run</th>
            <th className="px-4 py-2">Last finished</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {tasks.map((task) => (
            <tr key={task.key}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{task.key}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{task.class_name || "-"}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{task.schedule}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(task.last_run_at)}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(task.last_finished_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function WorkersPanel({ payload }: { payload: WorkersQueuePayload }) {
  return (
    <div className="space-y-6 p-4">
      <WorkerTable workers={payload.workers} />
      <ProcessTable processes={payload.all_processes} />
    </div>
  )
}

function WorkerTable({ workers }: { workers: QueueWorker[] }) {
  if (workers.length === 0) return <PanelMessage>No workers registered.</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Host</th>
            <th className="px-4 py-2">PID</th>
            <th className="px-4 py-2">Queues</th>
            <th className="px-4 py-2">Threads</th>
            <th className="px-4 py-2">Heartbeat</th>
            <th className="px-4 py-2">State</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {workers.map((worker) => (
            <tr key={`${worker.hostname}-${worker.pid}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{worker.hostname || "-"}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{worker.pid}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{formatQueues(worker.queues)}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{worker.threads ?? "-"}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(worker.last_heartbeat_at)}</td>
              <td className={`px-4 py-2 ${worker.stale ? "text-red-700 dark:text-red-300" : "text-emerald-700 dark:text-emerald-300"}`}>{worker.stale ? "stale" : "healthy"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ProcessTable({ processes }: { processes: QueueProcess[] }) {
  if (processes.length === 0) return <PanelMessage>No SolidQueue processes registered.</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Kind</th>
            <th className="px-4 py-2">Host</th>
            <th className="px-4 py-2">PID</th>
            <th className="px-4 py-2">Heartbeat</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {processes.map((process) => (
            <tr key={`${process.kind}-${process.hostname}-${process.pid}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{process.kind}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{process.hostname || "-"}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{process.pid}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{formatDate(process.last_heartbeat_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function QueueError({ error }: { error: Error }) {
  const queueUnavailable = error instanceof ApiError && error.code === "queue_unreachable"
  const message = queueUnavailable ? "SolidQueue tables are unreachable from this connection." : "Unable to load queue data."

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function formatQueues(queues: QueueWorker["queues"]) {
  if (Array.isArray(queues)) return queues.length > 0 ? queues.join(", ") : "-"
  if (typeof queues === "string") return queues.trim() || "-"
  return "-"
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function formatDate(value: string | null | undefined) {
  if (!value) return "-"

  return new Date(value).toLocaleString()
}

function formatArguments(value: unknown[] | null) {
  if (!value || value.length === 0) return "[]"

  return JSON.stringify(value)
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}
