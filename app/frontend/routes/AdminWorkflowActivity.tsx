import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { fetchAdminWorkflowActivity, type AdminWorkflowActivityPayload, type WorkflowActivityEvent } from "../api/adminWorkflowActivity"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { AdminEventFilterBar, AdminEventLogTable, type AdminEventLogTableColumn, AdminEventPageShell, AdminEventPanelMessage, adminEventLinkClass, disabledPaginationClass, durationLabel, paginationLinkClass, severityPillClass } from "../components/AdminEventLogPanel"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"

const POLL_INTERVAL_MS = 30_000

export function AdminWorkflowActivity() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_activity"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const activity = useQuery({
    queryKey: ["admin", "workflow_activity", location.search],
    queryFn: ({ signal }) => fetchAdminWorkflowActivity(location.search, signal),
    refetchInterval: POLL_INTERVAL_MS
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <button className="inline-flex shrink-0 items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500" disabled={activity.isFetching} onClick={() => void activity.refetch()} type="button">
          {activity.isFetching ? t("activity.refreshing") : t("activity.refresh")}
        </button>
      }
      ariaLabel={t("activity.aria")}
      eyebrow={t("section_label")}
      title={t("activity.heading")}
    >
      <AdminEventFilterBar clearLabel={t("activity.clear_filters")} fields={[
        { name: "event_type", label: t("activity.filter_event_type"), options: [
          { value: "", label: t("activity.all_event_types") },
          ...(activity.data?.event_types || []).map((type) => ({ value: type, label: type }))
        ] },
        { name: "trigger_kind", label: t("activity.filter_trigger") },
        { name: "reason_key", label: t("activity.filter_reason") },
        { name: "job_id", label: t("activity.filter_job"), inputMode: "numeric" },
        { name: "workflow_id", label: t("activity.filter_workflow"), inputMode: "numeric" },
        { name: "run_id", label: t("activity.filter_run"), inputMode: "numeric" }
      ]} search={location.search} searchLabel={t("activity.apply_filters")} onNavigate={navigateSearch} />

      <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        {activity.isPending ? <AdminEventPanelMessage>{t("activity.loading")}</AdminEventPanelMessage> : null}
        {activity.isError ? <AdminEventPanelMessage tone="error">{t("activity.error_load")}</AdminEventPanelMessage> : null}
        {activity.isSuccess ? <ActivityTable payload={activity.data} prefix={prefix} search={location.search} onNavigate={navigateSearch} /> : null}
      </section>
    </AdminEventPageShell>
  )
}

function ActivityTable({ onNavigate, payload, prefix, search }: { onNavigate: (params: URLSearchParams) => void; payload: AdminWorkflowActivityPayload; prefix: string; search: string }) {
  const { t } = useT("admin")
  if (payload.events.length === 0) return <AdminEventPanelMessage>{t("activity.no_events")}</AdminEventPanelMessage>
  const columns: Array<AdminEventLogTableColumn<WorkflowActivityEvent>> = [
    {
      className: "whitespace-nowrap px-4 py-2 text-xs text-gray-500 dark:text-gray-400",
      headerClassName: "px-4 py-2",
      header: t("activity.col_time"),
      key: "time",
      sort: "time",
      render: (event) => <RelativeTimestamp value={event.occurred_at} />
    },
    {
      className: "px-4 py-2",
      headerClassName: "px-4 py-2",
      header: t("activity.col_type"),
      key: "type",
      sort: "type",
      render: (event) => <span className={`rounded px-1.5 py-0.5 font-mono text-xs ${severityPillClass(event.severity)}`}>{event.event_type}</span>
    },
    {
      className: "px-4 py-2 text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("activity.col_context"),
      key: "context",
      sort: "context",
      render: (event) => <ContextLinks event={event} prefix={prefix} />
    },
    {
      className: "px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("activity.col_state"),
      key: "state",
      sort: "state",
      render: (event) => stateLabel(event)
    },
    {
      className: "whitespace-nowrap px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("activity.col_duration"),
      key: "duration",
      sort: "duration",
      render: (event) => durationLabel(event.duration_ms)
    },
    {
      className: "max-w-3xl px-4 py-2 text-gray-700 dark:text-gray-200",
      headerClassName: "px-4 py-2",
      header: t("activity.col_message"),
      key: "message",
      sort: "message",
      render: (event) => (
        <>
          <div>{event.message}</div>
          <details className="mt-1">
            <summary className="cursor-pointer text-xs text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">metadata</summary>
            <pre className="mt-1 max-h-64 overflow-auto rounded bg-gray-50 p-2 text-xs text-gray-700 dark:bg-gray-950 dark:text-gray-300">{JSON.stringify(event.metadata, null, 2)}</pre>
          </details>
        </>
      )
    },
    {
      className: "px-4 py-2 font-mono text-xs text-gray-500 dark:text-gray-400",
      headerClassName: "px-4 py-2",
      header: t("activity.col_source"),
      key: "source",
      sort: "source",
      render: (event) => event.source
    }
  ]

  return (
    <div>
      <div className="border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
        {t("activity.showing", { first: payload.pagination.first_item, last: payload.pagination.last_item, total: payload.pagination.total })}
      </div>
      <AdminEventLogTable columns={columns} getRowKey={(event) => event.id} rows={payload.events} search={search} tableClassName="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700" onNavigate={onNavigate} />
      <Pagination pagination={payload.pagination} prefix={prefix} />
    </div>
  )
}

function ContextLinks({ event, prefix }: { event: WorkflowActivityEvent; prefix: string }) {
  const links: ReactNode[] = []
  if (event.job) links.push(<Link className={linkClass()} key="job" to={withRoutePrefix(event.job.path, prefix)}>{event.job.slug}</Link>)
  if (event.workflow) links.push(<Link className={linkClass()} key="workflow" to={withRoutePrefix(event.workflow.path, prefix)}>{event.workflow.slug}</Link>)
  if (event.run) links.push(<Link className={linkClass()} key="run" to={withRoutePrefix(event.run.path, prefix)}>Run #{event.run.id}</Link>)
  if (links.length === 0) return <span>-</span>
  return <span className="flex flex-wrap gap-x-2 gap-y-1">{links}</span>
}

function Pagination({ pagination, prefix }: { pagination: AdminWorkflowActivityPayload["pagination"]; prefix: string }) {
  const { t } = useT("admin")
  if (pagination.total_pages <= 1) return null
  return (
    <nav aria-label={t("activity.aria_pagination")} className="flex items-center justify-between border-t border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
      <span>{t("activity.page_of", { page: pagination.page, total: pagination.total_pages })}</span>
      <div className="flex items-center gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("activity.previous")}</Link> : <span className={disabledPaginationClass()}>{t("activity.previous")}</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("activity.next")}</Link> : <span className={disabledPaginationClass()}>{t("activity.next")}</span>}
      </div>
    </nav>
  )
}

function stateLabel(event: WorkflowActivityEvent) {
  return [event.trigger_kind, event.workflow_state, event.step_kind, event.run_state, event.reason_key].filter(Boolean).join(" · ") || "-"
}

function linkClass() {
  return adminEventLinkClass()
}
