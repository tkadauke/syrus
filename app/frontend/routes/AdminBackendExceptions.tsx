import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { fetchAdminBackendExceptions, type BackendExceptionEventRow, type BackendExceptionEventsPayload } from "../api/adminBackendExceptions"
import { AdminEventActions } from "../components/AdminEventActions"
import { AdminEventFilterBar, AdminEventLogTable, type AdminEventLogTableColumn, AdminEventPageShell, AdminEventPagination, AdminEventPanelMessage, DetailBlock, JsonBlock, formatEventDate, shortRevision } from "../components/AdminEventLogPanel"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const revisionScopes = ["current", "all"] as const

export function AdminBackendExceptions() {
  const { t } = useT("admin")
  const location = useLocation()
  const navigate = useNavigate()
  usePageTitle(t("page_title_backend_exceptions"))
  const search = normalizedSearch(location.search)
  const exceptions = useQuery({
    queryKey: ["admin", "backend_exceptions", search],
    queryFn: () => fetchAdminBackendExceptions(search),
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
          disabled={exceptions.isFetching}
          onClick={() => void exceptions.refetch()}
          type="button"
        >
          {exceptions.isFetching ? t("backend_exceptions.refreshing") : t("backend_exceptions.refresh")}
        </button>
      }
      ariaLabel={t("backend_exceptions.aria")}
      eyebrow={t("section_label")}
      title={t("backend_exceptions.heading")}
    >
      <BackendExceptionFilters search={search} payload={exceptions.data} onNavigate={navigateSearch} />
      {exceptions.isPending ? <AdminEventPanelMessage>{t("backend_exceptions.loading")}</AdminEventPanelMessage> : null}
      {exceptions.isError ? <AdminEventPanelMessage tone="error">{errorMessage(exceptions.error, t("backend_exceptions.error_load"))}</AdminEventPanelMessage> : null}
      {exceptions.isSuccess ? <BackendExceptionsView payload={exceptions.data} search={search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function BackendExceptionFilters({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload?: BackendExceptionEventsPayload; search: string }) {
  const { t } = useT("admin")
  return <AdminEventFilterBar clearLabel={t("backend_exceptions.clear")} filter={payload?.filter} filterSchema={payload?.filter_schema} fields={[
    { name: "query", label: t("backend_exceptions.query"), placeholder: t("backend_exceptions.query_placeholder") },
    { name: "since", label: t("backend_exceptions.since"), defaultValue: "24h", placeholder: "24h" },
    { name: "until", label: t("backend_exceptions.until"), placeholder: t("backend_exceptions.until_placeholder") },
    { name: "source", label: t("backend_exceptions.source"), options: [
      { value: "", label: t("backend_exceptions.all_sources") },
      ...(payload?.sources || []).map((source) => ({ value: source, label: source }))
    ] },
    { name: "exception_class", label: t("backend_exceptions.exception_class"), placeholder: "ActiveRecord::..." },
    { name: "path", label: t("backend_exceptions.path"), placeholder: "/api/..." },
    { name: "fingerprint", label: t("backend_exceptions.fingerprint"), placeholder: "sha..." },
    { name: "revision_scope", label: t("backend_exceptions.revision_scope"), defaultValue: "current", options: revisionScopes.map((scope) => ({ value: scope, label: t(`backend_exceptions.revision_${scope}`) })) },
    { name: "per_page", label: t("backend_exceptions.per_page"), defaultValue: "50", options: [25, 50, 100].map((value) => ({ value: String(value), label: String(value) })) }
  ]} search={search} searchLabel={t("backend_exceptions.search")} onNavigate={onNavigate} />
}

function BackendExceptionsView({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload: BackendExceptionEventsPayload; search: string }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
        <span>{t("backend_exceptions.showing", { count: payload.events.length, page: payload.pagination.page })}</span>
        <span>{t("backend_exceptions.revision_hint", { revision: payload.revision_scope === "all" ? t("backend_exceptions.all_revisions") : shortRevision(payload.current_revision) })}</span>
      </div>
      {payload.events.length > 0 ? <BackendExceptionsTable revisionScope={payload.revision_scope} rows={payload.events} search={search} onNavigate={onNavigate} /> : <AdminEventPanelMessage>{t("backend_exceptions.empty")}</AdminEventPanelMessage>}
      <AdminEventPagination
        label={t("backend_exceptions.page", { page: payload.pagination.page })}
        nextLabel={t("backend_exceptions.next")}
        previousLabel={t("backend_exceptions.previous")}
        pagination={payload.pagination}
        search={search}
        onNavigate={onNavigate}
      />
    </section>
  )
}

function BackendExceptionsTable({ onNavigate, revisionScope, rows, search }: { onNavigate: (params: URLSearchParams) => void; revisionScope: string; rows: BackendExceptionEventRow[]; search: string }) {
  const { t } = useT("admin")
  const columns: Array<AdminEventLogTableColumn<BackendExceptionEventRow>> = [
    {
      className: "w-36 whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "w-36 px-4 py-2",
      header: t("backend_exceptions.col_time"),
      key: "time",
      sort: "time",
      render: (row) => (
        <>
          {formatEventDate(row.occurred_at)}
          {revisionScope === "all" ? <div className="mt-1 text-gray-500 dark:text-gray-400">{shortRevision(row.app_revision)}</div> : null}
        </>
      )
    },
    {
      className: "w-64 px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "w-64 px-4 py-2",
      header: t("backend_exceptions.col_context"),
      key: "context",
      sort: "context",
      render: (row) => {
        const context = row.source === "active_job"
          ? [row.job_class, row.queue_name ? `queue ${row.queue_name}` : null].filter(Boolean).join(" · ")
          : [row.method, row.path, row.status].filter(Boolean).join(" ")
        return (
          <>
            <div className="font-mono">{row.source}</div>
            <div className="mt-1 break-words">{context || "-"}</div>
            {row.job_id ? <Link className="mt-1 inline-block underline" to={`/jobs/${row.job_id}`}>JOB-{row.job_id}</Link> : null}
          </>
        )
      }
    },
    {
      className: "px-4 py-3 align-top",
      headerClassName: "px-4 py-2",
      header: t("backend_exceptions.col_error"),
      key: "error",
      sort: "error",
      render: (row) => (
        <>
          <div className="break-words font-medium text-gray-900 dark:text-gray-100">{row.message}</div>
          <div className="mt-1 break-all font-mono text-xs text-gray-500 dark:text-gray-400">{row.exception_class} · {row.fingerprint}</div>
        </>
      )
    },
    {
      className: "w-48 px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "w-48 px-4 py-2",
      header: t("backend_exceptions.col_runtime"),
      key: "runtime",
      sort: "runtime",
      render: (row) => (
        <>
          <div>{row.role || "-"} {row.hostname ? `@ ${row.hostname}` : ""}</div>
          {row.request_id ? <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">request {row.request_id}</div> : null}
          {row.active_job_id ? <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">active job {row.active_job_id}</div> : null}
        </>
      )
    },
    {
      className: "w-32 px-4 py-3 align-top",
      headerClassName: "w-32 px-4 py-2",
      header: t("backend_exceptions.col_actions"),
      key: "actions",
      render: (row, state) => (
        <AdminEventActions actions={row.actions} eventId={row.id} eventType="backend_exception" showDetailsLabel={state.expanded ? t("backend_exceptions.hide_details") : t("backend_exceptions.show_details")} onToggleDetails={state.toggleExpanded} />
      )
    }
  ]

  return (
    <AdminEventLogTable
      columns={columns}
      getRowKey={(row) => row.id}
      rows={rows}
      search={search}
      onNavigate={onNavigate}
      renderExpanded={(row) => (
        <div className="grid gap-4 lg:grid-cols-2">
          <DetailBlock title={t("backend_exceptions.backtrace")} value={row.backtrace} />
          <JsonBlock title={t("backend_exceptions.request_context")} value={{ controller: row.controller, action: row.action, method: row.method, path: row.path, status: row.status, request_id: row.request_id }} />
          <JsonBlock title={t("backend_exceptions.job_context")} value={{ job_class: row.job_class, active_job_id: row.active_job_id, queue_name: row.queue_name, executions: row.executions, job_id: row.job_id, workflow_id: row.workflow_id, run_id: row.run_id }} />
          <JsonBlock title={t("backend_exceptions.environment")} value={{ role: row.role, hostname: row.hostname, pid: row.pid, metadata: row.metadata || {} }} />
        </div>
      )}
    />
  )
}

function normalizedSearch(search: string) {
  if (search) return search
  return "?since=24h&revision_scope=current&per_page=50"
}

export default AdminBackendExceptions
