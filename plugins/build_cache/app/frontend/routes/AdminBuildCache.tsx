import { useState, type FormEvent, type ReactNode } from "react"
import { useLocation } from "react-router-dom"
import { Button, DataTable, Notice, Page, Section, SectionHeading, Text } from "@app/components/ui"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { ApiError } from "@app/api/client"
import {
  cancelBuildCacheClearRequest,
  confirmBuildCacheClearRequest,
  createBuildCacheClearRequest,
  fetchAdminBuildCache,
  fetchAdminBuildCacheStats,
  type AdminBuildCachePayload,
  type AdminBuildCacheStatsPayload,
  type BuildCacheClearRequest,
  type BuildCacheClearRequestScope
} from "../api/adminBuildCache"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useConfirm } from "@app/hooks/useConfirm"
import { formatBytes } from "@app/lib/format"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { Form } from "@app/components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "@app/components/dataTable"
import type { DataTableSortDirection } from "@app/components/ui/DataTable"
import { AdminDataTablePanel } from "@app/components/AdminEventLogPanel"
import { AdminEventFilterBar, type AdminEventFilterField } from "@app/components/AdminEventLogPanel"
import { buildFlatFilterLink } from "@app/lib/flatFilterLink"

const QUERY_KEY = ["admin", "build_cache"]
const STATS_QUERY_KEY = ["admin", "build_cache", "stats"]
const FILTER_FIELDS = ["state", "scope", "older_than_days", "reason", "user_id", "confirmed_since", "cancelled_since", "created_since", "updated_since", "result_status"] as const

export function AdminBuildCache() {
  const { t } = useT("build_cache")
  const location = useLocation()
  usePageTitle(t("page_title_build_cache"))
  const query = useQuery({ queryKey: [...QUERY_KEY, location.search], queryFn: () => fetchAdminBuildCache(location.search) })

  return (
    <Page.Root aria-label={t("build_cache.aria_main")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Page.HeadingGroup>
          <Text as="p" muted variant="label">
            {t("admin:section_label")}
          </Text>
          <Page.Title className="mt-1">{t("build_cache.heading")}</Page.Title>
        </Page.HeadingGroup>
        <Page.Description>{t("build_cache.description")}</Page.Description>
      </Page.Header>

      {query.isPending ? <Notice>{t("build_cache.loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{query.error instanceof ApiError ? query.error.message : t("build_cache.error_load")}</Notice> : null}
      {query.isSuccess ? <BuildCacheContent payload={query.data} search={location.search} /> : null}
    </Page.Root>
  )
}

function BuildCacheContent({ payload, search }: { payload: AdminBuildCachePayload; search: string }) {
  const { t } = useT("build_cache")

  if (!payload.configured) {
    return <Notice tone="warning">{t("build_cache.not_configured")}</Notice>
  }

  return (
    <>
      <StatsCard configured={payload.configured} initial={payload} />
      {payload.pending_request ? <PendingRequestCard request={payload.pending_request} /> : <ClearRequestForm />}
      <AdminEventFilterBar
        buildLink={buildFlatFilterLink(FILTER_FIELDS)}
        clearLabel={t("build_cache.clear_filters")}
        fields={buildCacheFilterFields(t)}
        filter={payload.filter}
        filterSchema={payload.filter_schema}
        search={search}
        searchLabel={t("build_cache.search")}
      />
      <RecentRequestsCard requests={payload.recent_requests} />
    </>
  )
}

function buildCacheFilterFields(t: (key: string) => string): AdminEventFilterField[] {
  return [
    { name: "state", label: t("build_cache.filter_state"), options: ["pending", "confirmed", "cancelled"].map((value) => ({ label: t(`build_cache.state_${value}`), value })) },
    { name: "scope", label: t("build_cache.filter_scope"), options: ["full", "partial"].map((value) => ({ label: t(`build_cache.scope_${value}`), value })) },
    { name: "older_than_days", label: t("build_cache.filter_older_than_days"), inputMode: "numeric" },
    { name: "reason", label: t("build_cache.filter_reason") },
    { name: "user_id", label: t("build_cache.filter_user"), inputMode: "numeric" },
    { name: "confirmed_since", label: t("build_cache.filter_confirmed_since"), placeholder: "1h" },
    { name: "cancelled_since", label: t("build_cache.filter_cancelled_since"), placeholder: "1h" },
    { name: "created_since", label: t("build_cache.filter_created_since"), placeholder: "1h" },
    { name: "updated_since", label: t("build_cache.filter_updated_since"), placeholder: "1h" },
    { name: "result_status", label: t("build_cache.filter_result"), options: ["present", "empty", "truncated"].map((value) => ({ label: t(`build_cache.result_${value}`), value })) }
  ]
}

function StatsCard({ configured, initial }: { configured: boolean; initial?: AdminBuildCacheStatsPayload }) {
  const { t } = useT("build_cache")
  const query = useQuery({
    enabled: configured,
    queryKey: STATS_QUERY_KEY,
    queryFn: fetchAdminBuildCacheStats,
    initialData: initial?.stats || initial?.stats_error ? initial : undefined
  })
  const payload = query.data
  const stats = payload?.stats

  return (
    <Section.Root data-testid="build-cache-stats">
      <Section.Header>
        <Section.Title>{t("build_cache.stats_heading")}</Section.Title>
        <Section.Actions>
          <Button disabled={query.isFetching} onClick={() => void query.refetch()} size="sm" variant="secondary">
            {query.isFetching ? t("build_cache.stats_refreshing") : t("build_cache.stats_refresh")}
          </Button>
        </Section.Actions>
      </Section.Header>

      {query.isPending ? (
        <Text className="mt-2" tone="muted">
          {t("build_cache.stats_loading")}
        </Text>
      ) : query.isError ? (
        <Text className="mt-2" tone="danger">
          {query.error instanceof ApiError ? query.error.message : t("build_cache.error_generic")}
        </Text>
      ) : payload?.stats_error ? (
        <Text className="mt-2" tone="danger">
          {payload.stats_error}
        </Text>
      ) : stats ? (
        <>
          <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-4">
            <Stat label={t("build_cache.stat_object_count")} value={stats.object_count.toLocaleString()} />
            <Stat label={t("build_cache.stat_total_size")} value={formatBytes(stats.total_size_bytes)} />
            <Stat
              label={t("build_cache.stat_oldest_object")}
              value={stats.oldest_object ? <RelativeTimestamp value={stats.oldest_object.last_modified} /> : "—"}
            />
            <Stat
              label={t("build_cache.stat_newest_object")}
              value={stats.newest_object ? <RelativeTimestamp value={stats.newest_object.last_modified} /> : "—"}
            />
          </dl>
          {stats.truncated ? (
            <Text className="mt-3" variant="caption" tone="warning">
              {t("build_cache.stats_truncated")}
            </Text>
          ) : null}
        </>
      ) : (
        <Text className="mt-2" tone="muted">
          {t("build_cache.stats_unavailable")}
        </Text>
      )}
    </Section.Root>
  )
}

function Stat({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div>
      <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="mt-0.5 font-medium text-gray-900 dark:text-gray-100">{value}</dd>
    </div>
  )
}

function ClearRequestForm() {
  const { t } = useT("build_cache")
  const queryClient = useQueryClient()
  const [scope, setScope] = useState<BuildCacheClearRequestScope>("full")
  const [olderThanDays, setOlderThanDays] = useState("30")
  const [reason, setReason] = useState("")

  const create = useMutation({
    mutationFn: () =>
      createBuildCacheClearRequest({
        scope,
        older_than_days: scope === "partial" ? Number(olderThanDays) : null,
        reason
      }),
    onSuccess: (updated) => {
      queryClient.setQueriesData({ queryKey: QUERY_KEY }, updated)
      setReason("")
    }
  })

  function submit(event: FormEvent) {
    event.preventDefault()
    if (!reason.trim()) return
    create.mutate()
  }

  return (
    <Section.Root>
      <form className="space-y-4" onSubmit={submit} data-testid="build-cache-clear-form">
        <SectionHeading>{t("build_cache.request_heading")}</SectionHeading>

        <fieldset className="space-y-2">
          <label className="flex items-center gap-2 text-sm text-text-primary">
            <input checked={scope === "full"} className="h-4 w-4 accent-brand" name="scope" onChange={() => setScope("full")} type="radio" value="full" />
            {t("build_cache.scope_full")}
          </label>
          <div className="flex items-center gap-2 text-sm text-text-primary">
            <label className="flex items-center gap-2">
              <input
                checked={scope === "partial"}
                className="h-4 w-4 accent-brand"
                name="scope"
                onChange={() => setScope("partial")}
                type="radio"
                value="partial"
              />
              {t("build_cache.scope_partial")}
            </label>
            <Form.Field controlId="build-cache-older-than-days">
              <Form.Label className="sr-only">{t("build_cache.scope_partial")}</Form.Label>
              <Form.Input
                className="w-20"
                disabled={scope !== "partial"}
                fullWidth={false}
                min={1}
                onChange={(event) => setOlderThanDays(event.target.value)}
                type="number"
                value={olderThanDays}
              />
            </Form.Field>
            {t("build_cache.scope_partial_suffix")}
          </div>
        </fieldset>

        <Form.Field controlId="build-cache-clear-reason">
          <Form.Label>{t("build_cache.reason_label")}</Form.Label>
          <Form.Textarea
            onChange={(event) => setReason(event.target.value)}
            placeholder={t("build_cache.reason_placeholder")}
            required
            rows={2}
            value={reason}
          />
        </Form.Field>

        {create.isError ? (
          <Text role="alert" tone="danger">
            {create.error instanceof ApiError ? create.error.message : t("build_cache.error_generic")}
          </Text>
        ) : null}

        <Button disabled={create.isPending || !reason.trim()} type="submit" variant="primary">
          {create.isPending ? t("build_cache.requesting") : t("build_cache.request_button")}
        </Button>
      </form>
    </Section.Root>
  )
}

function PendingRequestCard({ request }: { request: BuildCacheClearRequest }) {
  const { t } = useT("build_cache")
  const queryClient = useQueryClient()
  const { confirm, dialog } = useConfirm()

  const confirmMutation = useMutation({
    mutationFn: () => confirmBuildCacheClearRequest(request.id),
    onSuccess: (updated) => queryClient.setQueriesData({ queryKey: QUERY_KEY }, updated)
  })
  const cancelMutation = useMutation({
    mutationFn: () => cancelBuildCacheClearRequest(request.id),
    onSuccess: (updated) => queryClient.setQueriesData({ queryKey: QUERY_KEY }, updated)
  })

  async function onConfirmClick() {
    const message = request.scope === "full" ? t("build_cache.confirm_full") : t("build_cache.confirm_partial", { days: request.older_than_days })
    if (await confirm({ message, destructive: true, confirmLabel: t("build_cache.confirm_button") })) {
      confirmMutation.mutate()
    }
  }

  return (
    <Section.Root className="border-warning/30 bg-warning/10 text-warning" data-testid="build-cache-pending-request">
      {dialog}
      <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">{t("build_cache.pending_heading")}</h2>
      <dl className="mt-2 grid grid-cols-1 gap-y-1 text-sm text-amber-900 dark:text-amber-100 sm:grid-cols-[8rem_1fr]">
        <dt className="text-amber-700 dark:text-amber-300">{t("build_cache.pending_scope")}</dt>
        <dd>{request.scope === "full" ? t("build_cache.scope_full") : t("build_cache.pending_scope_partial_value", { days: request.older_than_days })}</dd>
        <dt className="text-amber-700 dark:text-amber-300">{t("build_cache.pending_reason")}</dt>
        <dd className="whitespace-pre-wrap">{request.reason}</dd>
        <dt className="text-amber-700 dark:text-amber-300">{t("build_cache.pending_requested_by")}</dt>
        <dd>
          {request.requested_by ?? "—"} · <RelativeTimestamp value={request.created_at} />
        </dd>
      </dl>

      {confirmMutation.isError ? (
        <Text className="mt-2" tone="danger">
          {confirmMutation.error instanceof ApiError ? confirmMutation.error.message : t("build_cache.error_generic")}
        </Text>
      ) : null}

      <div className="mt-3 flex gap-2">
        <Button disabled={confirmMutation.isPending} onClick={onConfirmClick} variant="danger">
          {confirmMutation.isPending ? t("build_cache.confirming") : t("build_cache.confirm_button")}
        </Button>
        <Button disabled={cancelMutation.isPending} onClick={() => cancelMutation.mutate()} variant="secondary">
          {t("build_cache.cancel_button")}
        </Button>
      </div>
    </Section.Root>
  )
}

function RecentRequestsCard({ requests }: { requests: BuildCacheClearRequest[] }) {
  const { t } = useT("build_cache")
  const [sort, setSort] = useState<{ column: string; direction: "asc" | "desc" }>({ column: "created_at", direction: "desc" })
  const columns = recentRequestColumns(t)
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: "syrus.admin.build_cache.recent_requests.visible_columns" })
  const sortedRequests = sortRequests(requests, sort)
  const sortDirection: DataTableSortDirection = sort.direction === "asc" ? "ascending" : "descending"
  if (requests.length === 0) return null

  function toggleSort(column: string) {
    setSort((current) => ({ column, direction: current.column === column && current.direction === "asc" ? "desc" : "asc" }))
  }

  return (
    <div data-testid="build-cache-recent-requests">
      <AdminDataTablePanel
        columnSelector={
          <DataTableColumnMenu
            columns={columns}
            downLabel={t("build_cache.column_down")}
            menuId="build-cache-recent-requests-columns"
            moveDownLabel={(title) => t("build_cache.column_move_down", { title })}
            moveUpLabel={(title) => t("build_cache.column_move_up", { title })}
            onChange={preferences.onChange}
            order={preferences.order}
            triggerAriaLabel={t("build_cache.columns")}
            upLabel={t("build_cache.column_up")}
            visibleLabel={t("build_cache.visible_columns")}
          />
        }
        config={{ summary: t("build_cache.recent_heading"), meta: t("build_cache.recent_count", { count: requests.length }) }}
      >
        <DataTable.Root wrapperClassName="rounded-none border-0">
          <DataTable.Header>
            <DataTableColumnHeaderRow
              columns={columns}
              onReorder={preferences.onChange}
              onSort={toggleSort}
              order={preferences.order}
              sortColumn={sort.column}
              sortDirection={sortDirection}
            />
          </DataTable.Header>
          <DataTable.Body>
            {sortedRequests.map((request) => (
              <DataTable.Row key={request.id}>
                <DataTableColumnCells columns={columns} order={preferences.order} row={request} />
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      </AdminDataTablePanel>
    </div>
  )
}

function sortRequests(requests: BuildCacheClearRequest[], sort: { column: string; direction: "asc" | "desc" }) {
  const direction = sort.direction === "asc" ? 1 : -1
  return [...requests].sort((a, b) => compareValues(requestSortValue(a, sort.column), requestSortValue(b, sort.column)) * direction)
}

function requestSortValue(request: BuildCacheClearRequest, column: string) {
  if (column === "scope") return request.scope
  if (column === "state") return request.state
  if (column === "reason") return request.reason
  if (column === "requested_by") return request.requested_by ?? ""
  if (column === "created_at") return request.created_at
  if (column === "older_than_days") return request.older_than_days ?? 0
  if (column === "confirmed_at") return request.confirmed_at ?? ""
  if (column === "cancelled_at") return request.cancelled_at ?? ""
  if (column === "updated_at") return request.updated_at
  if (column === "result_status") return request.result_status
  return request.id
}

function compareValues(a: string | number, b: string | number) {
  if (typeof a === "number" && typeof b === "number") return a - b
  return String(a).localeCompare(String(b))
}

function recentRequestColumns(t: (key: string, options?: Record<string, unknown>) => string): DataTableColumnDef<BuildCacheClearRequest>[] {
  return [
    {
      key: "scope",
      label: t("build_cache.col_scope"),
      required: true,
      cellClassName: "align-top font-medium",
      sortKey: "scope",
      renderCell: (request) => request.scope === "full" ? t("build_cache.scope_full") : t("build_cache.pending_scope_partial_value", { days: request.older_than_days })
    },
    {
      key: "state",
      label: t("build_cache.col_state"),
      cellClassName: "align-top",
      sortKey: "state",
      renderCell: (request) => <RequestStateBadge state={request.state} />
    },
    {
      key: "older_than_days",
      label: t("build_cache.col_older_than_days"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      defaultVisible: false,
      sortKey: "older_than_days",
      renderCell: (request) => request.older_than_days ?? "—"
    },
    {
      key: "reason",
      label: t("build_cache.col_reason"),
      cellClassName: "max-w-xl align-top text-gray-600 dark:text-gray-300",
      sortKey: "reason",
      renderCell: (request) => <span className="line-clamp-3 whitespace-pre-wrap">{request.reason}</span>
    },
    {
      key: "result",
      label: t("build_cache.col_result"),
      cellClassName: "align-top text-gray-600 dark:text-gray-300",
      renderCell: (request) => request.result ? t("build_cache.result_summary", { count: request.result.deleted_count, size: formatBytes(request.result.bytes_freed) }) : "—"
    },
    {
      key: "result_status",
      label: t("build_cache.col_result_status"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      defaultVisible: false,
      sortKey: "result_status",
      renderCell: (request) => t(`build_cache.result_${request.result_status}`)
    },
    {
      key: "requested_by",
      label: t("build_cache.col_requested_by"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      sortKey: "requested_by",
      renderCell: (request) => request.requested_by ?? "—"
    },
    {
      key: "created_at",
      label: t("build_cache.col_requested"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      sortKey: "created_at",
      renderCell: (request) => <RelativeTimestamp value={request.created_at} />
    },
    {
      key: "confirmed_at",
      label: t("build_cache.col_confirmed"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      defaultVisible: false,
      sortKey: "confirmed_at",
      renderCell: (request) => request.confirmed_at ? <RelativeTimestamp value={request.confirmed_at} /> : "—"
    },
    {
      key: "cancelled_at",
      label: t("build_cache.col_cancelled"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      defaultVisible: false,
      sortKey: "cancelled_at",
      renderCell: (request) => request.cancelled_at ? <RelativeTimestamp value={request.cancelled_at} /> : "—"
    },
    {
      key: "updated_at",
      label: t("build_cache.col_updated"),
      cellClassName: "whitespace-nowrap align-top text-gray-600 dark:text-gray-300",
      defaultVisible: false,
      sortKey: "updated_at",
      renderCell: (request) => <RelativeTimestamp value={request.updated_at} />
    }
  ]
}

function RequestStateBadge({ state }: { state: BuildCacheClearRequest["state"] }) {
  const { t } = useT("build_cache")
  const classes =
    state === "confirmed"
      ? "bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-300 dark:border-emerald-900"
      : "bg-gray-100 text-gray-700 border-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:border-gray-700"

  return <span className={`rounded border px-2 py-0.5 text-xs font-medium ${classes}`}>{t(`build_cache.state_${state}`)}</span>
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default AdminBuildCache
