import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button } from "../components/Button"
import { PageHeading } from "../components/Heading"
import { useRef, type ReactNode } from "react"
import { Link, useLocation, useSearchParams } from "react-router-dom"
import { forceFailStuckJob, fetchAdminStuck, type StuckItem } from "../api/adminStuck"
import { workflowSlug } from "../lib/slugs"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"
import { DataTable, Page } from "../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "../components/dataTable"

const POLL_INTERVAL_MS = 30_000

export function AdminStuck() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_stuck"))
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const page = parsePage(searchParams.get("page"))
  const prefix = routePrefix(location.pathname)
  const refreshNext = useRef(false)
  const stuck = useQuery({
    queryKey: ["admin", "stuck", page],
    queryFn: async ({ signal }) => {
      const refresh = refreshNext.current
      refreshNext.current = false
      return fetchAdminStuck(page, signal, refresh)
    },
    refetchInterval: POLL_INTERVAL_MS
  })

  return (
    <Page.Root aria-label={t("aria_stuck")} gutter="responsive" size="wide">
      <Page.Header className="items-end border-b border-gray-200 dark:border-gray-700 pb-4">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <PageHeading className="mt-1">{t("stuck.heading")}</PageHeading>
        </div>
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
      </Page.Header>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {stuck.isPending ? <PanelMessage>{t("stuck.loading")}</PanelMessage> : null}
        {stuck.isError ? <PanelMessage tone="error">{t("stuck.error_load")}</PanelMessage> : null}
        {stuck.isSuccess ? <StuckTable items={stuck.data.items} pagination={stuck.data.pagination} prefix={prefix} /> : null}
      </section>
    </Page.Root>
  )
}

const STUCK_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.admin.stuck.visible_columns"

function buildStuckColumns({ forceFail, prefix, t }: { forceFail: { isPending: boolean; mutate: (path: string) => void }; prefix: string; t: (key: string) => string }): DataTableColumnDef<StuckItem>[] {
  return [
    {
      key: "severity",
      label: t("stuck.col_severity"),
      required: true,
      renderCell: (item) => <span className={`rounded px-1.5 py-0.5 font-mono text-xs uppercase ${severityClass(item.severity)}`}>{item.severity}</span>
    },
    { key: "status", label: t("stuck.col_status"), cellClassName: "text-xs text-gray-600 dark:text-gray-300", renderCell: (item) => statusLabel(item.attention_state, t) },
    { key: "kind", label: t("stuck.col_kind"), cellClassName: "font-mono text-xs text-gray-700 dark:text-gray-200", renderCell: (item) => item.kind },
    { key: "detail", label: t("stuck.col_detail"), cellClassName: "text-gray-700 dark:text-gray-200", renderCell: (item) => item.detail },
    { key: "context", label: t("stuck.col_context"), cellClassName: "text-xs text-gray-600 dark:text-gray-300", renderCell: (item) => contextLabel(item) },
    { key: "age", label: t("stuck.col_age"), cellClassName: "text-xs text-gray-500 dark:text-gray-400", renderCell: (item) => item.age_label },
    {
      key: "links",
      label: t("stuck.col_links"),
      required: true,
      pin: "end",
      align: "right",
      cellClassName: "space-x-3 text-xs",
      renderCell: (item) => (
        <>
          {item.workflow_path ? (
            <Link className="text-brand dark:text-brand-emphasis underline hover:no-underline" to={withRoutePrefix(item.workflow_path, prefix)}>{item.workflow_slug || t("stuck.link_workflow")}</Link>
          ) : null}
          {item.job_id ? <Link className="text-brand dark:text-brand-emphasis underline hover:no-underline" to={withRoutePrefix(item.job_path || `/jobs/${item.job_id}`, prefix)}>{t("stuck.link_job")}</Link> : null}
          {item.run_id && item.has_transcript ? (
            <Link className="text-indigo-600 dark:text-indigo-300 underline hover:no-underline" to={withRoutePrefix(`/admin/runs/${item.run_id}/transcript`, prefix)}>{t("stuck.link_transcript")}</Link>
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
        </>
      )
    }
  ]
}

function StuckTable({ items, pagination, prefix }: { items: StuckItem[]; pagination: { page: number; per_page: number; total: number; total_pages: number; first_item: number; last_item: number; previous_path: string | null; next_path: string | null }; prefix: string }) {
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
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: STUCK_VISIBLE_COLUMNS_STORAGE_KEY })

  if (items.length === 0) {
    return (
      <div className="bg-emerald-50 dark:bg-emerald-950/40 p-6 text-sm text-emerald-800 dark:text-emerald-200">
        {t("stuck.nothing_stuck")}
      </div>
    )
  }

  return (
    <div>
      {forceFail.isError ? <PanelMessage tone="error">{errorMessage(forceFail.error, t("stuck.force_fail_error"))}</PanelMessage> : null}
      <div className="flex justify-end border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <DataTableColumnMenu
          columns={columns}
          downLabel={t("event_log_table.column_down")}
          menuId="admin-stuck-columns-menu"
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
          {items.map((item) => (
            <DataTable.Row key={`${item.kind}-${item.run_id || "none"}-${item.workflow_id || "none"}`}>
              <DataTableColumnCells columns={columns} order={preferences.order} row={item} />
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
      <StuckPagination pagination={pagination} prefix={prefix} />
    </div>
  )
}

function StuckPagination({ pagination, prefix }: { pagination: { page: number; total_pages: number; total: number; first_item: number; last_item: number; previous_path: string | null; next_path: string | null }; prefix: string }) {
  const { t } = useT("admin")
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label={t("stuck.aria_pagination")} className="flex items-center justify-between border-t border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
      <span>{t("stuck.showing", { first: pagination.first_item, last: pagination.last_item, total: pagination.total })}</span>
      <div className="flex items-center gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("stuck.previous")}</Link> : <span className={disabledPaginationClass()}>{t("stuck.previous")}</span>}
        <span className="px-2 text-xs text-gray-500 dark:text-gray-400">{t("stuck.page_of", { page: pagination.page, total: pagination.total_pages })}</span>
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("stuck.next")}</Link> : <span className={disabledPaginationClass()}>{t("stuck.next")}</span>}
      </div>
    </nav>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function severityClass(severity: string) {
  return severity === "alarm" ? "bg-red-100 dark:bg-red-950/60 text-red-700 dark:text-red-300" : "bg-amber-100 dark:bg-amber-950/60 text-amber-700 dark:text-amber-300"
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

function parsePage(value: string | null) {
  const parsed = Number.parseInt(value || "1", 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1
}

function paginationLinkClass() {
  return "rounded border border-gray-300 dark:border-gray-700 px-3 py-1 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 dark:border-gray-800 px-3 py-1 text-gray-400 dark:text-gray-600"
}
