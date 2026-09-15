import { useState, type FormEvent, type ReactNode } from "react"
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
import { Badge, Button, Form, Notice, Page, Section, Text } from "@app/components/ui"

const QUERY_KEY = ["admin", "build_cache"]

export function AdminBuildCache() {
  const { t } = useT("build_cache")
  usePageTitle(t("page_title_build_cache"))
  const query = useQuery({ queryKey: QUERY_KEY, queryFn: fetchAdminBuildCache })

  return (
    <Page.Root aria-label={t("build_cache.aria_main")} size="narrow">
      <Page.Header>
        <Page.HeadingGroup>
          <Text variant="label" muted>
            {t("admin:section_label")}
          </Text>
          <Page.Title>{t("build_cache.heading")}</Page.Title>
          <Page.Description>{t("build_cache.description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      {query.isPending ? <PanelMessage>{t("build_cache.loading")}</PanelMessage> : null}
      {query.isError ? <PanelMessage tone="error">{query.error instanceof ApiError ? query.error.message : t("build_cache.error_load")}</PanelMessage> : null}
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
      {payload.pending_request ? <PendingRequestCard request={payload.pending_request} /> : <ClearRequestForm />}
      <RecentRequestsCard requests={payload.recent_requests} />
    </>
  )
}

function StatsCard({ payload }: { payload: AdminBuildCachePayload }) {
  const { t } = useT("build_cache")
  const stats = payload.stats

  return (
    <Section.Root data-testid="build-cache-stats">
      <Section.Header>
        <Section.Title>{t("build_cache.stats_heading")}</Section.Title>
      </Section.Header>

      {payload.stats_error ? (
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
            <Text className="mt-3" tone="warning" variant="caption">
              {t("build_cache.stats_truncated")}
            </Text>
          ) : null}
        </>
      ) : (
        <Text className="mt-2" muted>
          {t("build_cache.stats_unavailable")}
        </Text>
      )}
    </Section.Root>
  )
}

function Stat({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div>
      <Text as="dt" variant="label" muted>
        {label}
      </Text>
      <Text as="dd" className="mt-0.5 font-medium">
        {value}
      </Text>
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
      <Section.Header>
        <Section.Title>{t("build_cache.request_heading")}</Section.Title>
      </Section.Header>
      <form className="mt-4 space-y-4" onSubmit={submit} data-testid="build-cache-clear-form">
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
          <p className="text-sm text-danger-text" role="alert">
            {create.error instanceof ApiError ? create.error.message : t("build_cache.error_generic")}
          </p>
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
    const message = request.scope === "full" ? t("build_cache.confirm_full") : t("build_cache.confirm_partial", { days: request.older_than_days })
    if (await confirm({ message, destructive: true, confirmLabel: t("build_cache.confirm_button") })) {
      confirmMutation.mutate()
    }
  }

  return (
    <Notice tone="warning" title={t("build_cache.pending_heading")} data-testid="build-cache-pending-request">
      {dialog}
      <dl className="mt-2 grid grid-cols-1 gap-y-1 text-sm sm:grid-cols-[8rem_1fr]">
        <Text as="dt" tone="warning">
          {t("build_cache.pending_scope")}
        </Text>
        <dd>{request.scope === "full" ? t("build_cache.scope_full") : t("build_cache.pending_scope_partial_value", { days: request.older_than_days })}</dd>
        <Text as="dt" tone="warning">
          {t("build_cache.pending_reason")}
        </Text>
        <dd className="whitespace-pre-wrap">{request.reason}</dd>
        <Text as="dt" tone="warning">
          {t("build_cache.pending_requested_by")}
        </Text>
        <dd>
          {request.requested_by ?? "—"} · <RelativeTimestamp value={request.created_at} />
        </dd>
      </dl>

      {confirmMutation.isError ? (
        <Text className="mt-2" role="alert" tone="danger">
          {confirmMutation.error instanceof ApiError ? confirmMutation.error.message : t("build_cache.error_generic")}
        </Text>
      ) : null}

      <Notice.Actions>
        <Button disabled={confirmMutation.isPending} onClick={onConfirmClick} variant="danger">
          {confirmMutation.isPending ? t("build_cache.confirming") : t("build_cache.confirm_button")}
        </Button>
        <Button disabled={cancelMutation.isPending} onClick={() => cancelMutation.mutate()} variant="secondary">
          {t("build_cache.cancel_button")}
        </Button>
      </Notice.Actions>
    </Notice>
  )
}

function RecentRequestsCard({ requests }: { requests: BuildCacheClearRequest[] }) {
  const { t } = useT("build_cache")
  if (requests.length === 0) return null

  return (
    <Section.Root divided padding="none" data-testid="build-cache-recent-requests">
      <Section.Header className="px-4 py-3">
        <Section.Title>{t("build_cache.recent_heading")}</Section.Title>
      </Section.Header>
      <ul className="divide-y divide-gray-100 dark:divide-gray-800">
        {requests.map((request) => (
          <li className="px-4 py-3 text-sm" key={request.id}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="font-medium text-gray-900 dark:text-gray-100">
                {request.scope === "full" ? t("build_cache.scope_full") : t("build_cache.pending_scope_partial_value", { days: request.older_than_days })}
              </span>
              <RequestStateBadge state={request.state} />
            </div>
            <Text className="mt-1">{request.reason}</Text>
            {request.result ? (
              <Text className="mt-1" variant="caption" muted>
                {t("build_cache.result_summary", { count: request.result.deleted_count, size: formatBytes(request.result.bytes_freed) })}
              </Text>
            ) : null}
            <Text className="mt-1" variant="caption" tone="subtle">
              {request.requested_by ?? "—"} · <RelativeTimestamp value={request.created_at} />
            </Text>
          </li>
        ))}
      </ul>
    </Section.Root>
  )
}

function RequestStateBadge({ state }: { state: BuildCacheClearRequest["state"] }) {
  const { t } = useT("build_cache")

  return <Badge tone={state === "confirmed" ? "success" : "neutral"}>{t(`build_cache.state_${state}`)}</Badge>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <Notice tone={tone === "error" ? "danger" : "neutral"}>{children}</Notice>
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default AdminBuildCache
