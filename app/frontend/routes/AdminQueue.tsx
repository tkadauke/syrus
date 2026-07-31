import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { formatRelativeDate } from "../lib/relativeTime"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import { FilterBar } from "../components/FilterBar"
import { adminSmartFolderFilterLinkBuilder } from "../lib/adminSmartFolderLinks"
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
  type WorkersQueuePayload,
  type WorkerHealthPayload
} from "../api/adminQueue"


export function AdminQueueRoute() {
  const params = useParams()
  const tab = isQueueTab(params.tab) ? params.tab : "active"

  return <AdminQueue tab={tab} />
}

function AdminQueue({ tab }: { tab: QueueTab }) {
  const { t } = useT("admin")
  usePageTitle(t("page_title_queue"))
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const queueQueryKey = ["admin", "queue", tab, location.search]
  const queue = useQuery({
    queryKey: queueQueryKey,
    queryFn: () => fetchAdminQueue(tab, location.search),
    placeholderData: keepPreviousData
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
    <main aria-label={t("aria_queue")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex items-end justify-between gap-4 border-b border-gray-200 dark:border-gray-700 pb-4">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("queue.heading")}</h1>
        </div>
        <button
          className="inline-flex shrink-0 items-center justify-center rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:cursor-not-allowed disabled:text-gray-400 dark:disabled:text-gray-500"
          disabled={reaper.isPending}
          onClick={() => reaper.mutate()}
          type="button"
        >
          {reaper.isPending ? t("queue.reaper_running") : t("queue.run_reaper")}
        </button>
      </header>

      <nav aria-label={t("aria_queue_tabs")} className="flex flex-wrap gap-2">
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
            {t(`queue.tab_${candidate}`)}
          </Link>
        ))}
      </nav>

      {reaper.isSuccess ? (
        <p className="rounded border border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40 px-3 py-2 text-sm text-emerald-800 dark:text-emerald-200">{reaper.data.message}</p>
      ) : null}
      {reaper.isError ? (
        <p className="rounded border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 px-3 py-2 text-sm text-red-700 dark:text-red-300">{t("queue.reaper_error")}</p>
      ) : null}

      {queue.isPending ? <PanelMessage>{t("queue.loading")}</PanelMessage> : null}
      {queue.isError ? <QueueError error={queue.error} /> : null}
      {queue.isSuccess ? (
        <QueueContent basePath={basePath} onNavigate={(path) => navigate(withRoutePrefix(path, prefix))} onSmartFolderMutationSuccess={() => {
          void queryClient.invalidateQueries({ queryKey: ["admin", "queue"] })
        }} pathname={location.pathname} payload={queue.data} prefix={prefix} queryKey={queueQueryKey} search={location.search} tab={tab} />
      ) : null}
    </main>
  )
}

function QueueContent({ basePath, onNavigate, onSmartFolderMutationSuccess, pathname, payload, prefix, queryKey, search, tab }: { basePath: string; onNavigate: (path: string) => void; onSmartFolderMutationSuccess: () => void; pathname: string; payload: AdminQueuePayload; prefix: string; queryKey: unknown[]; search: string; tab: QueueTab }) {
  const { t } = useT("admin")
  const smartFolders = "smart_folders" in payload ? payload.smart_folders : []
  const activeFolderId = "active_smart_folder_id" in payload ? payload.active_smart_folder_id : null
  const activeUserFolderId = smartFolders.find((folder) => folder.id === activeFolderId && folder.kind === "user_defined")?.id
  const filterBar = isFilteredQueuePayload(payload) ? (
    <FilterBar
      filter={payload.filter}
      filterSchema={payload.controls.filter_schema}
      buildLink={adminSmartFolderFilterLinkBuilder(activeUserFolderId)}
      pathname={pathname}
      search={search}
    />
  ) : null

  return (
    <AdminFiltersLayout
      filterBar={filterBar}
      smartFolders={smartFolders.length > 0 ? (
        <AdminSmartFolderNav
          activeFolderId={activeFolderId}
          allLabel={t("queue.all_queue")}
          allPath={`${basePath}/${tab}`}
          appliedFilter={isFilteredQueuePayload(payload) ? payload.filter : null}
          ariaLabel="Admin queue smart folders"
          currentFilter={isFilteredQueuePayload(payload) ? payload.filter : undefined}
          folders={smartFolders}
          heading={t("queue.queues")}
          onNavigate={onNavigate}
          onMutationSuccess={onSmartFolderMutationSuccess}
          prefix={prefix}
          queryKey={queryKey}
          search={search}
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
  const { t } = useT("admin")

  switch (tab) {
    case "active":
      return <JobsTable emptyLabel={t("queue.no_active")} jobs={(payload as ActiveQueuePayload).jobs ?? []} showClaimed />
    case "pending":
      return <PendingTable payload={payload as PendingQueuePayload} />
    case "failed":
      return <FailuresTable payload={payload as FailedQueuePayload} />
    case "recurring":
      return <RecurringTable tasks={(payload as RecurringQueuePayload).tasks ?? []} />
    case "workers":
      return <WorkersPanel payload={payload as WorkersQueuePayload} />
  }
}

function PendingTable({ payload }: { payload: PendingQueuePayload }) {
  const { t } = useT("admin")
  const jobs = payload.jobs ?? []

  return (
    <>
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300">{t("queue.showing_of", { shown: jobs.length, total: payload.total ?? 0 })}</div>
      <JobsTable emptyLabel={t("queue.no_queued")} jobs={jobs} />
    </>
  )
}

function JobsTable({ jobs, showClaimed = false, emptyLabel }: { jobs: QueueJob[]; showClaimed?: boolean; emptyLabel: string }) {
  const { t } = useT("admin")

  if (jobs.length === 0) return <PanelMessage>{emptyLabel}</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("queue.col_class")}</th>
            <th className="px-4 py-2">{t("queue.col_queue")}</th>
            <th className="px-4 py-2">{t("queue.col_arguments")}</th>
            <th className="px-4 py-2">{t("queue.col_created")}</th>
            {showClaimed ? <th className="px-4 py-2">{t("queue.col_claimed")}</th> : null}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {jobs.map((job) => (
            <tr key={job.id}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{job.class_name}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{job.queue_name}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{formatArguments(job.arguments)}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={job.created_at} /></td>
              {showClaimed ? <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={job.claimed_at} /></td> : null}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function FailuresTable({ payload }: { payload: FailedQueuePayload }) {
  const { t } = useT("admin")
  const failures = payload.failures ?? []

  if (failures.length === 0) return <PanelMessage>{t("queue.no_failures", { since: payload.since ? formatRelativeDate(new Date(payload.since)) : "-" })}</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("queue.col_created")}</th>
            <th className="px-4 py-2">{t("queue.col_class")}</th>
            <th className="px-4 py-2">{t("queue.col_exception")}</th>
            <th className="px-4 py-2">{t("queue.col_message")}</th>
            <th className="px-4 py-2">{t("queue.col_arguments")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {failures.map((failure: QueueFailure) => (
            <tr key={failure.id}>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={failure.created_at} /></td>
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
  const { t } = useT("admin")

  if (tasks.length === 0) return <PanelMessage>{t("queue.no_recurring")}</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("queue.col_key")}</th>
            <th className="px-4 py-2">{t("queue.col_class")}</th>
            <th className="px-4 py-2">{t("queue.col_schedule")}</th>
            <th className="px-4 py-2">{t("queue.col_last_run")}</th>
            <th className="px-4 py-2">{t("queue.col_last_finished")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {tasks.map((task) => (
            <tr key={task.key}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{task.key}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{task.class_name || "-"}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{task.schedule}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={task.last_run_at} /></td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={task.last_finished_at} /></td>
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
      {payload.worker_health ? <WorkerHealthPanel health={payload.worker_health} /> : null}
      <WorkerTable workers={payload.workers ?? []} />
      <ProcessTable processes={payload.all_processes ?? []} />
    </div>
  )
}

function WorkerHealthPanel({ health }: { health: WorkerHealthPayload }) {
  const { t } = useT("admin")
  const hosts = health.hosts ?? []

  if (hosts.length === 0) return <PanelMessage>{t("queue.no_worker_health")}</PanelMessage>

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("queue.worker_health")}</h2>
        <span className="text-xs text-gray-500 dark:text-gray-400">{t("queue.worker_health_range", { since: formatRelativeDate(new Date(health.range.since)), minutes: health.minute_bucket?.window_minutes ?? 60 })}</span>
      </div>
      <div className="grid gap-3 lg:grid-cols-2">
        {hosts.map((host) => <WorkerHealthHostPanel host={host} key={host.hostname} />)}
      </div>
    </div>
  )
}

function WorkerHealthHostPanel({ host }: { host: WorkerHealthPayload["hosts"][number] }) {
  const { t } = useT("admin")
  const current = host.current
  const sample = current?.sample || host.recent_samples[0]
  const level = current?.health.level || (sample ? "ok" : "unknown")
  const oneHour = host.windows["1h"]
  const minuteBuckets = host.minute_buckets ?? []

  return (
    <details className={`rounded border ${workerHealthBorder(level)} bg-white dark:bg-gray-900`} open={level === "critical" || level === "warning"}>
      <summary className="flex cursor-pointer list-none flex-wrap items-center justify-between gap-3 px-4 py-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-mono text-sm font-semibold text-gray-900 dark:text-gray-100">{host.hostname}</span>
            <span className={`rounded px-2 py-0.5 text-xs font-medium ${workerHealthBadge(level)}`}>{workerHealthLabel(level, t)}</span>
          </div>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{current?.health.reasons.length ? current.health.reasons.join("; ") : t("queue.worker_health_ok")}</p>
        </div>
        <div className="grid grid-cols-4 gap-3 text-right text-xs">
          <HealthStat label={t("queue.metric_cpu")} value={formatPercent(sample?.cpu_used_percent)} />
          <HealthStat label={t("queue.metric_memory")} value={formatPercent(sample?.memory_used_percent)} />
          <HealthStat label={t("queue.metric_disk")} value={formatPercent(sample?.data_root_used_percent)} />
          <HealthStat label={t("queue.metric_io")} value={formatPercent(sample?.io_pressure_some)} />
        </div>
      </summary>
      <div className="border-t border-gray-100 dark:border-gray-800 px-4 py-3">
        <div className="grid gap-3 text-xs sm:grid-cols-3">
          <HealthStat label={t("queue.col_version")} value={current?.version || sample?.version || "-"} />
          <HealthStat label={t("queue.last_sample")} value={sample ? formatRelativeDate(new Date(sample.observed_at)) : "-"} />
          <HealthStat label={t("queue.one_hour_max")} value={oneHour ? compactTrend(oneHour) : "-"} />
        </div>
        {minuteBuckets.length > 0 ? (
          <div className="mt-3 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-xs">
              <thead className="bg-gray-50 dark:bg-gray-800 text-left font-medium uppercase text-gray-500 dark:text-gray-400">
                <tr>
                  <th className="px-3 py-2">{t("queue.col_minute")}</th>
                  <th className="px-3 py-2">{t("queue.col_samples")}</th>
                  <th className="px-3 py-2">{t("queue.metric_cpu")}</th>
                  <th className="px-3 py-2">{t("queue.metric_memory")}</th>
                  <th className="px-3 py-2">{t("queue.metric_disk")}</th>
                  <th className="px-3 py-2">{t("queue.metric_load")}</th>
                  <th className="px-3 py-2">{t("queue.metric_cpu_pressure")}</th>
                  <th className="px-3 py-2">{t("queue.metric_io")}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                {minuteBuckets.map((bucket) => (
                  <tr key={bucket.minute}>
                    <td className="px-3 py-2 text-gray-600 dark:text-gray-300">{formatRelativeDate(new Date(bucket.minute))}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{bucket.sample_count}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{formatSummary(bucket.cpu_used_percent, "percent")}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{formatSummary(bucket.memory_used_percent, "percent")}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{formatSummary(bucket.data_root_used_percent, "percent")}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{formatSummary(bucket.load_1m, "number")}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{formatSummary(bucket.cpu_pressure_some, "percent")}</td>
                    <td className="px-3 py-2 text-gray-700 dark:text-gray-200">{formatSummary(bucket.io_pressure_some, "percent")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </div>
    </details>
  )
}

function HealthStat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[11px] font-medium uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-0.5 font-mono text-gray-900 dark:text-gray-100">{value}</div>
    </div>
  )
}

function WorkerTable({ workers }: { workers: QueueWorker[] }) {
  const { t } = useT("admin")

  if (workers.length === 0) return <PanelMessage>{t("queue.no_workers")}</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("queue.col_host")}</th>
            <th className="px-4 py-2">{t("queue.col_pid")}</th>
            <th className="px-4 py-2">{t("queue.col_queues")}</th>
            <th className="px-4 py-2">{t("queue.col_threads")}</th>
            <th className="px-4 py-2">{t("queue.col_heartbeat")}</th>
            <th className="px-4 py-2">{t("queue.col_state")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {workers.map((worker) => (
            <tr key={`${worker.hostname}-${worker.pid}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{worker.hostname || "-"}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{worker.pid}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{formatQueues(worker.queues)}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{worker.threads ?? "-"}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={worker.last_heartbeat_at} /></td>
              <td className={`px-4 py-2 ${worker.stale ? "text-red-700 dark:text-red-300" : "text-emerald-700 dark:text-emerald-300"}`}>{worker.stale ? t("queue.worker_stale") : t("queue.worker_healthy")}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ProcessTable({ processes }: { processes: QueueProcess[] }) {
  const { t } = useT("admin")

  if (processes.length === 0) return <PanelMessage>{t("queue.no_processes")}</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("queue.col_kind")}</th>
            <th className="px-4 py-2">{t("queue.col_host")}</th>
            <th className="px-4 py-2">{t("queue.col_pid")}</th>
            <th className="px-4 py-2">{t("queue.col_heartbeat")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {processes.map((process) => (
            <tr key={`${process.kind}-${process.hostname}-${process.pid}`}>
              <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{process.kind}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{process.hostname || "-"}</td>
              <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{process.pid}</td>
              <td className="px-4 py-2 text-gray-600 dark:text-gray-300"><RelativeTimestamp value={process.last_heartbeat_at} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function QueueError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const queueUnavailable = error instanceof ApiError && error.code === "queue_unreachable"
  const message = queueUnavailable ? t("queue.queue_unreachable") : t("queue.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function workerHealthBorder(level: string) {
  if (level === "critical") return "border-red-300 dark:border-red-800"
  if (level === "warning" || level === "unknown") return "border-amber-300 dark:border-amber-800"
  return "border-emerald-200 dark:border-emerald-800"
}

function workerHealthBadge(level: string) {
  if (level === "critical") return "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-200"
  if (level === "warning" || level === "unknown") return "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-200"
  return "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-200"
}

function workerHealthLabel(level: string, t: (key: string) => string) {
  if (level === "critical") return t("queue.worker_critical")
  if (level === "warning") return t("queue.worker_warning")
  if (level === "unknown") return t("queue.worker_unknown")
  return t("queue.worker_healthy")
}

function compactTrend(summary: WorkerHealthPayload["hosts"][number]["windows"][string]) {
  if (!summary || summary.sample_count === 0) return "-"
  const cpu = summary.cpu_used_percent?.max
  const mem = summary.memory_used_percent?.max
  const disk = summary.data_root_used_percent?.max
  const parts = [
    cpu == null ? null : `CPU ${formatPercent(cpu)}`,
    mem == null ? null : `Mem ${formatPercent(mem)}`,
    disk == null ? null : `Disk ${formatPercent(disk)}`
  ].filter(Boolean)

  return parts.length > 0 ? parts.join(" / ") : `${summary.sample_count} samples`
}

function formatPercent(value?: number | null) {
  if (value == null) return "-"
  return `${Math.round(value * 10) / 10}%`
}

function formatNumber(value?: number | null) {
  if (value == null) return "-"
  return `${Math.round(value * 100) / 100}`
}

function formatSummary(summary?: { avg: number; max: number } | null, kind: "percent" | "number" = "number") {
  if (!summary) return "-"
  const format = kind === "percent" ? formatPercent : formatNumber
  return `${format(summary.max)} / ${format(summary.avg)}`
}

function formatQueues(queues: QueueWorker["queues"]) {
  if (Array.isArray(queues)) return queues.length > 0 ? queues.join(", ") : "-"
  if (typeof queues === "string") return queues.trim() || "-"
  return "-"
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function formatArguments(value: unknown[] | null) {
  if (!value || value.length === 0) return "[]"

  return JSON.stringify(value)
}
