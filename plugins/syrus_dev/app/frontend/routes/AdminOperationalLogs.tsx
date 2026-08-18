import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchAdminOperationalLogs, type OperationalLogRevisionScope, type OperationalLogRow, type OperationalLogsPayload } from "../api/adminOperationalLogs"
import { AdminEventFilterBar, AdminEventLogTable, type AdminEventLogTableColumn, AdminEventPageShell, AdminEventPagination, AdminEventPanelMessage, formatEventDate, shortRevision } from "@app/components/AdminEventLogPanel"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"

const revisionScopes = ["current", "all"] as const

export function AdminOperationalLogs() {
  const { t } = useT("admin")
  const location = useLocation()
  const navigate = useNavigate()
  usePageTitle(t("page_title_operational_logs"))
  const search = normalizedSearch(location.search)
  const logs = useQuery({
    queryKey: ["admin", "operational_logs", search],
    queryFn: () => fetchAdminOperationalLogs(search),
    placeholderData: keepPreviousData
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <button
          className="inline-flex w-fit items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
          disabled={logs.isFetching}
          onClick={() => void logs.refetch()}
          type="button"
        >
          {logs.isFetching ? t("operational_logs.refreshing") : t("operational_logs.refresh")}
        </button>
      }
      ariaLabel={t("operational_logs.aria")}
      eyebrow={t("section_label")}
      title={t("operational_logs.heading")}
    >
      <OperationalLogFilters payload={logs.data} search={search} onNavigate={navigateSearch} />

      {logs.isPending ? <AdminEventPanelMessage>{t("operational_logs.loading")}</AdminEventPanelMessage> : null}
      {logs.isError ? <AdminEventPanelMessage tone="error">{errorMessage(logs.error, t("operational_logs.error_load"))}</AdminEventPanelMessage> : null}
      {logs.isSuccess ? <OperationalLogsView payload={logs.data} search={search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

export default AdminOperationalLogs

function OperationalLogFilters({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload?: OperationalLogsPayload; search: string }) {
  const { t } = useT("admin")
  return <AdminEventFilterBar clearLabel={t("operational_logs.clear")} filter={payload?.filter} filterSchema={payload?.filter_schema} fields={[
    { name: "query", label: t("operational_logs.query"), placeholder: t("operational_logs.query_placeholder") },
    { name: "since", label: t("operational_logs.since"), defaultValue: "1h", placeholder: "1h" },
    { name: "until", label: t("operational_logs.until"), placeholder: t("operational_logs.until_placeholder") },
    { name: "level", label: t("operational_logs.level") },
    { name: "role", label: t("operational_logs.role") },
    { name: "hostname", label: t("operational_logs.hostname"), placeholder: "worker-0" },
    { name: "revision_scope", label: t("operational_logs.revision_scope"), defaultValue: "current", options: revisionScopes.map((scope) => ({ value: scope, label: t(`operational_logs.revision_${scope}`) })) },
    { name: "per_page", label: t("operational_logs.per_page"), defaultValue: "50", options: [25, 50, 100].map((value) => ({ value: String(value), label: String(value) })) }
  ]} search={search} searchLabel={t("operational_logs.search")} onNavigate={onNavigate} />
}

function OperationalLogsView({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload: OperationalLogsPayload; search: string }) {
  const { t } = useT("admin")
  if (!payload.enabled) {
    return <AdminEventPanelMessage tone="warn">{payload.error?.message || t("operational_logs.disabled")}</AdminEventPanelMessage>
  }

  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
        <span>{t("operational_logs.showing", { count: payload.logs.length, page: payload.pagination.page })}</span>
        <span>{t("operational_logs.retention", { hours: Math.round(payload.retention_seconds / 3600), revision: payload.revision_scope === "all" ? t("operational_logs.all_revisions") : shortRevision(payload.current_revision) })}</span>
      </div>
      {payload.logs.length > 0 ? <OperationalLogsTable revisionScope={payload.revision_scope} rows={payload.logs} /> : <AdminEventPanelMessage>{t("operational_logs.empty")}</AdminEventPanelMessage>}
      <AdminEventPagination
        label={t("operational_logs.page", { page: payload.pagination.page })}
        nextLabel={t("operational_logs.next")}
        previousLabel={t("operational_logs.previous")}
        pagination={payload.pagination}
        search={search}
        onNavigate={onNavigate}
      />
    </section>
  )
}

function OperationalLogsTable({ revisionScope, rows }: { revisionScope: OperationalLogRevisionScope; rows: OperationalLogRow[] }) {
  const { t } = useT("admin")
  const columns: Array<AdminEventLogTableColumn<OperationalLogRow>> = [
    {
      className: "w-36 whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "w-36 px-4 py-2",
      header: t("operational_logs.col_time"),
      key: "time",
      render: (row) => formatEventDate(row.occurred_at)
    },
    {
      className: "w-20 px-4 py-3 align-top",
      headerClassName: "w-20 px-4 py-2",
      header: t("operational_logs.col_level"),
      key: "level",
      render: (row) => <LevelBadge level={row.level} />
    },
    {
      className: "w-40 px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "w-40 px-4 py-2",
      header: t("operational_logs.col_process"),
      key: "process",
      render: (row) => (
        <>
          <div className="font-medium">{row.role} · {row.hostname}{row.pid ? ` · pid ${row.pid}` : ""}</div>
          {revisionScope === "all" ? <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">{shortRevision(row.app_revision)}</div> : null}
        </>
      )
    },
    {
      className: "w-40 px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "w-40 px-4 py-2",
      header: t("operational_logs.col_refs"),
      key: "refs",
      render: (row) => refsText(row)
    },
    {
      className: "px-4 py-3 align-top",
      headerClassName: "px-4 py-2",
      header: t("operational_logs.col_message"),
      key: "message",
      render: (row) => (
        <>
          <div className="overflow-hidden break-words font-mono text-xs leading-5 text-gray-900 dark:text-gray-100">{row.message}</div>
          {row.context && Object.keys(row.context).length > 0 ? <div className="mt-2 overflow-hidden break-words font-mono text-xs leading-5 text-gray-500 dark:text-gray-400">{compactContext(row.context, row.message)}</div> : null}
        </>
      )
    }
  ]

  return (
    <AdminEventLogTable columns={columns} getRowKey={(row) => row.id} rows={rows} />
  )
}

function LevelBadge({ level }: { level: string }) {
  const tone = level === "error" || level === "fatal"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300"
    : level === "warn"
      ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "border-gray-200 bg-gray-50 text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200"
  return <span className={`inline-flex rounded border px-2 py-0.5 font-mono text-xs font-medium uppercase ${tone}`}>{level}</span>
}

function normalizedSearch(search: string) {
  if (search) return search
  return "?since=1h&revision_scope=current&per_page=50"
}

function refsText(row: OperationalLogRow) {
  const refs = [
    row.job_id ? `JOB-${row.job_id}` : null,
    row.workflow_id ? `WF-${row.workflow_id}` : null,
    row.run_id ? `RUN-${row.run_id}` : null,
    row.request_id ? `REQ ${row.request_id}` : null
  ].filter(Boolean)
  return refs.length > 0 ? refs.join(" · ") : "-"
}

function compactContext(context: Record<string, string>, message?: string) {
  return Object.entries(context)
    .filter(([key, value]) => key !== "job_class" && value !== message)
    .map(([key, value]) => `${key}=${value}`)
    .join(" ")
}
