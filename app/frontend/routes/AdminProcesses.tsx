import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { SectionHeading } from "../components/Heading"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { AdminEventLogTable, type AdminEventLogTableColumn } from "../components/AdminEventLogPanel"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import { Button } from "../components/Button"
import { FilterBar } from "../components/FilterBar"
import { adminSmartFolderFilterLinkBuilder } from "../lib/adminSmartFolderLinks"
import {
  fetchAdminProcess,
  fetchAdminProcesses,
  killAdminProcess,
  type AdminProcessesPayload,
  type SpawnedProcessOwner,
  type SpawnedProcessPayload,
  type SpawnedProcessUser
} from "../api/adminProcesses"
import { workflowSlug } from "../lib/slugs"
import { DataTable, Page } from "../components/ui"

export function AdminProcessesIndex() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_processes"))
  const location = useLocation()
  const navigate = useNavigate()
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
  const activeUserFolderId = processes.data?.smart_folders.find(
    (folder) => folder.id === processes.data.active_smart_folder_id && folder.kind === "user_defined"
  )?.id

  return (
    <Page.Root aria-label={t("processes.aria_index")} gutter="responsive" size="wide">
      <Page.Header className="block border-b border-gray-200 dark:border-gray-700 pb-4">
        <Page.HeadingGroup>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <Page.Title className="mt-1">{t("processes.heading")}</Page.Title>
        </Page.HeadingGroup>
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
          <ProcessesTable
            basePath={basePath}
            onNavigate={(params) => navigate(`${location.pathname}?${params.toString()}`)}
            payload={processes.data}
            prefix={prefix}
            search={location.search}
          />
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
    <Page.Root aria-label={t("processes.aria_detail")} gutter="responsive" size="medium">
      <Page.Header className="block border-b border-gray-200 dark:border-gray-700 pb-4">
        <Link className="text-sm text-brand underline hover:no-underline" to={basePath}>
          {t("processes.heading")}
        </Link>
        <Page.Title className="mt-2">
          {t("processes.detail_heading")}
          {id ? ` #${id}` : ""}
        </Page.Title>
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

function buildProcessesColumns({
  basePath,
  prefix,
  t
}: {
  basePath: string
  prefix: string
  t: (key: string) => string
}): Array<AdminEventLogTableColumn<SpawnedProcessPayload>> {
  return [
    {
      key: "kind",
      header: t("processes.col_kind"),
      required: true,
      sort: "kind",
      className: "align-top",
      render: (process) => (
        <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-medium text-gray-700 dark:text-gray-200">{process.kind}</span>
      )
    },
    {
      key: "command",
      header: t("processes.col_command"),
      sort: "command",
      className: "max-w-md truncate align-top font-mono text-xs text-gray-700 dark:text-gray-200",
      render: (process) => <span title={process.command}>{process.command}</span>
    },
    {
      key: "chat_session_id",
      header: t("processes.col_chat_session"),
      sort: "chat_session_id",
      className: "align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      render: (process) => (process.owner?.type === "chat" ? process.owner.label : process.chat_session_id ? `#${process.chat_session_id}` : "-")
    },
    {
      key: "workdir",
      header: t("processes.col_workdir"),
      sort: "workdir",
      className: "max-w-md truncate align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      render: (process) => <span title={process.workdir || undefined}>{process.workdir || "-"}</span>
    },
    {
      key: "user",
      header: t("processes.col_user"),
      className: "max-w-xs align-top text-xs text-gray-700 dark:text-gray-200",
      render: (process) => <UserLabel prefix={prefix} user={process.user} />
    },
    {
      key: "owner",
      header: t("processes.col_owner"),
      className: "max-w-xs align-top text-xs text-gray-700 dark:text-gray-200",
      render: (process) => <OwnerLabel owner={process.owner} prefix={prefix} />
    },
    {
      key: "host_pid",
      header: t("processes.col_host_pid"),
      sort: "hostname",
      className: "align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      render: (process) => (
        <>
          {process.hostname || "-"}
          {process.pid ? <div className="text-gray-500 dark:text-gray-400">pid {process.pid}</div> : null}
        </>
      )
    },
    {
      key: "started",
      header: t("processes.col_started"),
      sort: "started_at",
      className: "whitespace-nowrap align-top text-xs text-gray-700 dark:text-gray-200",
      render: (process) => <RelativeTimestamp value={process.started_at} />
    },
    {
      key: "last_chunk",
      header: t("processes.col_last_chunk"),
      sort: "last_chunk_at",
      className: "whitespace-nowrap align-top text-xs text-gray-700 dark:text-gray-200",
      render: (process) => (
        <>
          <RelativeTimestamp value={process.last_chunk_at} />
          {process.stale ? (
            <span className="ml-1 rounded bg-amber-200 dark:bg-amber-900/70 px-1 text-2xs font-semibold uppercase text-amber-900 dark:text-amber-100">
              {t("processes.stale")}
            </span>
          ) : null}
        </>
      )
    },
    {
      key: "duration",
      header: t("processes.col_duration"),
      sort: "duration",
      className: "align-top text-xs text-gray-700 dark:text-gray-200",
      render: (process) => formatDuration(process.duration_s)
    },
    {
      key: "timeouts",
      header: t("processes.col_timeouts"),
      className: "align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      render: (process) => `${formatDuration(process.wall_timeout_s)} / ${formatDuration(process.silent_timeout_s)}`
    },
    {
      key: "exit_status",
      header: t("processes.col_exit_status"),
      sort: "exit_status",
      className: "align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      render: (process) => process.exit_status ?? "-"
    },
    { key: "outcome", header: t("processes.col_outcome"), sort: "outcome", className: "align-top text-xs", render: (process) => <Outcome process={process} /> },
    {
      key: "kill_requested",
      header: t("processes.col_kill_requested"),
      sort: "kill_requested_at",
      className: "whitespace-nowrap align-top text-xs text-gray-700 dark:text-gray-200",
      render: (process) => <RelativeTimestamp value={process.kill_requested_at} />
    },
    {
      key: "actions",
      header: t("processes.col_actions"),
      required: true,
      pin: "end",
      className: "space-x-3 whitespace-nowrap align-top text-right text-xs",
      render: (process) => (
        <>
          <Link className="text-brand underline hover:no-underline" to={`${basePath}/${process.id}`}>
            {t("processes.detail")}
          </Link>
          <KillButton process={process} />
        </>
      )
    }
  ]
}

function ProcessesTable({
  basePath,
  onNavigate,
  payload,
  prefix,
  search
}: {
  basePath: string
  onNavigate: (params: URLSearchParams) => void
  payload: AdminProcessesPayload
  prefix: string
  search: string
}) {
  const { t } = useT("admin")
  const columns = buildProcessesColumns({ basePath, prefix, t })
  const processes = payload.processes

  if (processes.length === 0) return <PanelMessage>{t("processes.no_match")}</PanelMessage>

  return (
    <AdminEventLogTable
      columns={columns}
      defaultSort={payload.sort}
      getRowKey={(process) => process.id}
      onNavigate={onNavigate}
      panel={processesTablePanel(t, payload, onNavigate, search)}
      rows={processes}
      search={search}
      storageKey={PROCESSES_VISIBLE_COLUMNS_STORAGE_KEY}
      tableClassName="min-w-[78rem] table-auto divide-y divide-border text-sm"
    />
  )
}

function processesTablePanel(
  t: (key: string, options?: Record<string, number>) => string,
  payload: AdminProcessesPayload,
  onNavigate: (params: URLSearchParams) => void,
  search: string
) {
  return {
    meta: t("processes.running_count", { count: payload.running_total }),
    pagination: {
      ariaLabel: t("processes.pagination_aria"),
      label: t("processes.page_of", { page: payload.pagination.page, total: payload.pagination.total_pages }),
      nextLabel: t("processes.next"),
      onNavigate,
      pagination: payload.pagination,
      previousLabel: t("processes.previous"),
      search
    },
    summary: t("processes.showing", { first: payload.pagination.first_item, last: payload.pagination.last_item, total: payload.pagination.total })
  }
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
            <dd>
              <OwnerLabel owner={process.owner} prefix={prefix} />
            </dd>
          </>
        ) : null}
        {process.user ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_user")}</dt>
            <dd>
              <UserLabel user={process.user} prefix={prefix} />
            </dd>
          </>
        ) : null}
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_hostname")}</dt>
        <dd className="font-mono text-gray-900 dark:text-gray-100">{process.hostname || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_pid_pgid")}</dt>
        <dd className="font-mono text-gray-900 dark:text-gray-100">
          {process.pid || "-"} / {process.pgid || "-"}
        </dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_workdir")}</dt>
        <dd className="break-all font-mono text-gray-900 dark:text-gray-100">{process.workdir || "-"}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_started")}</dt>
        <dd>
          <RelativeTimestamp value={process.started_at} />
        </dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_last_chunk")}</dt>
        <dd>
          <RelativeTimestamp value={process.last_chunk_at} />{" "}
          {process.stale ? (
            <span className="rounded bg-amber-200 dark:bg-amber-900/70 px-1 text-2xs font-semibold uppercase text-amber-900 dark:text-amber-100">
              {t("processes.stale")}
            </span>
          ) : null}
        </dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_finished")}</dt>
        <dd>
          <RelativeTimestamp value={process.finished_at} />
        </dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_duration")}</dt>
        <dd>{formatDuration(process.duration_s)}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_outcome")}</dt>
        <dd>
          <Outcome process={process} />
        </dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_wall_timeout")}</dt>
        <dd>{formatDuration(process.wall_timeout_s)}</dd>
        <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_silent_timeout")}</dt>
        <dd>{formatDuration(process.silent_timeout_s)}</dd>
        {process.run_id ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_run")}</dt>
            <dd>
              <Link className="text-brand underline hover:no-underline" to={withRoutePrefix(`/admin/runs/${process.run_id}/transcript`, prefix)}>
                #{process.run_id}
              </Link>
            </dd>
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
              ) : (
                process.workflow_slug || workflowSlug(process.workflow_id)
              )}
            </dd>
          </>
        ) : null}
        {process.kill_requested_at ? (
          <>
            <dt className="text-gray-500 dark:text-gray-400">{t("processes.detail_kill_requested")}</dt>
            <dd>
              <RelativeTimestamp value={process.kill_requested_at} />
            </dd>
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
    <Button disabled={kill.isPending} onClick={() => kill.mutate()} size="sm" variant="danger">
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
    const label = process.outcome ? t(`processes.outcome_${process.outcome}`, { defaultValue: process.outcome }) : t("processes.outcome_finished")
    return <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-medium text-gray-700 dark:text-gray-200">{label}</span>
  }
  if (process.kill_requested_at) {
    return (
      <span className="rounded bg-amber-100 dark:bg-amber-950/60 px-2 py-0.5 font-medium text-amber-800 dark:text-amber-200">
        {t("processes.outcome_kill_requested")}
      </span>
    )
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
  if (minutes < 60) return `${minutes}m`

  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}
