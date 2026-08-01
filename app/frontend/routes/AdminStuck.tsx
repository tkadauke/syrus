import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useSearchParams } from "react-router-dom"
import { forceFailStuckJob, fetchAdminStuck, type StuckItem } from "../api/adminStuck"
import { workflowSlug } from "../lib/slugs"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

const POLL_INTERVAL_MS = 30_000

export function AdminStuck() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_stuck"))
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const page = parsePage(searchParams.get("page"))
  const prefix = routePrefix(location.pathname)
  const stuck = useQuery({
    queryKey: ["admin", "stuck", page],
    queryFn: ({ signal }) => fetchAdminStuck(page, signal),
    refetchInterval: POLL_INTERVAL_MS
  })

  return (
    <main aria-label={t("aria_stuck")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex items-end justify-between gap-4 border-b border-gray-200 dark:border-gray-700 pb-4">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("stuck.heading")}</h1>
        </div>
        <button
          className="inline-flex shrink-0 items-center justify-center rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:cursor-not-allowed disabled:text-gray-400 dark:disabled:text-gray-500"
          disabled={stuck.isFetching}
          onClick={() => void stuck.refetch()}
          type="button"
        >
          {stuck.isFetching ? t("stuck.refreshing") : t("stuck.refresh")}
        </button>
      </header>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {stuck.isPending ? <PanelMessage>{t("stuck.loading")}</PanelMessage> : null}
        {stuck.isError ? <PanelMessage tone="error">{t("stuck.error_load")}</PanelMessage> : null}
        {stuck.isSuccess ? <StuckTable items={stuck.data.items} pagination={stuck.data.pagination} prefix={prefix} /> : null}
      </section>
    </main>
  )
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
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{t("stuck.col_severity")}</th>
              <th className="px-4 py-2">{t("stuck.col_status")}</th>
              <th className="px-4 py-2">{t("stuck.col_kind")}</th>
              <th className="px-4 py-2">{t("stuck.col_detail")}</th>
              <th className="px-4 py-2">{t("stuck.col_context")}</th>
              <th className="px-4 py-2">{t("stuck.col_age")}</th>
              <th className="px-4 py-2 text-right">{t("stuck.col_links")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {items.map((item) => (
              <tr key={`${item.kind}-${item.run_id || "none"}-${item.workflow_id || "none"}`}>
                <td className="px-4 py-2">
                  <span className={`rounded px-1.5 py-0.5 font-mono text-xs uppercase ${severityClass(item.severity)}`}>
                    {item.severity}
                  </span>
                </td>
                <td className="px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{statusLabel(item.attention_state, t)}</td>
                <td className="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-200">{item.kind}</td>
                <td className="px-4 py-2 text-gray-700 dark:text-gray-200">{item.detail}</td>
                <td className="px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{contextLabel(item)}</td>
                <td className="px-4 py-2 text-xs text-gray-500 dark:text-gray-400">{item.age_label}</td>
                <td className="space-x-3 px-4 py-2 text-right text-xs">
                  {item.workflow_path ? (
                    <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix(item.workflow_path, prefix)}>{item.workflow_slug || "Workflow"}</Link>
                  ) : null}
                  {item.job_id ? <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix(item.job_path || `/jobs/${item.job_id}`, prefix)}>Job</Link> : null}
                  {item.run_id && item.has_transcript ? (
                    <Link className="text-indigo-600 dark:text-indigo-300 underline hover:no-underline" to={withRoutePrefix(`/admin/runs/${item.run_id}/transcript`, prefix)}>Transcript</Link>
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
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
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
