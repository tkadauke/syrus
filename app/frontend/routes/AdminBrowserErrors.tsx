import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchAdminBrowserErrors, type BrowserErrorEventRow, type BrowserErrorEventsPayload } from "../api/adminBrowserErrors"
import { AdminEventActions } from "../components/AdminEventActions"
import { AdminEventFilterBar, AdminEventLogTable, type AdminEventLogTableColumn, AdminEventPageShell, AdminEventPagination, AdminEventPanelMessage, DetailBlock, JsonBlock, formatEventDate, shortRevision } from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const revisionScopes = ["current", "all"] as const

export function AdminBrowserErrors() {
  const { t } = useT("admin")
  const location = useLocation()
  const navigate = useNavigate()
  usePageTitle(t("page_title_browser_errors"))
  const search = location.search
  const errors = useQuery({
    queryKey: ["admin", "browser_errors", search],
    queryFn: () => fetchAdminBrowserErrors(search),
    placeholderData: keepPreviousData
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <Button
          className="w-fit"
          disabled={errors.isFetching}
          onClick={() => void errors.refetch()}
          variant="secondary"
        >
          {errors.isFetching ? t("browser_errors.refreshing") : t("browser_errors.refresh")}
        </Button>
      }
      ariaLabel={t("browser_errors.aria")}
      eyebrow={t("section_label")}
      title={t("browser_errors.heading")}
    >
      <BrowserErrorFilters payload={errors.data} search={search} onNavigate={navigateSearch} />
      {errors.isPending ? <AdminEventPanelMessage>{t("browser_errors.loading")}</AdminEventPanelMessage> : null}
      {errors.isError ? <AdminEventPanelMessage tone="error">{errorMessage(errors.error, t("browser_errors.error_load"))}</AdminEventPanelMessage> : null}
      {errors.isSuccess ? <BrowserErrorsView payload={errors.data} search={search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function BrowserErrorFilters({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload?: BrowserErrorEventsPayload; search: string }) {
  const { t } = useT("admin")
  return <AdminEventFilterBar clearLabel={t("browser_errors.clear")} filter={payload?.filter} filterSchema={payload?.filter_schema} fields={[
    { name: "query", label: t("browser_errors.query"), placeholder: t("browser_errors.query_placeholder") },
    { name: "since", label: t("browser_errors.since"), defaultValue: "24h", placeholder: "24h" },
    { name: "until", label: t("browser_errors.until"), placeholder: t("browser_errors.until_placeholder") },
    { name: "id", label: t("browser_errors.id"), placeholder: "123", inputMode: "numeric" },
    { name: "fingerprint", label: t("browser_errors.fingerprint"), placeholder: "sha..." },
    { name: "path", label: t("browser_errors.path"), placeholder: "/jobs/3188" },
    { name: "revision_scope", label: t("browser_errors.revision_scope"), defaultValue: "current", options: revisionScopes.map((scope) => ({ value: scope, label: t(`browser_errors.revision_${scope}`) })) },
    { name: "per_page", label: t("browser_errors.per_page"), defaultValue: "50", options: [25, 50, 100].map((value) => ({ value: String(value), label: String(value) })) }
  ]} search={search} searchLabel={t("browser_errors.search")} onNavigate={onNavigate} />
}

function BrowserErrorsView({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload: BrowserErrorEventsPayload; search: string }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
        <span>{t("browser_errors.showing", { count: payload.events.length, page: payload.pagination.page })}</span>
        <span>{t("browser_errors.revision_hint", { revision: payload.revision_scope === "all" ? t("browser_errors.all_revisions") : shortRevision(payload.current_revision) })}</span>
      </div>
      {payload.events.length > 0 ? <BrowserErrorsTable revisionScope={payload.revision_scope} rows={payload.events} search={search} onNavigate={onNavigate} /> : <AdminEventPanelMessage>{t("browser_errors.empty")}</AdminEventPanelMessage>}
      <AdminEventPagination
        label={t("browser_errors.page", { page: payload.pagination.page })}
        nextLabel={t("browser_errors.next")}
        previousLabel={t("browser_errors.previous")}
        pagination={payload.pagination}
        search={search}
        onNavigate={onNavigate}
      />
    </section>
  )
}

function BrowserErrorsTable({ onNavigate, revisionScope, rows, search }: { onNavigate: (params: URLSearchParams) => void; revisionScope: string; rows: BrowserErrorEventRow[]; search: string }) {
  const { t } = useT("admin")
  const columns: Array<AdminEventLogTableColumn<BrowserErrorEventRow>> = [
    {
      className: "w-36 whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "w-36 px-4 py-2",
      header: t("browser_errors.col_time"),
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
      className: "w-64 px-4 py-3 align-top font-mono text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "w-64 px-4 py-2",
      header: t("browser_errors.col_path"),
      key: "path",
      sort: "path",
      render: (row) => (
        <>
          <div className="break-words">{row.path || "-"}</div>
          {row.trace_id ? <div className="mt-1 text-gray-500 dark:text-gray-400">trace {row.trace_id}</div> : null}
        </>
      )
    },
    {
      className: "px-4 py-3 align-top",
      headerClassName: "px-4 py-2",
      header: t("browser_errors.col_error"),
      key: "error",
      sort: "error",
      render: (row) => (
        <>
          <div className="break-words font-medium text-gray-900 dark:text-gray-100">{row.message}</div>
          <div className="mt-1 break-all font-mono text-xs text-gray-500 dark:text-gray-400">{row.name || "Error"} · {row.fingerprint}</div>
        </>
      )
    },
    {
      className: "w-56 px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "w-56 px-4 py-2",
      header: t("browser_errors.col_user"),
      key: "user",
      sort: "user",
      render: (row) => (
        <>
          <div className="font-medium">{row.user.display_name || row.user.email_address || `User ${row.user.id}`}</div>
          {row.user_agent ? <div className="mt-1 line-clamp-2 text-gray-500 dark:text-gray-400">{row.user_agent}</div> : null}
        </>
      )
    },
    {
      className: "w-32 px-4 py-3 align-top",
      headerClassName: "w-32 px-4 py-2",
      header: t("browser_errors.col_actions"),
      key: "actions",
      render: (row, state) => (
        <AdminEventActions actions={row.actions} eventId={row.id} eventType="browser_error" showDetailsLabel={state.expanded ? t("browser_errors.hide_details") : t("browser_errors.show_details")} onToggleDetails={state.toggleExpanded} />
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
          <DetailBlock title={t("browser_errors.stack")} value={row.stack} />
          <DetailBlock title={t("browser_errors.component_stack")} value={row.component_stack} />
          <JsonBlock title={t("browser_errors.recent_api_requests")} value={row.recent_api_requests || []} />
          <JsonBlock title={t("browser_errors.recent_errors")} value={row.recent_errors || []} />
          <JsonBlock title={t("browser_errors.environment")} value={{ viewport: row.viewport || {}, feature_flags: row.feature_flags || {}, metadata: row.metadata || {}, route_params: row.route_params || {}, url: row.url }} />
        </div>
      )}
    />
  )
}

export default AdminBrowserErrors
