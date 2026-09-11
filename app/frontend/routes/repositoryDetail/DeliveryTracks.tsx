import { StatusPill } from "./shared"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { DataTable } from "../../components/ui"
import { Link } from "react-router-dom"
import { withRoutePrefix } from "../../lib/routing"
import { useT } from "../../hooks/useT"
import type { RepositoryDeliveryPayload, RepositoryDeliveryPrIngestion, RepositoryDeliveryRefMovementAction, RepositoryDeliveryRefMovementSummary, RepositoryDeliveryRefMovementWorkflow, RepositoryDeliveryTrack } from "../../api/repositories"

// Repository page "Delivery" section : tracks table, ref-movement
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
    <DataTable.Root>
      <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>{t("delivery.col_track")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("delivery.col_branch")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("delivery.col_grade_phases")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("delivery.col_health")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("delivery.col_queue_length")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("delivery.col_last_promotion")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("delivery.col_last_hotfix_sync")}</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {tracks.map((track) => (
            <DataTable.Row key={track.name}>
              <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">
                {track.name}
                {track.is_default ? <span className="ml-1 text-xs font-normal text-gray-400 dark:text-gray-500">{t("delivery.default_track_suffix")}</span> : null}
              </DataTable.Cell>
              <DataTable.Cell className="font-mono text-xs text-gray-700 dark:text-gray-300">{track.branch}</DataTable.Cell>
              <DataTable.Cell className="text-xs text-gray-600 dark:text-gray-400">
                {track.review_grade_phase} / {track.landing_grade_phase} / {track.branch_health_grade_phase}
              </DataTable.Cell>
              <DataTable.Cell>
                {track.health ? <StatusPill tone={healthTone(track.health)}>{track.health}</StatusPill> : <span className="text-xs text-gray-400 dark:text-gray-500">{t("delivery.health_not_tracked")}</span>}
              </DataTable.Cell>
              <DataTable.Cell className="text-gray-700 dark:text-gray-300">{track.queue_length}</DataTable.Cell>
              <DataTable.Cell>
                <RefMovementSummaryCell summary={track.last_promotion} />
              </DataTable.Cell>
              <DataTable.Cell>
                <RefMovementSummaryCell summary={track.last_hotfix_sync} />
              </DataTable.Cell>
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
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
      <DataTable.Root>
        <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("delivery.col_kind")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_job")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_refs")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_state")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_when")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {workflows.map((workflow) => (
              <DataTable.Row key={workflow.id}>
                <DataTable.Cell className="text-gray-700 dark:text-gray-300">{workflow.trigger_kind}</DataTable.Cell>
                <DataTable.Cell>
                  <Link className="text-brand hover:underline" to={withRoutePrefix(workflow.workflow_path, prefix)}>{workflow.job_slug}</Link>
                </DataTable.Cell>
                <DataTable.Cell className="font-mono text-xs text-gray-600 dark:text-gray-400">
                  {workflow.source_ref} &rarr; {workflow.target_repository_slug ? `${workflow.target_repository_slug}:` : ""}{workflow.target_ref}
                  {workflow.pr_number ? <span className="ml-1 text-gray-400 dark:text-gray-500">PR #{workflow.pr_number}{workflow.pr_state ? ` (${workflow.pr_state})` : ""}</span> : null}
                </DataTable.Cell>
                <DataTable.Cell><StatusPill tone={workflowStateTone(workflow.state)}>{workflow.state}</StatusPill></DataTable.Cell>
                <DataTable.Cell className="text-gray-500 dark:text-gray-400">
                  {workflow.finished_at ? <RelativeTimestamp value={workflow.finished_at} /> : workflow.created_at ? <RelativeTimestamp value={workflow.created_at} /> : null}
                </DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
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
      <DataTable.Root>
        <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("delivery.col_pr")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_job")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_classification")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("delivery.col_when")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {ingestions.map((ingestion) => (
              <DataTable.Row key={`${ingestion.job_id}-${ingestion.pr_number}`}>
                <DataTable.Cell className="text-gray-700 dark:text-gray-300">{ingestion.pr_number ? `#${ingestion.pr_number}` : "—"}</DataTable.Cell>
                <DataTable.Cell>
                  <Link className="text-brand hover:underline" to={withRoutePrefix(ingestion.job_path, prefix)}>{ingestion.job_slug}</Link>
                </DataTable.Cell>
                <DataTable.Cell>
                  <StatusPill tone={ingestion.classification === "external_unknown" ? "gray" : "blue"}>{ingestion.classification}</StatusPill>
                  {ingestion.source_repo_slug ? <span className="ml-1 text-xs text-gray-500 dark:text-gray-400">{ingestion.source_repo_slug}</span> : null}
                </DataTable.Cell>
                <DataTable.Cell className="text-gray-500 dark:text-gray-400">
                  {ingestion.created_at ? <RelativeTimestamp value={ingestion.created_at} /> : null}
                </DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
    </div>
  )
}
