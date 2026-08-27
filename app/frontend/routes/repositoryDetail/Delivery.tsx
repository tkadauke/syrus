import { appendSearch, buttonClass, PanelMessage, StatusPill, type RepositoryDetailQueryKey } from "./shared"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { withRoutePrefix } from "../../lib/routing"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import {
  dispatchRefMovementAction,
  type RepositoryDeliveryJobRef,
  type RepositoryDeliveryPayload,
  type RepositoryDeliveryPrIngestion,
  type RepositoryDeliveryRecentRefMovementAction,
  type RepositoryDeliveryRecentWorkflow,
  type RepositoryDeliveryRefMovementActionConfig,
  type RepositoryDetailPayload
} from "../../api/repositories"
import { errorMessage } from "../../lib/errorMessage"

// Repository delivery section (EPIC-268 / JOB-3690): tracks table,
// ref-movement action availability + dispatch, and recent ref-movement
// workflow/PR-ingestion history. Entirely read-only against data prior Epic
// Jobs already compute (DeliveryPolicy, RefMovementAction, JobPrLink,
// promotion/hotfix_sync/upstream_export Workflows).

export function DeliverySection({ delivery, page, prefix, queryKey, onNotice }: { delivery: RepositoryDeliveryPayload; page: number; prefix: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")

  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
        {t("repository.delivery_heading")}
      </h2>
      <div className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <TracksTable delivery={delivery} />
        <RefMovementActions delivery={delivery} page={page} queryKey={queryKey} onNotice={onNotice} />
        <RecentRefMovementActions actions={delivery.recent_ref_movement_actions} prefix={prefix} />
        <RecentWorkflows workflows={delivery.recent_workflows} prefix={prefix} />
        <RecentPrIngestions ingestions={delivery.recent_pr_ingestions} prefix={prefix} />
      </div>
    </section>
  )
}

function TracksTable({ delivery }: { delivery: RepositoryDeliveryPayload }) {
  const { t } = useT("settings")

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.delivery_tracks_heading")}</h3>
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-3 py-2">{t("repository.delivery_col_track")}</th>
              <th className="px-3 py-2">{t("repository.delivery_col_branch")}</th>
              <th className="px-3 py-2">{t("repository.delivery_col_grade_phases")}</th>
              <th className="px-3 py-2">{t("repository.delivery_col_health")}</th>
              <th className="px-3 py-2">{t("repository.delivery_col_queue")}</th>
              <th className="px-3 py-2">{t("repository.delivery_col_last_promotion_sync")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {delivery.tracks.map((track) => (
              <tr key={track.name}>
                <td className="px-3 py-2 font-mono text-xs text-gray-800 dark:text-gray-200">
                  {track.name}
                  {track.default ? <span className="ml-1 text-2xs text-gray-400 dark:text-gray-500">{t("repository.delivery_default_track")}</span> : null}
                </td>
                <td className="px-3 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">{track.branch}</td>
                <td className="px-3 py-2 text-xs text-gray-600 dark:text-gray-400">
                  {track.review_grade_phase} / {track.landing_grade_phase} / {track.branch_health_grade_phase}
                </td>
                <td className="px-3 py-2"><HealthPill health={track.health} /></td>
                <td className="px-3 py-2">
                  {track.queue_path ? (
                    <a className="text-blue-600 dark:text-blue-400 hover:underline" href={track.queue_path}>{track.landing_queue_count}</a>
                  ) : (
                    track.landing_queue_count
                  )}
                </td>
                <td className="px-3 py-2 text-gray-500 dark:text-gray-400">
                  {track.last_promotion_or_sync_at ? <RelativeTimestamp value={track.last_promotion_or_sync_at} /> : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function HealthPill({ health }: { health: string }) {
  const tone = health === "healthy" ? "green" : health === "broken" ? "red" : health === "inconclusive" ? "amber" : "gray"
  return <StatusPill tone={tone}>{health.replace(/_/g, " ")}</StatusPill>
}

function RefMovementActions({ delivery, page, queryKey, onNotice }: { delivery: RepositoryDeliveryPayload; page: number; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")

  if (delivery.ref_movement_actions.length === 0) {
    return (
      <div>
        <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.delivery_actions_heading")}</h3>
        <p className="text-sm text-gray-500 dark:text-gray-400">{t("repository.delivery_no_actions_configured")}</p>
      </div>
    )
  }

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.delivery_actions_heading")}</h3>
      <ul className="space-y-2">
        {delivery.ref_movement_actions.map((action) => (
          <RefMovementActionRow action={action} key={action.name} page={page} path={delivery.paths.app_dispatch_ref_movement_action_repository_path} queryKey={queryKey} onNotice={onNotice} />
        ))}
      </ul>
    </div>
  )
}

function RefMovementActionRow({ action, page, path, queryKey, onNotice }: { action: RepositoryDeliveryRefMovementActionConfig; page: number; path: string; queryKey: RepositoryDetailQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const search = queryKey[3]
  const [sourceBranch, setSourceBranch] = useState("")
  const [targetBranch, setTargetBranch] = useState("")
  const dispatch = useMutation({
    mutationFn: () => dispatchRefMovementAction(
      appendSearch(path, search),
      { refMovementActionName: action.name, sourceBranch: sourceBranch.trim() || undefined, targetBranch: targetBranch.trim() || undefined },
      page
    ),
    onSuccess: (updated: RepositoryDetailPayload) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  return (
    <li className="rounded border border-gray-200 dark:border-gray-700 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm text-gray-800 dark:text-gray-200">{action.name}</span>
        {action.mode ? <span className="text-xs text-gray-500 dark:text-gray-400">{action.mode}</span> : null}
        <StatusPill tone={action.available ? "green" : "gray"}>
          {action.available ? t("repository.delivery_action_available") : t("repository.delivery_action_blocked")}
        </StatusPill>
        {action.name === "submit_branch_upstream" ? (
          <>
            <input
              className="w-32 rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1 text-xs"
              onChange={(event) => setSourceBranch(event.target.value)}
              placeholder={t("repository.delivery_source_branch_placeholder")}
              type="text"
              value={sourceBranch}
            />
            <input
              className="w-32 rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1 text-xs"
              onChange={(event) => setTargetBranch(event.target.value)}
              placeholder={t("repository.delivery_target_branch_placeholder")}
              type="text"
              value={targetBranch}
            />
          </>
        ) : null}
        <button
          className={buttonClass("gray")}
          disabled={dispatch.isPending || !action.available}
          onClick={() => { onNotice(null); dispatch.mutate() }}
          type="button"
        >
          {t("repository.delivery_dispatch")}
        </button>
      </div>
      {!action.available && action.blocked_reason ? (
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{action.blocked_reason}</p>
      ) : null}
      {dispatch.isError ? <PanelMessage tone="error">{errorMessage(dispatch.error, "Unable to dispatch ref-movement action.")}</PanelMessage> : null}
    </li>
  )
}

function RecentRefMovementActions({ actions, prefix }: { actions: RepositoryDeliveryRecentRefMovementAction[]; prefix: string }) {
  const { t } = useT("settings")
  if (actions.length === 0) return null

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.delivery_recent_actions_heading")}</h3>
      <ul className="space-y-1 text-sm">
        {actions.map((action) => (
          <li className="flex flex-wrap items-center gap-2 border-b border-gray-100 dark:border-gray-800 pb-1 last:border-0" key={action.id}>
            <span className="font-mono text-xs text-gray-800 dark:text-gray-200">{action.action_name}</span>
            <StatusPill tone={action.state === "dispatched" ? "green" : "amber"}>{action.state}</StatusPill>
            {action.source_ref ? <span className="text-xs text-gray-500 dark:text-gray-400">{action.source_ref} → {action.target_ref || "?"}</span> : null}
            {action.job ? <JobLink job={action.job} prefix={prefix} /> : null}
            {action.blocked_reason ? <span className="text-xs text-amber-700 dark:text-amber-300">{action.blocked_reason}</span> : null}
            <span className="ml-auto text-xs text-gray-400 dark:text-gray-500"><RelativeTimestamp value={action.created_at} /></span>
          </li>
        ))}
      </ul>
    </div>
  )
}

function RecentWorkflows({ workflows, prefix }: { workflows: RepositoryDeliveryRecentWorkflow[]; prefix: string }) {
  const { t } = useT("settings")
  if (workflows.length === 0) return null

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.delivery_recent_workflows_heading")}</h3>
      <ul className="space-y-1 text-sm">
        {workflows.map((workflow) => (
          <li className="flex flex-wrap items-center gap-2 border-b border-gray-100 dark:border-gray-800 pb-1 last:border-0" key={workflow.id}>
            <span className="text-xs text-gray-800 dark:text-gray-200">{workflow.trigger_kind_label}</span>
            <StatusPill tone={workflow.state === "succeeded" ? "green" : workflow.state === "failed" ? "red" : "gray"}>{workflow.state}</StatusPill>
            {workflow.source_ref ? <span className="text-xs text-gray-500 dark:text-gray-400">{workflow.source_ref} → {workflow.target_ref || "?"}{workflow.target_repository_slug ? ` (${workflow.target_repository_slug})` : ""}</span> : null}
            <JobLink job={workflow.job} prefix={prefix} />
            <span className="ml-auto text-xs text-gray-400 dark:text-gray-500"><RelativeTimestamp value={workflow.created_at} /></span>
          </li>
        ))}
      </ul>
    </div>
  )
}

function RecentPrIngestions({ ingestions, prefix }: { ingestions: RepositoryDeliveryPrIngestion[]; prefix: string }) {
  const { t } = useT("settings")
  if (ingestions.length === 0) return null

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("repository.delivery_recent_ingestions_heading")}</h3>
      <ul className="space-y-1 text-sm">
        {ingestions.map((ingestion) => (
          <li className="flex flex-wrap items-center gap-2 border-b border-gray-100 dark:border-gray-800 pb-1 last:border-0" key={ingestion.job.id}>
            {ingestion.pr_number && ingestion.external_pr_url ? (
              <a className="text-xs text-indigo-700 dark:text-indigo-300 underline hover:no-underline" href={ingestion.external_pr_url} rel="noopener" target="_blank">PR #{ingestion.pr_number}</a>
            ) : null}
            <StatusPill tone="gray">{ingestion.provenance.replace(/_/g, " ")}</StatusPill>
            {ingestion.source_repo_slug ? <span className="text-xs text-gray-500 dark:text-gray-400">{ingestion.source_repo_slug}</span> : null}
            <JobLink job={ingestion.job} prefix={prefix} />
            <span className="ml-auto text-xs text-gray-400 dark:text-gray-500"><RelativeTimestamp value={ingestion.created_at} /></span>
          </li>
        ))}
      </ul>
    </div>
  )
}

function JobLink({ job, prefix }: { job: RepositoryDeliveryJobRef; prefix: string }) {
  return (
    <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline text-xs" to={withRoutePrefix(job.job_path, prefix)}>
      {job.slug}
    </Link>
  )
}
