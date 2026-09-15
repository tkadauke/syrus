import { useState, type FormEvent, type ReactNode } from "react"
import { Button, Notice, Page, PageDescription, PageHeader, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
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
import { Form } from "@app/components/ui/Form"
      ) : null}

      <Button disabled={create.isPending || !reason.trim()} type="submit" variant="primary">
        {create.isPending ? t("build_cache.requesting") : t("build_cache.request_button")}
      </Button>
    </Section>
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
    <Section className="border-warning/30 bg-warning/10 text-warning" data-testid="build-cache-pending-request">
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
    </Section>
  )
}

function RecentRequestsCard({ requests }: { requests: BuildCacheClearRequest[] }) {
  const { t } = useT("build_cache")
  if (requests.length === 0) return null

  return (
    <Section className="overflow-hidden p-0" data-testid="build-cache-recent-requests">
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
    </Section>
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
