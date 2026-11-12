import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchAdminBrowserError, fetchAdminBrowserErrorControls, fetchAdminBrowserErrors, type BrowserErrorEventRow, type BrowserErrorEventsPayload } from "../api/adminBrowserErrors"
import { AdminEventActions } from "../components/AdminEventActions"
import { AdminDataTablePanel, type AdminDataTablePanelConfig, AdminEventFilterBar, AdminEventLogTable, type AdminEventLogTableColumn, AdminEventPageShell, AdminEventPanelMessage, DetailBlock, JsonBlock, formatEventDate, shortRevision } from "../components/AdminEventLogPanel"
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
  const controls = useQuery({
    queryKey: ["admin", "browser_errors", "controls"],
    queryFn: fetchAdminBrowserErrorControls,
    staleTime: Infinity
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
      <BrowserErrorFilters filterSchema={controls.data?.filter_schema} payload={errors.data} search={search} onNavigate={navigateSearch} />
      {errors.isPending ? <AdminEventPanelMessage>{t("browser_errors.loading")}</AdminEventPanelMessage> : null}
      {errors.isError ? <AdminEventPanelMessage tone="error">{errorMessage(errors.error, t("browser_errors.error_load"))}</AdminEventPanelMessage> : null}
      {errors.isSuccess ? <BrowserErrorsView actions={controls.data?.actions || errors.data.actions} payload={errors.data} search={search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function BrowserErrorFilters({ filterSchema, onNavigate, payload, search }: { filterSchema?: NonNullable<BrowserErrorEventsPayload["filter_schema"]>; onNavigate: (params: URLSearchParams) => void; payload?: BrowserErrorEventsPayload; search: string }) {
  const { t } = useT("admin")
  return <AdminEventFilterBar clearLabel={t("browser_errors.clear")} filter={payload?.filter} filterSchema={filterSchema} fields={[
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

function BrowserErrorsView({ actions, onNavigate, payload, search }: { actions: BrowserErrorEventsPayload["actions"]; onNavigate: (params: URLSearchParams) => void; payload: BrowserErrorEventsPayload; search: string }) {
  const { t } = useT("admin")
  const panel = {
    summary: t("browser_errors.showing", { count: payload.events.length, page: payload.pagination.page }),
    meta: t("browser_errors.revision_hint", { revision: payload.revision_scope === "all" ? t("browser_errors.all_revisions") : shortRevision(payload.current_revision) }),
    pagination: {
      label: t("browser_errors.page", { page: payload.pagination.page }),
      nextLabel: t("browser_errors.next"),
      previousLabel: t("browser_errors.previous"),
      pagination: payload.pagination,
      search,
      onNavigate
    }
  }

  if (payload.events.length === 0) {
    return (
      <AdminDataTablePanel config={panel}>
        <AdminEventPanelMessage>{t("browser_errors.empty")}</AdminEventPanelMessage>
      </AdminDataTablePanel>
    )
  }

  return (
    <BrowserErrorsTable actions={actions} panel={panel} revisionScope={payload.revision_scope} rows={payload.events} search={search} onNavigate={onNavigate} />
  )
}

function BrowserErrorsTable({ actions, onNavigate, panel, revisionScope, rows, search }: { actions: BrowserErrorEventsPayload["actions"]; onNavigate: (params: URLSearchParams) => void; panel: AdminDataTablePanelConfig; revisionScope: string; rows: BrowserErrorEventRow[]; search: string }) {
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
        </>
      )
    },
    {
      className: "w-32 px-4 py-3 align-top",
      headerClassName: "w-32 px-4 py-2",
      header: t("browser_errors.col_actions"),
      key: "actions",
      // Action controls intentionally are not sortable; every data-bearing
      // column above declares a sort key.
      // Pin to the declared end (its natural, already-rightmost position) --
      // required columns default to start-pinning, which would otherwise
      // yank the only expand/collapse toggle in front of time/path/user.
      pin: "end",
      required: true,
      render: (row, state) => (
        <AdminEventActions actions={actions} eventId={row.id} eventType="browser_error" showDetailsLabel={state.expanded ? t("browser_errors.hide_details") : t("browser_errors.show_details")} onToggleDetails={state.toggleExpanded} />
      )
    }
  ]

  return (
    <AdminEventLogTable
      columns={columns}
      getRowKey={(row) => row.id}
      rows={rows}
      search={search}
      storageKey="syrus.admin.browser_errors.visible_columns"
      onNavigate={onNavigate}
      panel={panel}
      renderExpanded={(row) => <BrowserErrorDetails id={row.id} />}
    />
  )
}

function BrowserErrorDetails({ id }: { id: number }) {
  const { t } = useT("admin")
  const detail = useQuery({ queryKey: ["admin", "browser_errors", id], queryFn: () => fetchAdminBrowserError(id) })
  if (!detail.data) return <AdminEventPanelMessage>{t("browser_errors.loading")}</AdminEventPanelMessage>
  return <div className="grid gap-4 lg:grid-cols-2">
    <DetailBlock title={t("browser_errors.stack")} value={detail.data.stack} />
    <DetailBlock title={t("browser_errors.component_stack")} value={detail.data.component_stack} />
    <JsonBlock title={t("browser_errors.recent_api_requests")} value={detail.data.recent_api_requests} />
    <JsonBlock title={t("browser_errors.recent_errors")} value={detail.data.recent_errors} />
    <JsonBlock title={t("browser_errors.environment")} value={{ viewport: detail.data.viewport, feature_flags: detail.data.feature_flags, metadata: detail.data.metadata, route_params: detail.data.route_params, url: detail.data.url, user_agent: detail.data.user_agent }} />
  </div>
}

export default AdminBrowserErrors
