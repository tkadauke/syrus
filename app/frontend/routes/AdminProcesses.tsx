import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading, SectionHeading } from "../components/Heading"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import { Button } from "../components/Button"
import { FilterBar } from "../components/FilterBar"
import { adminSmartFolderFilterLinkBuilder } from "../lib/adminSmartFolderLinks"
import {
  fetchAdminProcess,
  fetchAdminProcesses,
  killAdminProcess,
  type SpawnedProcessOwner,
  type SpawnedProcessPayload,
  type SpawnedProcessUser
} from "../api/adminProcesses"
import { workflowSlug } from "../lib/slugs"
import { DataTable, Page } from "../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "../components/dataTable"

export function AdminProcessesIndex() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_processes"))
  const location = useLocation()
  const queryClient = useQueryClient()
  const prefix = routePrefix(location.pathname)
  const basePath = location.pathname.startsWith("/app-shell") ? "/app-shell/admin/processes" : "/admin/processes"
  // A bare visit to this path (no query at all) defaults to the "Running"
  // smart folder server-side. The "All" nav link marks its request
  // explicitly with an empty smart_folder_id so it isn't swallowed by
  // that default and still shows the unfiltered active+recent view.
  const allPath = `${basePath}?smart_folder_id=`
  const processes = useQuery({
    queryKey: ["admin", "processes", location.search],
    queryFn: () => fetchAdminProcesses(location.search)
  })
  const activeUserFolderId = processes.data?.smart_folders.find((folder) => folder.id === processes.data.active_smart_folder_id && folder.kind === "user_defined")?.id

  return (
    <Page.Root aria-label={t("processes.aria_index")} gutter="responsive" size="wide">
      <Page.Header className="block border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <PageHeading className="mt-1">{t("processes.heading")}</PageHeading>
      </Page.Header>

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
              allPath={allPath}
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
            <ProcessesTable basePath={basePath} prefix={prefix} processes={processes.data.processes} />
          </section>
        </AdminFiltersLayout>
      ) : null}
    </Page.Root>
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
    <Page.Root aria-label={t("processes.aria_detail")} className="max-w-5xl" gutter="responsive">
      <Page.Header className="block border-b border-gray-200 dark:border-gray-700 pb-4">
        <Link className="text-sm text-brand underline hover:no-underline" to={basePath}>{t("processes.heading")}</Link>
        <PageHeading className="mt-2">{t("processes.detail_heading")}{id ? ` #${id}` : ""}</PageHeading>
      </Page.Header>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {process.isPending ? <PanelMessage>{t("processes.loading")}</PanelMessage> : null}
        {process.isError ? <ProcessError error={process.error} /> : null}
        {process.isSuccess ? <ProcessDetail prefix={prefix} process={process.data} /> : null}
      </section>
    </Page.Root>
  )
}

const PROCESSES_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.admin.processes.visible_columns"

function buildProcessesColumns({ basePath, prefix, t }: { basePath: string; prefix: string; t: (key: string) => string }): DataTableColumnDef<SpawnedProcessPayload>[] {
  return [
    {
      key: "kind",
      label: t("processes.col_kind"),
      required: true,
      cellClassName: "align-top",
      renderCell: (process) => <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-medium text-gray-700 dark:text-gray-200">{process.kind}</span>
    },
    { key: "command", label: t("processes.col_command"), cellClassName: "max-w-md truncate align-top font-mono text-xs text-gray-700 dark:text-gray-200", renderCell: (process) => <span title={process.command}>{process.command}</span> },
    { key: "user", label: t("processes.col_user"), cellClassName: "max-w-xs align-top text-xs text-gray-700 dark:text-gray-200", renderCell: (process) => <UserLabel prefix={prefix} user={process.user} /> },
    { key: "owner", label: t("processes.col_owner"), cellClassName: "max-w-xs align-top text-xs text-gray-700 dark:text-gray-200", renderCell: (process) => <OwnerLabel owner={process.owner} prefix={prefix} /> },
    {
      key: "host_pid",
      label: t("processes.col_host_pid"),
      cellClassName: "align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      renderCell: (process) => (
        <>
          {process.hostname || "-"}
          {process.pid ? <div className="text-gray-500 dark:text-gray-400">pid {process.pid}</div> : null}
        </>
      )
    },
    { key: "started", label: t("processes.col_started"), cellClassName: "whitespace-nowrap align-top text-xs text-gray-700 dark:text-gray-200", renderCell: (process) => <RelativeTimestamp value={process.started_at} /> },
    {
      key: "last_chunk",
      label: t("processes.col_last_chunk"),
      cellClassName: "whitespace-nowrap align-top text-xs text-gray-700 dark:text-gray-200",
      renderCell: (process) => (
        <>
          <RelativeTimestamp value={process.last_chunk_at} />
          {process.stale ? <span className="ml-1 rounded bg-amber-200 dark:bg-amber-900/70 px-1 text-2xs font-semibold uppercase text-amber-900 dark:text-amber-100">{t("processes.stale")}</span> : null}
        </>
      )
    },
    { key: "duration", label: t("processes.col_duration"), cellClassName: "align-top text-xs text-gray-700 dark:text-gray-200", renderCell: (process) => formatDuration(process.duration_s) },
    { key: "outcome", label: t("processes.col_outcome"), cellClassName: "align-top text-xs", renderCell: (process) => <Outcome process={process} /> },
    {
      key: "actions",
      label: t("processes.col_actions"),
      required: true,
      pin: "end",
      align: "right",
      cellClassName: "space-x-3 whitespace-nowrap align-top text-xs",
      renderCell: (process) => (
        <>
          <Link className="text-brand underline hover:no-underline" to={`${basePath}/${process.id}`}>{t("processes.detail")}</Link>
          <KillButton process={process} />
        </>
      )
    }
  ]
}

function ProcessesTable({ processes, basePath, prefix }: { processes: SpawnedProcessPayload[]; basePath: string; prefix: string }) {
  const { t } = useT("admin")
  const columns = buildProcessesColumns({ basePath, prefix, t })
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: PROCESSES_VISIBLE_COLUMNS_STORAGE_KEY })

  if (processes.length === 0) return <PanelMessage>{t("processes.no_match")}</PanelMessage>

  return (
    <div>
      <div className="flex justify-end border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <DataTableColumnMenu
          columns={columns}
          downLabel={t("event_log_table.column_down")}
          menuId="admin-processes-columns-menu"
          moveDownLabel={(title) => t("event_log_table.column_move_down", { title })}
          moveUpLabel={(title) => t("event_log_table.column_move_up", { title })}
          onChange={preferences.onChange}
          order={preferences.order}
          triggerAriaLabel={t("event_log_table.columns")}
          upLabel={t("event_log_table.column_up")}
          visibleLabel={t("event_log_table.visible_columns")}
        />
      </div>
      <DataTable.Root>
        <DataTable.Header>
          <DataTableColumnHeaderRow columns={columns} onReorder={preferences.onChange} order={preferences.order} />
        </DataTable.Header>
        <DataTable.Body>
          {processes.map((process) => (
            <DataTable.Row className={process.stale ? "bg-amber-50 dark:bg-amber-950/40" : ""} key={process.id}>
              <DataTableColumnCells columns={columns} order={preferences.order} row={process} />
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
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
            <SectionHeading>#{process.id}</SectionHeading>
            <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-medium text-gray-700 dark:text-gray-200">{process.kind}</span>
          </div>
          <p className="mt-2 break-all font-mono text-xs text-gray-600 dark:text-gray-300">{process.command}</p>
        </div>
        <KillButton process={process} />
      </div>

      <dl className="grid grid-cols-1 gap-x-6 gap-y-3 text-sm sm:grid-cols-[10rem_1fr]">
        {process.owner ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_owner")}</dt>
            <dd><OwnerLabel owner={process.owner} prefix={prefix} /></dd>
          </>
        ) : null}
        {process.user ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_user")}</dt>
            <dd><UserLabel user={process.user} prefix={prefix} /></dd>
          </>
        ) : null}
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_hostname")}</dt>
        <dd className="font-mono text-gray-900 dark:text-gray-100">{process.hostname || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_pid_pgid")}</dt>
        <dd className="font-mono text-gray-900 dark:text-gray-100">{process.pid || "-"} / {process.pgid || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_workdir")}</dt>
        <dd className="break-all font-mono text-gray-900 dark:text-gray-100">{process.workdir || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_started")}</dt>
        <dd><RelativeTimestamp value={process.started_at} /></dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_last_chunk")}</dt>
        <dd><RelativeTimestamp value={process.last_chunk_at} /> {process.stale ? <span className="rounded bg-amber-200 dark:bg-amber-900/70 px-1 text-2xs font-semibold uppercase text-amber-900 dark:text-amber-100">{t("processes.stale")}</span> : null}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_finished")}</dt>
        <dd><RelativeTimestamp value={process.finished_at} /></dd>
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
            <dd><Link className="text-brand underline hover:no-underline" to={withRoutePrefix(`/admin/runs/${process.run_id}/transcript`, prefix)}>#{process.run_id}</Link></dd>
          </>
        ) : null}
        {process.workflow_id ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_workflow")}</dt>
            <dd>
              {process.workflow_path ? (
                <Link className="text-brand underline hover:no-underline" to={withRoutePrefix(process.workflow_path, prefix)}>
                  {process.workflow_slug || workflowSlug(process.workflow_id)}
                </Link>
              ) : process.workflow_slug || workflowSlug(process.workflow_id)}
            </dd>
          </>
        ) : null}
        {process.kill_requested_at ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_kill_requested")}</dt>
            <dd><RelativeTimestamp value={process.kill_requested_at} /></dd>
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
    <Button
      disabled={kill.isPending}
      onClick={() => kill.mutate()}
      size="sm"
      variant="danger"
    >
      {kill.isPending ? t("processes.killing") : t("processes.kill")}
    </Button>
  )
}

function HostMetrics({ metrics }: { metrics: Record<string, unknown> }) {
  const { t } = useT("admin")
  return (
    <div className="border-t border-gray-200 dark:border-gray-700 pt-4">
      <SectionHeading as="h3">{t("processes.host_metrics")}</SectionHeading>
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

function OwnerLabel({ owner, prefix }: { owner: SpawnedProcessOwner | null; prefix: string }) {
  const { t } = useT("admin")
  if (!owner) return <span className="text-gray-400 dark:text-gray-500">{t("processes.owner_unknown")}</span>
  if (!owner.path) return <span>{owner.label}</span>

  return (
    <Link className="text-brand underline hover:no-underline" to={withRoutePrefix(owner.path, prefix)}>
      {owner.label}
    </Link>
  )
}

function UserLabel({ user, prefix }: { user: SpawnedProcessUser | null; prefix: string }) {
  const { t } = useT("admin")
  if (!user) return <span className="text-gray-400 dark:text-gray-500">{t("processes.owner_unknown")}</span>

  const label = user.email_address && user.email_address !== user.label ? `${user.label} (${user.email_address})` : user.label
  if (!user.path) return <span>{label}</span>

  return (
    <Link className="text-brand underline hover:no-underline" to={withRoutePrefix(user.path, prefix)}>
      {label}
    </Link>
  )
}

function Outcome({ process }: { process: SpawnedProcessPayload }) {
  const { t } = useT("admin")
  if (process.finished_at) {
    const label = process.outcome
      ? t(`processes.outcome_${process.outcome}`, { defaultValue: process.outcome })
      : t("processes.outcome_finished")
    return <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-medium text-gray-700 dark:text-gray-200">{label}</span>
  }
  if (process.kill_requested_at) {
    return <span className="rounded bg-amber-100 dark:bg-amber-950/60 px-2 py-0.5 font-medium text-amber-800 dark:text-amber-200">{t("processes.outcome_kill_requested")}</span>
  }
  return <span className="rounded border border-info bg-surface-raised px-2 py-0.5 font-medium text-info">{t("processes.outcome_running")}</span>
}

function ProcessError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("processes.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function formatDuration(value: number | null) {
  if (value == null) return "-"
  if (value < 60) return `${Math.round(value)}s`

  const minutes = Math.floor(value / 60)
  if (minutes < 60) return`${minutes}m`

  const hours = Math.floor(minutes / 60)
  return`${hours}h ${minutes % 60}m`
}
