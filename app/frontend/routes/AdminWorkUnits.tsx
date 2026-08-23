import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { AdminEventFilterBar, AdminEventLogTable, type AdminEventLogTableColumn, AdminEventPageShell, AdminEventPanelMessage, adminEventLinkClass, disabledPaginationClass, paginationLinkClass, severityPillClass } from "../components/AdminEventLogPanel"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { fetchAdminWorkUnits, type AdminWorkUnitsPayload, type LinkedJob, type WorkIntentSummary, type WorkUnitSummary } from "../api/adminWorkUnits"
import { updateAdminSettings } from "../api/adminSettings"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const POLL_INTERVAL_MS = 30_000

export function AdminWorkUnits() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_work_units"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const queryClient = useQueryClient()
  const workUnits = useQuery({
    queryKey: ["admin", "work_units", location.search],
    queryFn: ({ signal }) => fetchAdminWorkUnits(location.search, signal),
    refetchInterval: POLL_INTERVAL_MS
  })
  const toggleDebug = useMutation({
    mutationFn: (enabled: boolean) => updateAdminSettings({ show_work_unit_debug: enabled }),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["admin", "work_units"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "settings"] })
      ])
    }
  })
  const debugVisible = workUnits.data?.settings.show_work_unit_debug ?? false

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <div className="flex flex-wrap gap-2">
          <button className="inline-flex shrink-0 items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500" disabled={workUnits.isFetching} onClick={() => void workUnits.refetch()} type="button">
            {workUnits.isFetching ? t("work_units.refreshing") : t("work_units.refresh")}
          </button>
          <button className={`inline-flex shrink-0 items-center justify-center rounded border px-3 py-2 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-60 ${debugVisible ? "border-green-300 bg-green-50 text-green-700 hover:bg-green-100 dark:border-green-800 dark:bg-green-950/40 dark:text-green-300" : "border-gray-300 bg-white text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"}`} disabled={toggleDebug.isPending || workUnits.isPending} onClick={() => toggleDebug.mutate(!debugVisible)} type="button">
            {debugVisible ? t("work_units.hide_user_debug") : t("work_units.show_user_debug")}
          </button>
        </div>
      }
      ariaLabel={t("work_units.aria")}
      eyebrow={t("section_label")}
      title={t("work_units.heading")}
    >
      <p className="max-w-3xl text-sm text-gray-600 dark:text-gray-300">{t("work_units.description")}</p>

      <AdminEventFilterBar clearLabel={t("work_units.clear_filters")} filter={workUnits.data?.filter} filterSchema={workUnits.data?.filter_schema} fields={[
        { name: "intent_state", label: t("work_units.filter_intent_state") },
        { name: "intent_kind", label: t("work_units.filter_intent_kind") },
        { name: "unit_state", label: t("work_units.filter_unit_state") },
        { name: "unit_kind", label: t("work_units.filter_unit_kind") },
        { name: "scope_type", label: t("work_units.filter_scope") },
        { name: "repository_id", label: t("work_units.filter_repository"), inputMode: "numeric" },
        { name: "job_id", label: t("work_units.filter_job"), inputMode: "numeric" },
        { name: "workflow_id", label: t("work_units.filter_workflow"), inputMode: "numeric" }
      ]} search={location.search} searchLabel={t("work_units.apply_filters")} />

      <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        {workUnits.isPending ? <AdminEventPanelMessage>{t("work_units.loading")}</AdminEventPanelMessage> : null}
        {workUnits.isError ? <AdminEventPanelMessage tone="error">{t("work_units.error_load")}</AdminEventPanelMessage> : null}
        {workUnits.isSuccess ? <WorkUnitsTable payload={workUnits.data} prefix={prefix} search={location.search} onNavigate={navigateSearch} /> : null}
      </section>
    </AdminEventPageShell>
  )
}

function WorkUnitsTable({ onNavigate, payload, prefix, search }: { onNavigate: (params: URLSearchParams) => void; payload: AdminWorkUnitsPayload; prefix: string; search: string }) {
  const { t } = useT("admin")
  if (payload.intents.length === 0) return <AdminEventPanelMessage>{t("work_units.no_intents")}</AdminEventPanelMessage>

  const columns: Array<AdminEventLogTableColumn<WorkIntentSummary>> = [
    {
      className: "whitespace-nowrap px-4 py-3 text-xs text-gray-500 dark:text-gray-400",
      headerClassName: "px-4 py-2",
      header: t("work_units.col_requested"),
      key: "requested",
      sort: "requested",
      render: (intent) => intent.requested_at ? <RelativeTimestamp value={intent.requested_at} /> : "-"
    },
    {
      className: "px-4 py-3",
      headerClassName: "px-4 py-2",
      header: t("work_units.col_intent"),
      key: "kind",
      sort: "kind",
      render: (intent) => <IntentSummary intent={intent} />
    },
    {
      className: "px-4 py-3 text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("work_units.col_scope"),
      key: "scope",
      sort: "scope",
      render: (intent) => <ScopeSummary intent={intent} prefix={prefix} />
    },
    {
      className: "px-4 py-3 text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("work_units.col_jobs"),
      key: "jobs",
      render: (intent) => <JobLinks jobs={intent.jobs} prefix={prefix} />
    },
    {
      className: "px-4 py-3 text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("work_units.col_units"),
      key: "units",
      render: (intent) => <UnitList units={intent.units} prefix={prefix} />
    }
  ]

  return (
    <div>
      <div className="border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
        {t("work_units.showing", { first: payload.pagination.first_item, last: payload.pagination.last_item, total: payload.pagination.total })}
      </div>
      <AdminEventLogTable columns={columns} getRowKey={(intent) => intent.id} rows={payload.intents} search={search} tableClassName="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700" onNavigate={onNavigate} />
      <Pagination pagination={payload.pagination} prefix={prefix} />
    </div>
  )
}

function IntentSummary({ intent }: { intent: WorkIntentSummary }) {
  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold text-gray-900 dark:text-gray-100">{intent.label}</span>
        <Pill state={intent.state} />
        <span className="font-mono text-xs text-gray-500 dark:text-gray-400">WI-{intent.id}</span>
        {intent.priority ? <span className="rounded bg-gray-100 px-1.5 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{intent.priority}</span> : null}
      </div>
      {intent.wait_reason ? <div className="font-mono text-xs text-amber-700 dark:text-amber-300">{intent.wait_reason}{intent.wait_until ? ` until ${intent.wait_until}` : ""}</div> : null}
      {(intent.source_ref || intent.target_ref) ? <div className="font-mono text-xs text-gray-500 dark:text-gray-400">{[intent.source_ref, intent.target_ref].filter(Boolean).join(" -> ")}</div> : null}
    </div>
  )
}

function ScopeSummary({ intent, prefix }: { intent: WorkIntentSummary; prefix: string }) {
  return (
    <div className="space-y-1">
      <div className="font-mono">{intent.scope_type}:{intent.scope_id ?? "-"}</div>
      {intent.repository ? <Link className={linkClass()} to={withRoutePrefix(intent.repository.path, prefix)}>{intent.repository.slug}</Link> : null}
      {intent.actor ? <div>{intent.actor.display_name}</div> : null}
    </div>
  )
}

function UnitList({ units, prefix }: { units: WorkUnitSummary[]; prefix: string }) {
  if (units.length === 0) return <span>-</span>
  return (
    <div className="space-y-2">
      {units.map((unit) => (
        <div className="rounded border border-gray-200 bg-gray-50 p-2 dark:border-gray-700 dark:bg-gray-950" key={unit.id}>
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-gray-900 dark:text-gray-100">{unit.label}</span>
            <Pill state={unit.state} />
            <span className="font-mono text-xs text-gray-500 dark:text-gray-400">WU-{unit.id}</span>
            {unit.workflow ? <Link className={linkClass()} to={withRoutePrefix(unit.workflow.path, prefix)}>{unit.workflow.slug}</Link> : null}
          </div>
          {(unit.blocked_reason || unit.preemption_reason || unit.pause_requested) ? (
            <div className="mt-1 font-mono text-xs text-amber-700 dark:text-amber-300">
              {[unit.blocked_reason && `blocked: ${unit.blocked_reason}`, unit.preemption_reason && `preempted: ${unit.preemption_reason}`, unit.pause_requested && "pause requested"].filter(Boolean).join(" · ")}
            </div>
          ) : null}
          {unit.members.length > 0 ? <div className="mt-1"><JobLinks jobs={unit.members.map((member) => member.job).filter((job): job is LinkedJob => Boolean(job))} prefix={prefix} /></div> : null}
        </div>
      ))}
    </div>
  )
}

function JobLinks({ jobs, prefix }: { jobs: LinkedJob[]; prefix: string }) {
  if (jobs.length === 0) return <span>-</span>
  return (
    <span className="flex flex-wrap gap-x-2 gap-y-1">
      {jobs.map((job) => <Link className={linkClass()} key={job.id} title={job.title || undefined} to={withRoutePrefix(job.path, prefix)}>{job.slug}</Link>)}
    </span>
  )
}

function Pill({ state }: { state: string }) {
  return <span className={`rounded px-1.5 py-0.5 font-mono text-xs ${severityPillClass(state === "failed" || state === "blocked" ? "error" : state === "waiting" || state === "queued" ? "warn" : "info")}`}>{state}</span>
}

function Pagination({ pagination, prefix }: { pagination: AdminWorkUnitsPayload["pagination"]; prefix: string }) {
  const { t } = useT("admin")
  if (pagination.total_pages <= 1) return null
  return (
    <nav aria-label={t("work_units.aria_pagination")} className="flex items-center justify-between border-t border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
      <span>{t("work_units.page_of", { page: pagination.page, total: pagination.total_pages })}</span>
      <div className="flex items-center gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("work_units.previous")}</Link> : <span className={disabledPaginationClass()}>{t("work_units.previous")}</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("work_units.next")}</Link> : <span className={disabledPaginationClass()}>{t("work_units.next")}</span>}
      </div>
    </nav>
  )
}

function linkClass(): string {
  return adminEventLinkClass()
}
