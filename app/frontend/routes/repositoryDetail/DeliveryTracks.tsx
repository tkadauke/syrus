import { StatusPill } from "./shared"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { Link } from "react-router-dom"
import { withRoutePrefix } from "../../lib/routing"
import { useT } from "../../hooks/useT"
import type { RepositoryDeliveryPayload, RepositoryDeliveryPrIngestion, RepositoryDeliveryRefMovementAction, RepositoryDeliveryRefMovementSummary, RepositoryDeliveryRefMovementWorkflow, RepositoryDeliveryTrack } from "../../api/repositories"

// Repository page "Delivery" section (EPIC-268): tracks table, ref-movement
// action availability, recent ref-movement workflows, and recent PR
// ingestion classifications. Rendered only when the repository's
// `delivery` payload is non-null (i.e. it has opted into more than the
// implicit single default track) — see App::DeliveryTracksPayload#configured?.

function healthTone(health: string | null): "green" | "red" | "gray" | "amber" {
  if (health === "healthy") return "green"
  if (health === "broken") return "red"
  if (health === "inconclusive") return "amber"
  return "gray"
}

export function DeliveryTracksSection({ delivery, prefix }: { delivery: RepositoryDeliveryPayload; prefix: string }) {
  const { t } = useT("settings")

  return (
    <section aria-label={t("delivery.aria_section")}>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">
        {t("delivery.heading")}
      </h2>
      <div className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <DeliveryTracksTable tracks={delivery.tracks} />
        <RefMovementActionsList actions={delivery.ref_movement_actions} />
        <RecentRefMovementWorkflows prefix={prefix} workflows={delivery.recent_ref_movement_workflows} />
        <RecentPrIngestions prefix={prefix} ingestions={delivery.recent_pr_ingestions} />
      </div>
    </section>
  )
}

function DeliveryTracksTable({ tracks }: { tracks: RepositoryDeliveryTrack[] }) {
  const { t } = useT("settings")
  if (tracks.length === 0) return null

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-3 py-2">{t("delivery.col_track")}</th>
            <th className="px-3 py-2">{t("delivery.col_branch")}</th>
            <th className="px-3 py-2">{t("delivery.col_grade_phases")}</th>
            <th className="px-3 py-2">{t("delivery.col_health")}</th>
            <th className="px-3 py-2">{t("delivery.col_queue_length")}</th>
            <th className="px-3 py-2">{t("delivery.col_last_promotion")}</th>
            <th className="px-3 py-2">{t("delivery.col_last_hotfix_sync")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {tracks.map((track) => (
            <tr key={track.name}>
              <td className="px-3 py-2 font-medium text-gray-900 dark:text-gray-100">
                {track.name}
                {track.is_default ? <span className="ml-1 text-xs font-normal text-gray-400 dark:text-gray-500">{t("delivery.default_track_suffix")}</span> : null}
              </td>
              <td className="px-3 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">{track.branch}</td>
              <td className="px-3 py-2 text-xs text-gray-600 dark:text-gray-400">
                {track.review_grade_phase} / {track.landing_grade_phase} / {track.branch_health_grade_phase}
              </td>
              <td className="px-3 py-2">
                {track.health ? <StatusPill tone={healthTone(track.health)}>{track.health}</StatusPill> : <span className="text-xs text-gray-400 dark:text-gray-500">{t("delivery.health_not_tracked")}</span>}
              </td>
              <td className="px-3 py-2 text-gray-700 dark:text-gray-300">{track.queue_length}</td>
              <td className="px-3 py-2">
                <RefMovementSummaryCell summary={track.last_promotion} />
              </td>
              <td className="px-3 py-2">
                <RefMovementSummaryCell summary={track.last_hotfix_sync} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function RefMovementSummaryCell({ summary }: { summary: RepositoryDeliveryRefMovementSummary | null }) {
  const { t } = useT("settings")
  if (!summary) return <span className="text-xs text-gray-400 dark:text-gray-500">{t("delivery.none_yet")}</span>

  return (
    <div className="text-xs text-gray-600 dark:text-gray-400">
      <div className="font-mono">{summary.source_ref} &rarr; {summary.target_ref}</div>
      {summary.finished_at ? <RelativeTimestamp value={summary.finished_at} /> : null}
    </div>
  )
}

function RefMovementActionsList({ actions }: { actions: RepositoryDeliveryRefMovementAction[] }) {
  const { t } = useT("settings")
  if (actions.length === 0) return null

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("delivery.ref_movement_actions_heading")}</h3>
      <ul className="space-y-1.5">
        {actions.map((action) => (
          <li className="flex flex-wrap items-center gap-2 text-sm" key={action.name}>
            <span className="font-mono text-xs text-gray-700 dark:text-gray-300">{action.name}</span>
            <StatusPill tone={action.available ? "green" : action.enabled ? "amber" : "gray"}>
              {action.available ? t("delivery.action_available") : action.enabled ? t("delivery.action_blocked") : t("delivery.action_disabled")}
            </StatusPill>
            {action.mode ? <span className="text-xs text-gray-500 dark:text-gray-400">{action.mode}</span> : null}
            {action.blocked_reason ? <span className="text-xs text-gray-500 dark:text-gray-400">{action.blocked_reason}</span> : null}
          </li>
        ))}
      </ul>
    </div>
  )
}

function RecentRefMovementWorkflows({ workflows, prefix }: { workflows: RepositoryDeliveryRefMovementWorkflow[]; prefix: string }) {
  const { t } = useT("settings")
  if (workflows.length === 0) return null

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("delivery.recent_ref_movements_heading")}</h3>
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-3 py-2">{t("delivery.col_kind")}</th>
              <th className="px-3 py-2">{t("delivery.col_job")}</th>
              <th className="px-3 py-2">{t("delivery.col_refs")}</th>
              <th className="px-3 py-2">{t("delivery.col_state")}</th>
              <th className="px-3 py-2">{t("delivery.col_when")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {workflows.map((workflow) => (
              <tr key={workflow.id}>
                <td className="px-3 py-2 text-gray-700 dark:text-gray-300">{workflow.trigger_kind}</td>
                <td className="px-3 py-2">
                  <Link className="text-brand hover:underline" to={withRoutePrefix(workflow.workflow_path, prefix)}>{workflow.job_slug}</Link>
                </td>
                <td className="px-3 py-2 font-mono text-xs text-gray-600 dark:text-gray-400">
                  {workflow.source_ref} &rarr; {workflow.target_repository_slug ? `${workflow.target_repository_slug}:` : ""}{workflow.target_ref}
                  {workflow.pr_number ? <span className="ml-1 text-gray-400 dark:text-gray-500">PR #{workflow.pr_number}{workflow.pr_state ? ` (${workflow.pr_state})` : ""}</span> : null}
                </td>
                <td className="px-3 py-2"><StatusPill tone={workflowStateTone(workflow.state)}>{workflow.state}</StatusPill></td>
                <td className="px-3 py-2 text-gray-500 dark:text-gray-400">
                  {workflow.finished_at ? <RelativeTimestamp value={workflow.finished_at} /> : workflow.created_at ? <RelativeTimestamp value={workflow.created_at} /> : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function workflowStateTone(state: string): "green" | "red" | "gray" | "amber" | "blue" {
  if (state === "succeeded") return "green"
  if (state === "failed" || state === "cancelled") return "red"
  if (state === "running") return "blue"
  return "gray"
}

function RecentPrIngestions({ ingestions, prefix }: { ingestions: RepositoryDeliveryPrIngestion[]; prefix: string }) {
  const { t } = useT("settings")
  if (ingestions.length === 0) return null

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("delivery.recent_pr_ingestions_heading")}</h3>
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-3 py-2">{t("delivery.col_pr")}</th>
              <th className="px-3 py-2">{t("delivery.col_job")}</th>
              <th className="px-3 py-2">{t("delivery.col_classification")}</th>
              <th className="px-3 py-2">{t("delivery.col_when")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {ingestions.map((ingestion) => (
              <tr key={`${ingestion.job_id}-${ingestion.pr_number}`}>
                <td className="px-3 py-2 text-gray-700 dark:text-gray-300">{ingestion.pr_number ? `#${ingestion.pr_number}` : "—"}</td>
                <td className="px-3 py-2">
                  <Link className="text-brand hover:underline" to={withRoutePrefix(ingestion.job_path, prefix)}>{ingestion.job_slug}</Link>
                </td>
                <td className="px-3 py-2">
                  <StatusPill tone={ingestion.classification === "external_unknown" ? "gray" : "blue"}>{ingestion.classification}</StatusPill>
                  {ingestion.source_repo_slug ? <span className="ml-1 text-xs text-gray-500 dark:text-gray-400">{ingestion.source_repo_slug}</span> : null}
                </td>
                <td className="px-3 py-2 text-gray-500 dark:text-gray-400">
                  {ingestion.created_at ? <RelativeTimestamp value={ingestion.created_at} /> : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
