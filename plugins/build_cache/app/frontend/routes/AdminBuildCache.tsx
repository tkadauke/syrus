import { useState, type FormEvent, type ReactNode } from "react"
import { Button, Notice, Page, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { ApiError } from "@app/api/client"
import {
  cancelBuildCacheClearRequest,
  confirmBuildCacheClearRequest,
  createBuildCacheClearRequest,
  fetchAdminBuildCache,
  type AdminBuildCachePayload,
  type BuildCacheClearRequest,
  type BuildCacheClearRequestScope
} from "../api/adminBuildCache"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useConfirm } from "@app/hooks/useConfirm"
import { formatBytes } from "@app/lib/format"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { Form } from "@app/components/ui"

const QUERY_KEY = ["admin", "build_cache"]

export function AdminBuildCache() {
  const { t } = useT("build_cache")
  usePageTitle(t("page_title_build_cache"))
  const query = useQuery({ queryKey: QUERY_KEY, queryFn: fetchAdminBuildCache })

  return (
    <Page.Root aria-label={t("build_cache.aria_main")}>
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">{t("admin:section_label")}</Text>
        <PageHeading>{t("build_cache.heading")}</PageHeading>
        <Page.Description>{t("build_cache.description")}</Page.Description>
      </Page.Header>

      {query.isPending ? <Notice>{t("build_cache.loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{query.error instanceof ApiError ? query.error.message : t("build_cache.error_load")}</Notice> : null}
      {query.isSuccess ? <BuildCacheContent payload={query.data} /> : null}
    </Page.Root>
  )
}

function BuildCacheContent({ payload }: { payload: AdminBuildCachePayload }) {
  const { t } = useT("build_cache")

  if (!payload.configured) {
    return <Notice tone="warning">{t("build_cache.not_configured")}</Notice>
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
  const { t } = useT("build_cache")
  const stats = payload.stats

  return (
    <Section.Root data-testid="build-cache-stats">
      <SectionHeading>{t("build_cache.stats_heading")}</SectionHeading>

      {payload.stats_error ? (
        <Text className="mt-2" tone="danger">{payload.stats_error}</Text>
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
            <Text className="mt-3" variant="caption" tone="warning">{t("build_cache.stats_truncated")}</Text>
          ) : null}
        </>
      ) : (
        <Text className="mt-2" tone="muted">{t("build_cache.stats_unavailable")}</Text>
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
              <input checked={scope === "partial"} className="h-4 w-4 accent-brand" name="scope" onChange={() => setScope("partial")} type="radio" value="partial" />
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
          <Text role="alert" tone="danger">{create.error instanceof ApiError ? create.error.message : t("build_cache.error_generic")}</Text>
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
    <Section.Root className="border-warning/30 bg-warning/10 text-warning" data-testid="build-cache-pending-request">
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
        <Text className="mt-2" tone="danger">{confirmMutation.error instanceof ApiError ? confirmMutation.error.message : t("build_cache.error_generic")}</Text>
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
  if (requests.length === 0) return null

  return (
    <Section.Root className="overflow-hidden p-0" data-testid="build-cache-recent-requests">
      <div className="border-b border-border px-4 py-3 text-sm font-semibold text-text-primary">
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
    </Section.Root>
  )
}

function RequestStateBadge({ state }: { state: BuildCacheClearRequest["state"] }) {
  const { t } = useT("build_cache")
  const classes = state === "confirmed"
    ? "bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-300 dark:border-emerald-900"
    : "bg-gray-100 text-gray-700 border-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:border-gray-700"

  return (
    <span className={`rounded border px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`build_cache.state_${state}`)}
    </span>
  )
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default AdminBuildCache
