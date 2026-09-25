import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button } from "../components/Button"
import { useRef } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { forceFailStuckJob, fetchAdminStuck, type StuckItem } from "../api/adminStuck"
import { workflowSlug } from "../lib/slugs"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"
import {
  AdminEventFilterBar,
  AdminEventLogTable,
  type AdminEventLogTableColumn,
  AdminEventPageShell,
  AdminEventPanelMessage,
  adminEventLinkClass
} from "../components/AdminEventLogPanel"

const POLL_INTERVAL_MS = 30_000

export function AdminStuck() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_stuck"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const refreshNext = useRef(false)
  const stuck = useQuery({
    queryKey: ["admin", "stuck", location.search],
    queryFn: async ({ signal }) => {
      const refresh = refreshNext.current
      refreshNext.current = false
      return fetchAdminStuck(location.search, signal, refresh)
    },
    refetchInterval: POLL_INTERVAL_MS
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <Button
          className="shrink-0 disabled:text-gray-400 dark:disabled:text-gray-500"
          disabled={stuck.isFetching}
          onClick={() => {
            refreshNext.current = true
            void stuck.refetch()
          }}
          variant="secondary"
        >
          {stuck.isFetching ? t("stuck.refreshing") : t("stuck.refresh")}
        </Button>
      }
      ariaLabel={t("aria_stuck")}
      description={t("stuck.description")}
      eyebrow={t("section_label")}
      title={t("stuck.heading")}
    >
      <AdminEventFilterBar clearLabel={t("stuck.clear_filters")} filter={stuck.data?.filter} filterSchema={stuck.data?.filter_schema} fields={[
        { name: "severity", label: t("stuck.filter_severity") },
        { name: "status", label: t("stuck.filter_status") },
        { name: "kind", label: t("stuck.filter_kind") },
        { name: "job_id", label: t("stuck.filter_job"), inputMode: "numeric" },
        { name: "workflow_id", label: t("stuck.filter_workflow"), inputMode: "numeric" },
        { name: "run_id", label: t("stuck.filter_run"), inputMode: "numeric" }
      ]} search={location.search} searchLabel={t("stuck.apply_filters")} />

      {stuck.isPending ? <AdminEventPanelMessage>{t("stuck.loading")}</AdminEventPanelMessage> : null}
      {stuck.isError ? <AdminEventPanelMessage tone="error">{t("stuck.error_load")}</AdminEventPanelMessage> : null}
      {stuck.isSuccess ? <StuckTable items={stuck.data.items} pagination={stuck.data.pagination} prefix={prefix} search={location.search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function buildStuckColumns({
  forceFail,
  prefix,
  t
}: {
  forceFail: { isPending: boolean; mutate: (path: string) => void }
  prefix: string
  t: (key: string) => string
}): Array<AdminEventLogTableColumn<StuckItem>> {
  return [
    {
      key: "severity",
      header: t("stuck.col_severity"),
      required: true,
      sort: "severity",
      render: (item) => <span className={`rounded px-1.5 py-0.5 font-mono text-xs uppercase ${severityClass(item.severity)}`}>{item.severity}</span>
    },
    {
      key: "status",
      header: t("stuck.col_status"),
      className: "text-xs text-gray-600 dark:text-gray-300",
      sort: "status",
      render: (item) => statusLabel(item.attention_state, t)
    },
    { key: "kind", header: t("stuck.col_kind"), sort: "kind", className: "font-mono text-xs text-gray-700 dark:text-gray-200", render: (item) => item.kind },
    { key: "detail", header: t("stuck.col_detail"), sort: "detail", className: "text-gray-700 dark:text-gray-200", render: (item) => item.detail },
    { key: "context", header: t("stuck.col_context"), sort: "context", className: "text-xs text-gray-600 dark:text-gray-300", render: (item) => contextLabel(item) },
    { key: "age", header: t("stuck.col_age"), sort: "age", className: "text-xs text-gray-500 dark:text-gray-400", render: (item) => item.age_label },
    {
      key: "links",
      header: t("stuck.col_links"),
      required: true,
      pin: "end",
      className: "text-xs",
      render: (item) => (
        <span className="flex flex-wrap justify-end gap-x-3 gap-y-1">
          {item.workflow_path ? (
            <Link className={adminEventLinkClass()} to={withRoutePrefix(item.workflow_path, prefix)}>
              {item.workflow_slug || t("stuck.link_workflow")}
            </Link>
          ) : null}
          {item.job_id ? (
            <Link
              className={adminEventLinkClass()}
              to={withRoutePrefix(item.job_path || `/jobs/${item.job_id}`, prefix)}
            >
              {t("stuck.link_job")}
            </Link>
          ) : null}
          {item.run_id && item.has_transcript ? (
            <Link
              className={adminEventLinkClass()}
              to={withRoutePrefix(`/admin/runs/${item.run_id}/transcript`, prefix)}
            >
              {t("stuck.link_transcript")}
            </Link>
          ) : null}
          {item.force_fail_path ? (
            <button
              className="font-medium text-red-600 underline hover:no-underline disabled:cursor-not-allowed disabled:text-gray-400 dark:text-red-300 dark:disabled:text-gray-500"
              disabled={forceFail.isPending}
              onClick={() => forceFail.mutate(item.force_fail_path as string)}
              type="button"
            >
              {forceFail.isPending ? t("stuck.force_failing") : t("stuck.force_fail")}
            </button>
          ) : null}
        </span>
      )
    }
  ]
}

function StuckTable({
  items,
  onNavigate,
  pagination,
  prefix,
  search
}: {
  items: StuckItem[]
  onNavigate: (params: URLSearchParams) => void
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
    first_item: number
    last_item: number
    previous_path: string | null
    next_path: string | null
  }
  prefix: string
  search: string
}) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const forceFail = useMutation({
    mutationFn: forceFailStuckJob,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["admin", "stuck"] })
      void queryClient.invalidateQueries({ queryKey: ["admin", "overview"] })
      void queryClient.invalidateQueries({ queryKey: ["jobs"], exact: true })
    }
  })
  const columns = buildStuckColumns({ forceFail, prefix, t })

  if (items.length === 0) {
    return <AdminEventPanelMessage>{t("stuck.nothing_stuck")}</AdminEventPanelMessage>
  }

  return (
    <>
      {forceFail.isError ? <AdminEventPanelMessage tone="error">{errorMessage(forceFail.error, t("stuck.force_fail_error"))}</AdminEventPanelMessage> : null}
      <AdminEventLogTable
        columns={columns}
        defaultSort={{ column: "severity", direction: "desc" }}
        getRowKey={(item) => `${item.kind}-${item.run_id || "none"}-${item.workflow_id || "none"}-${item.job_id || "none"}`}
        rows={items}
        search={search}
        storageKey="syrus.admin.stuck.visible_columns"
        tableClassName="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700"
        onNavigate={onNavigate}
        panel={{
          summary: t("stuck.showing", { first: pagination.first_item, last: pagination.last_item, total: pagination.total }),
          pagination: {
            ariaLabel: t("stuck.aria_pagination"),
            label: t("stuck.page_of", { page: pagination.page, total: pagination.total_pages }),
            nextLabel: t("stuck.next"),
            onNavigate,
            pagination: {
              page: pagination.page,
              has_next_page: Boolean(pagination.next_path),
              has_previous_page: Boolean(pagination.previous_path),
              next_page: pagination.page + 1,
              previous_page: pagination.page - 1,
              total_pages: pagination.total_pages
            },
            previousLabel: t("stuck.previous"),
            search
          }
        }}
      />
    </>
  )
}

function severityClass(severity: string) {
  return severity === "alarm"
    ? "bg-red-100 dark:bg-red-950/60 text-red-700 dark:text-red-300"
    : "bg-amber-100 dark:bg-amber-950/60 text-amber-700 dark:text-amber-300"
}

function statusLabel(status: string | undefined, t: (key: string) => string) {
  if (status === "auto_repairable") return t("stuck.status_auto_repairable")
  if (status === "operator_action_required") return t("stuck.status_operator_action_required")
  if (status === "repaired") return t("stuck.status_repaired")
  if (status === "waiting") return t("stuck.status_waiting")
  return status || "-"
}

function contextLabel(item: StuckItem) {
  const parts = []
  if (item.run_id) parts.push(`Run #${item.run_id}`)
  if (item.workflow_trigger_kind) parts.push(item.workflow_trigger_kind)
  if (item.step_kind) parts.push(`step ${item.step_kind}`)
  if (parts.length === 0 && item.workflow_id) parts.push(item.workflow_slug || workflowSlug(item.workflow_id))

  return parts.join(" · ") || "-"
}
