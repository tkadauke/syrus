import { useState, type FormEvent, type ReactNode } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { ApiError } from "../api/client"
import {
  cancelBuildCacheClearRequest,
  confirmBuildCacheClearRequest,
  createBuildCacheClearRequest,
  fetchAdminBuildCache,
  type AdminBuildCachePayload,
  type BuildCacheClearRequest,
  type BuildCacheClearRequestScope
} from "../api/adminBuildCache"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useConfirm } from "../hooks/useConfirm"
import { formatBytes } from "../lib/format"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { Button } from "../components/Button"

const QUERY_KEY = ["admin", "build_cache"]

export function AdminBuildCache() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_build_cache"))
  const query = useQuery({ queryKey: QUERY_KEY, queryFn: fetchAdminBuildCache })

  return (
    <main aria-label={t("build_cache.aria_main")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("build_cache.heading")}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">{t("build_cache.description")}</p>
      </header>

      {query.isPending ? <PanelMessage>{t("build_cache.loading")}</PanelMessage> : null}
      {query.isError ? <PanelMessage tone="error">{query.error instanceof ApiError ? query.error.message : t("build_cache.error_load")}</PanelMessage> : null}
      {query.isSuccess ? <BuildCacheContent payload={query.data} /> : null}
    </main>
  )
}

function BuildCacheContent({ payload }: { payload: AdminBuildCachePayload }) {
  const { t } = useT("admin")

  if (!payload.configured) {
    return (
      <section className="rounded border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/30 p-4 text-sm text-amber-900 dark:text-amber-200">
        {t("build_cache.not_configured")}
      </section>
    )
  }

  return (
    <>
      <StatsCard payload={payload} />
      {payload.pending_request ? (
        <PendingRequestCard request={payload.pending_request} />
      ) : (
        <ClearRequestForm />
      )}
      <RecentRequestsCard requests={payload.recent_requests} />
    </>
  )
}

function StatsCard({ payload }: { payload: AdminBuildCachePayload }) {
  const { t } = useT("admin")
  const stats = payload.stats

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4" data-testid="build-cache-stats">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("build_cache.stats_heading")}</h2>

      {payload.stats_error ? (
        <p className="mt-2 text-sm text-red-600 dark:text-red-300">{payload.stats_error}</p>
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
            <p className="mt-3 text-xs text-amber-700 dark:text-amber-300">{t("build_cache.stats_truncated")}</p>
          ) : null}
        </>
      ) : (
        <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">{t("build_cache.stats_unavailable")}</p>
      )}
    </section>
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
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [scope, setScope] = useState<BuildCacheClearRequestScope>("full")
  const [olderThanDays, setOlderThanDays] = useState("30")
  const [reason, setReason] = useState("")

  const create = useMutation({
    mutationFn: () => createBuildCacheClearRequest({
      scope,
      older_than_days: scope === "partial" ? Number(olderThanDays) : null,
      reason
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(QUERY_KEY, updated)
      setReason("")
    }
  })

  function submit(event: FormEvent) {
    event.preventDefault()
    if (!reason.trim()) return
    create.mutate()
  }

  return (
    <form className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4" onSubmit={submit} data-testid="build-cache-clear-form">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("build_cache.request_heading")}</h2>

      <fieldset className="space-y-2">
        <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-200">
          <input checked={scope === "full"} name="scope" onChange={() => setScope("full")} type="radio" value="full" />
          {t("build_cache.scope_full")}
        </label>
        <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-200">
          <input checked={scope === "partial"} name="scope" onChange={() => setScope("partial")} type="radio" value="partial" />
          {t("build_cache.scope_partial")}
          <input
            className="w-20 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
            disabled={scope !== "partial"}
            min={1}
            onChange={(event) => setOlderThanDays(event.target.value)}
            type="number"
            value={olderThanDays}
          />
          {t("build_cache.scope_partial_suffix")}
        </label>
      </fieldset>

      <label className="block text-sm text-gray-700 dark:text-gray-200">
        {t("build_cache.reason_label")}
        <textarea
          className="mt-1 block w-full rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 px-2 py-1 text-sm"
          onChange={(event) => setReason(event.target.value)}
          placeholder={t("build_cache.reason_placeholder")}
          required
          rows={2}
          value={reason}
        />
      </label>

      {create.isError ? (
        <p className="text-sm text-red-600 dark:text-red-300">{create.error instanceof ApiError ? create.error.message : t("build_cache.error_generic")}</p>
      ) : null}

      <Button disabled={create.isPending || !reason.trim()} type="submit" variant="primary">
        {create.isPending ? t("build_cache.requesting") : t("build_cache.request_button")}
      </Button>
    </form>
  )
}

function PendingRequestCard({ request }: { request: BuildCacheClearRequest }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const { confirm, dialog } = useConfirm()

  const confirmMutation = useMutation({
    mutationFn: () => confirmBuildCacheClearRequest(request.id),
    onSuccess: (updated) => queryClient.setQueryData(QUERY_KEY, updated)
  })
  const cancelMutation = useMutation({
    mutationFn: () => cancelBuildCacheClearRequest(request.id),
    onSuccess: (updated) => queryClient.setQueryData(QUERY_KEY, updated)
  })

  async function onConfirmClick() {
    const message = request.scope === "full"
      ? t("build_cache.confirm_full")
      : t("build_cache.confirm_partial", { days: request.older_than_days })
    if (await confirm({ message, destructive: true, confirmLabel: t("build_cache.confirm_button") })) {
      confirmMutation.mutate()
    }
  }

  return (
    <section className="rounded border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/30 p-4" data-testid="build-cache-pending-request">
      {dialog}
      <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">{t("build_cache.pending_heading")}</h2>
      <dl className="mt-2 grid grid-cols-1 gap-y-1 text-sm text-amber-900 dark:text-amber-100 sm:grid-cols-[8rem_1fr]">
        <dt className="text-amber-700 dark:text-amber-300">{t("build_cache.pending_scope")}</dt>
        <dd>{request.scope === "full" ? t("build_cache.scope_full") : t("build_cache.pending_scope_partial_value", { days: request.older_than_days })}</dd>
        <dt className="text-amber-700 dark:text-amber-300">{t("build_cache.pending_reason")}</dt>
        <dd className="whitespace-pre-wrap">{request.reason}</dd>
        <dt className="text-amber-700 dark:text-amber-300">{t("build_cache.pending_requested_by")}</dt>
        <dd>{request.requested_by ?? "—"} · <RelativeTimestamp value={request.created_at} /></dd>
      </dl>

      {confirmMutation.isError ? (
        <p className="mt-2 text-sm text-red-700 dark:text-red-300">{confirmMutation.error instanceof ApiError ? confirmMutation.error.message : t("build_cache.error_generic")}</p>
      ) : null}

      <div className="mt-3 flex gap-2">
        <Button disabled={confirmMutation.isPending} onClick={onConfirmClick} variant="danger">
          {confirmMutation.isPending ? t("build_cache.confirming") : t("build_cache.confirm_button")}
        </Button>
        <Button disabled={cancelMutation.isPending} onClick={() => cancelMutation.mutate()} variant="secondary">
          {t("build_cache.cancel_button")}
        </Button>
      </div>
    </section>
  )
}

function RecentRequestsCard({ requests }: { requests: BuildCacheClearRequest[] }) {
  const { t } = useT("admin")
  if (requests.length === 0) return null

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900" data-testid="build-cache-recent-requests">
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm font-semibold text-gray-900 dark:text-gray-100">
        {t("build_cache.recent_heading")}
      </div>
      <ul className="divide-y divide-gray-100 dark:divide-gray-800">
        {requests.map((request) => (
          <li className="px-4 py-3 text-sm" key={request.id}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="font-medium text-gray-900 dark:text-gray-100">
                {request.scope === "full" ? t("build_cache.scope_full") : t("build_cache.pending_scope_partial_value", { days: request.older_than_days })}
              </span>
              <RequestStateBadge state={request.state} />
            </div>
            <p className="mt-1 text-gray-600 dark:text-gray-300">{request.reason}</p>
            {request.result ? (
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                {t("build_cache.result_summary", { count: request.result.deleted_count, size: formatBytes(request.result.bytes_freed) })}
              </p>
            ) : null}
            <p className="mt-1 text-xs text-gray-400 dark:text-gray-500">
              {request.requested_by ?? "—"} · <RelativeTimestamp value={request.created_at} />
            </p>
          </li>
        ))}
      </ul>
    </section>
  )
}

function RequestStateBadge({ state }: { state: BuildCacheClearRequest["state"] }) {
  const { t } = useT("admin")
  const classes = state === "confirmed"
    ? "bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-300 dark:border-emerald-900"
    : "bg-gray-100 text-gray-700 border-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:border-gray-700"

  return (
    <span className={`rounded border px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`build_cache.state_${state}`)}
    </span>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}
