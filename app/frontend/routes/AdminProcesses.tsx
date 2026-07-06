import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { useT } from "../hooks/useT"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import { FilterBar } from "../components/FilterBar"
import { adminSmartFolderFilterLinkBuilder } from "../lib/adminSmartFolderLinks"
import {
  fetchAdminProcess,
  fetchAdminProcesses,
  killAdminProcess,
  type SpawnedProcessPayload
} from "../api/adminProcesses"
import { workflowSlug } from "../lib/slugs"

export function AdminProcessesIndex() {
  const { t } = useT("admin")
  const location = useLocation()
  const queryClient = useQueryClient()
  const prefix = routePrefix(location.pathname)
  const basePath = location.pathname.startsWith("/app-shell") ? "/app-shell/admin/processes" : "/admin/processes"
  const processes = useQuery({
    queryKey: ["admin", "processes", location.search],
    queryFn: () => fetchAdminProcesses(location.search)
  })
  const activeUserFolderId = processes.data?.smart_folders.find((folder) => folder.id === processes.data.active_smart_folder_id && folder.kind === "user_defined")?.id

  return (
    <main aria-label="Admin processes" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("processes.heading")}</h1>
      </header>

      {processes.isPending ? <PanelMessage>{t("processes.loading")}</PanelMessage> : null}
      {processes.isError ? <ProcessError error={processes.error} /> : null}
      {processes.isSuccess ? (
        <AdminFiltersLayout
          filterBar={
            <FilterBar
              filter={processes.data.filter}
              filterSchema={processes.data.controls.filter_schema}
              buildLink={adminSmartFolderFilterLinkBuilder(activeUserFolderId)}
              legacyFilterKeys={adminProcessLegacyFilterKeys}
              pathname={location.pathname}
              search={location.search}
            />
          }
          smartFolders={
            <AdminSmartFolderNav
              activeFolderId={processes.data.active_smart_folder_id}
              allLabel={t("processes.all_label")}
              allPath={basePath}
              ariaLabel="Admin process smart folders"
              currentFilter={processes.data.filter}
              folders={processes.data.smart_folders}
              heading={t("processes.heading")}
              onMutationSuccess={() => {
                void queryClient.invalidateQueries({ queryKey: ["admin", "processes"] })
              }}
              prefix={prefix}
              search={location.search}
              subjectType="spawned_process"
            />
          }
        >
          <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
            <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
              {t("processes.running_summary", { running: processes.data.running_total, shown: processes.data.processes.length })}
            </div>
            <ProcessesTable basePath={basePath} processes={processes.data.processes} />
          </section>
        </AdminFiltersLayout>
      ) : null}
    </main>
  )
}

const adminProcessLegacyFilterKeys = ["state", "kind", "hostname", "run_id", "workflow_id", "since"]

export function AdminProcessDetail() {
  const { t } = useT("admin")
  const params = useParams()
  const id = params.id || ""
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const basePath = location.pathname.startsWith("/app-shell") ? "/app-shell/admin/processes" : "/admin/processes"
  const process = useQuery({
    queryKey: ["admin", "processes", id],
    queryFn: () => fetchAdminProcess(id),
    enabled: id.length > 0
  })

  return (
    <main aria-label="Admin process detail" className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <Link className="text-sm text-blue-600 dark:text-blue-300 underline hover:no-underline" to={basePath}>{t("processes.heading")}</Link>
        <h1 className="mt-2 text-2xl font-semibold text-gray-900 dark:text-gray-100">Process {id ? `#${id}` : ""}</h1>
      </header>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {process.isPending ? <PanelMessage>{t("processes.loading")}</PanelMessage> : null}
        {process.isError ? <ProcessError error={process.error} /> : null}
        {process.isSuccess ? <ProcessDetail prefix={prefix} process={process.data} /> : null}
      </section>
    </main>
  )
}

function ProcessesTable({ processes, basePath }: { processes: SpawnedProcessPayload[]; basePath: string }) {
  const { t } = useT("admin")
  if (processes.length === 0) return <PanelMessage>{t("processes.no_match")}</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-3 py-2">{t("processes.col_kind")}</th>
            <th className="px-3 py-2">{t("processes.col_command")}</th>
            <th className="px-3 py-2">{t("processes.col_host_pid")}</th>
            <th className="px-3 py-2">{t("processes.col_started")}</th>
            <th className="px-3 py-2">{t("processes.col_last_chunk")}</th>
            <th className="px-3 py-2">{t("processes.col_duration")}</th>
            <th className="px-3 py-2">{t("processes.col_outcome")}</th>
            <th className="px-3 py-2 text-right">{t("processes.col_actions")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {processes.map((process) => (
            <tr className={process.stale ? "bg-amber-50 dark:bg-amber-950/40" : ""} key={process.id}>
              <td className="px-3 py-2 align-top">
                <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-medium text-gray-700 dark:text-gray-200">{process.kind}</span>
              </td>
              <td className="max-w-md truncate px-3 py-2 align-top font-mono text-xs text-gray-700 dark:text-gray-200" title={process.command}>{process.command}</td>
              <td className="px-3 py-2 align-top font-mono text-xs text-gray-600 dark:text-gray-300">
                {process.hostname || "-"}
                {process.pid ? <div className="text-gray-500 dark:text-gray-400">pid {process.pid}</div> : null}
              </td>
              <td className="whitespace-nowrap px-3 py-2 align-top text-xs text-gray-700 dark:text-gray-200">{formatDate(process.started_at)}</td>
              <td className="whitespace-nowrap px-3 py-2 align-top text-xs text-gray-700 dark:text-gray-200">
                {formatDate(process.last_chunk_at)}
                {process.stale ? <span className="ml-1 rounded bg-amber-200 dark:bg-amber-900/70 px-1 text-[0.65rem] font-semibold uppercase text-amber-900 dark:text-amber-100">{t("processes.stale")}</span> : null}
              </td>
              <td className="px-3 py-2 align-top text-xs text-gray-700 dark:text-gray-200">{formatDuration(process.duration_s)}</td>
              <td className="px-3 py-2 align-top text-xs"><Outcome process={process} /></td>
              <td className="space-x-3 whitespace-nowrap px-3 py-2 text-right align-top text-xs">
                <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={`${basePath}/${process.id}`}>{t("processes.detail")}</Link>
                <KillButton process={process} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ProcessDetail({ process, prefix }: { process: SpawnedProcessPayload; prefix: string }) {
  const { t } = useT("admin")
  return (
    <div className="space-y-5 p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">#{process.id}</h2>
            <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-medium text-gray-700 dark:text-gray-200">{process.kind}</span>
          </div>
          <p className="mt-2 break-all font-mono text-xs text-gray-600 dark:text-gray-300">{process.command}</p>
        </div>
        <KillButton process={process} />
      </div>

      <dl className="grid grid-cols-1 gap-x-6 gap-y-3 text-sm sm:grid-cols-[10rem_1fr]">
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_hostname")}</dt>
        <dd className="font-mono text-gray-900 dark:text-gray-100">{process.hostname || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_pid_pgid")}</dt>
        <dd className="font-mono text-gray-900 dark:text-gray-100">{process.pid || "-"} / {process.pgid || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_workdir")}</dt>
        <dd className="break-all font-mono text-gray-900 dark:text-gray-100">{process.workdir || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_started")}</dt>
        <dd>{formatDate(process.started_at)}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_last_chunk")}</dt>
        <dd>{formatDate(process.last_chunk_at)} {process.stale ? <span className="rounded bg-amber-200 dark:bg-amber-900/70 px-1 text-[0.65rem] font-semibold uppercase text-amber-900 dark:text-amber-100">{t("processes.stale")}</span> : null}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_finished")}</dt>
        <dd>{formatDate(process.finished_at)}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_duration")}</dt>
        <dd>{formatDuration(process.duration_s)}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_outcome")}</dt>
        <dd><Outcome process={process} /></dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_wall_timeout")}</dt>
        <dd>{formatDuration(process.wall_timeout_s)}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_silent_timeout")}</dt>
        <dd>{formatDuration(process.silent_timeout_s)}</dd>
        {process.run_id ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_run")}</dt>
            <dd><Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix(`/admin/runs/${process.run_id}/transcript`, prefix)}>#{process.run_id}</Link></dd>
          </>
        ) : null}
        {process.workflow_id ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_workflow")}</dt>
            <dd>
              {process.workflow_path ? (
                <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix(process.workflow_path, prefix)}>
                  {process.workflow_slug || workflowSlug(process.workflow_id)}
                </Link>
              ) : process.workflow_slug || workflowSlug(process.workflow_id)}
            </dd>
          </>
        ) : null}
        {process.kill_requested_at ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_kill_requested")}</dt>
            <dd>{formatDate(process.kill_requested_at)}</dd>
          </>
        ) : null}
      </dl>

      {process.host_metrics ? <HostMetrics metrics={process.host_metrics} /> : null}
    </div>
  )
}

function KillButton({ process }: { process: SpawnedProcessPayload }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const kill = useMutation({
    mutationFn: () => killAdminProcess(process.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(["admin", "processes", String(process.id)], updated)
      void queryClient.invalidateQueries({ queryKey: ["admin", "processes"] })
    }
  })

  if (process.finished_at || process.kill_requested_at) return null

  return (
    <button
      className="inline-flex items-center rounded bg-red-600 dark:bg-red-500 px-2 py-0.5 text-xs font-medium text-white hover:bg-red-700 dark:hover:bg-red-400 disabled:cursor-not-allowed disabled:bg-red-300 dark:disabled:bg-red-900"
      disabled={kill.isPending}
      onClick={() => kill.mutate()}
      type="button"
    >
      {kill.isPending ? t("processes.killing") : t("processes.kill")}
    </button>
  )
}

function HostMetrics({ metrics }: { metrics: Record<string, unknown> }) {
  const { t } = useT("admin")
  return (
    <div className="border-t border-gray-200 dark:border-gray-700 pt-4">
      <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">{t("processes.host_metrics")}</h3>
      <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
        {Object.entries(metrics).map(([key, value]) => (
          <div key={key}>
            <dt className="text-gray-500 dark:text-gray-400">{key}</dt>
            <dd className="font-mono text-gray-900 dark:text-gray-100">{String(value ?? "-")}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

function Outcome({ process }: { process: SpawnedProcessPayload }) {
  if (process.finished_at) {
    return <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-medium text-gray-700 dark:text-gray-200">{process.outcome || "finished"}</span>
  }
  if (process.kill_requested_at) {
    return <span className="rounded bg-amber-100 dark:bg-amber-950/60 px-2 py-0.5 font-medium text-amber-800 dark:text-amber-200">kill requested</span>
  }
  return <span className="rounded bg-blue-100 dark:bg-blue-950/60 px-2 py-0.5 font-medium text-blue-800">running</span>
}

function ProcessError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("processes.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function formatDate(value: string | null) {
  if (!value) return "-"

  return new Date(value).toLocaleString()
}

function formatDuration(value: number | null) {
  if (value == null) return "-"
  if (value < 60) return `${Math.round(value)}s`

  const minutes = Math.floor(value / 60)
  if (minutes < 60) return`${minutes}m`

  const hours = Math.floor(minutes / 60)
  return`${hours}h ${minutes % 60}m`
}
