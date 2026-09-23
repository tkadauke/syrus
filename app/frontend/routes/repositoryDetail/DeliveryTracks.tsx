import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { TonePill } from "../../components/StatusPill"
import { DataTable } from "../../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "../../components/dataTable"
import { Link } from "react-router-dom"
import { withRoutePrefix } from "../../lib/routing"
import { useT } from "../../hooks/useT"
import type { RepositoryDeliveryPayload, RepositoryDeliveryPrIngestion, RepositoryDeliveryRefMovementAction, RepositoryDeliveryRefMovementSummary, RepositoryDeliveryRefMovementWorkflow, RepositoryDeliveryTrack } from "../../api/repositories"

// Shared rendering for this file's three delivery-detail tables (tracks, ref
// movements, PR ingestions): a column menu next to the section heading plus
// DataTableColumnHeaderRow/Cells wired to a per-table localStorage
// preference, mirroring Repositories.tsx's direct use of the same
// DataTableColumnMenu/DataTableColumnHeaderRow/DataTableColumnCells trio.
function DeliveryColumnTable<Row>({ columns, getRowKey, rows, storageKey, t }: { columns: DataTableColumnDef<Row>[]; getRowKey: (row: Row) => string | number; rows: Row[]; storageKey: string; t: (key: string, options?: Record<string, unknown>) => string }) {
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey })

  return (
    <>
      <div className="mb-2 flex justify-end">
        <DataTableColumnMenu
          columns={columns}
          downLabel={t("repositories.column_down")}
          menuId={`${storageKey}-menu`}
          moveDownLabel={(title) => t("repositories.column_move_down", { title })}
          moveUpLabel={(title) => t("repositories.column_move_up", { title })}
          onChange={preferences.onChange}
          order={preferences.order}
          triggerAriaLabel={t("repositories.columns")}
          upLabel={t("repositories.column_up")}
          visibleLabel={t("repositories.visible_columns")}
        />
      </div>
      <DataTable.Root>
        <DataTable.Header>
          <DataTableColumnHeaderRow columns={columns} onReorder={preferences.onChange} order={preferences.order} />
        </DataTable.Header>
        <DataTable.Body>
          {rows.map((row) => (
            <DataTable.Row key={getRowKey(row)}>
              <DataTableColumnCells columns={columns} order={preferences.order} row={row} />
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
    </>
  )
}

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

  const columns: DataTableColumnDef<RepositoryDeliveryTrack>[] = [
    {
      key: "track",
      label: t("delivery.col_track"),
      required: true,
      cellClassName: "font-medium text-gray-900 dark:text-gray-100",
      renderCell: (track) => (
        <>
          {track.name}
          {track.is_default ? <span className="ml-1 text-xs font-normal text-gray-400 dark:text-gray-500">{t("delivery.default_track_suffix")}</span> : null}
        </>
      )
    },
    { key: "branch", label: t("delivery.col_branch"), cellClassName: "font-mono text-xs text-gray-700 dark:text-gray-300", renderCell: (track) => track.branch },
    { key: "grade_phases", label: t("delivery.col_grade_phases"), cellClassName: "text-xs text-gray-600 dark:text-gray-400", renderCell: (track) => `${track.review_grade_phase} / ${track.landing_grade_phase} / ${track.branch_health_grade_phase}` },
    { key: "health", label: t("delivery.col_health"), renderCell: (track) => track.health ? <TonePill tone={healthTone(track.health)}>{track.health}</TonePill> : <span className="text-xs text-gray-400 dark:text-gray-500">{t("delivery.health_not_tracked")}</span> },
    { key: "queue_length", label: t("delivery.col_queue_length"), cellClassName: "text-gray-700 dark:text-gray-300", renderCell: (track) => track.queue_length },
    { key: "last_promotion", label: t("delivery.col_last_promotion"), renderCell: (track) => <RefMovementSummaryCell summary={track.last_promotion} /> },
    { key: "last_hotfix_sync", label: t("delivery.col_last_hotfix_sync"), renderCell: (track) => <RefMovementSummaryCell summary={track.last_hotfix_sync} /> }
  ]

  return <DeliveryColumnTable columns={columns} getRowKey={(track) => track.name} rows={tracks} storageKey="syrus.repository_detail.delivery_tracks.visible_columns" t={t} />
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
            <TonePill tone={action.available ? "green" : action.enabled ? "amber" : "gray"}>
              {action.available ? t("delivery.action_available") : action.enabled ? t("delivery.action_blocked") : t("delivery.action_disabled")}
            </TonePill>
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

  const columns: DataTableColumnDef<RepositoryDeliveryRefMovementWorkflow>[] = [
    { key: "kind", label: t("delivery.col_kind"), required: true, cellClassName: "text-gray-700 dark:text-gray-300", renderCell: (workflow) => workflow.trigger_kind },
    { key: "job", label: t("delivery.col_job"), renderCell: (workflow) => <Link className="text-brand hover:underline" to={withRoutePrefix(workflow.workflow_path, prefix)}>{workflow.job_slug}</Link> },
    {
      key: "refs",
      label: t("delivery.col_refs"),
      cellClassName: "font-mono text-xs text-gray-600 dark:text-gray-400",
      renderCell: (workflow) => (
        <>
          {workflow.source_ref} &rarr; {workflow.target_repository_slug ? `${workflow.target_repository_slug}:` : ""}{workflow.target_ref}
          {workflow.pr_number ? <span className="ml-1 text-gray-400 dark:text-gray-500">PR #{workflow.pr_number}{workflow.pr_state ? ` (${workflow.pr_state})` : ""}</span> : null}
        </>
      )
    },
    { key: "state", label: t("delivery.col_state"), renderCell: (workflow) => <TonePill tone={workflowStateTone(workflow.state)}>{workflow.state}</TonePill> },
    {
      key: "when",
      label: t("delivery.col_when"),
      cellClassName: "text-gray-500 dark:text-gray-400",
      renderCell: (workflow) => workflow.finished_at ? <RelativeTimestamp value={workflow.finished_at} /> : workflow.created_at ? <RelativeTimestamp value={workflow.created_at} /> : null
    }
  ]

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("delivery.recent_ref_movements_heading")}</h3>
      <DeliveryColumnTable columns={columns} getRowKey={(workflow) => workflow.id} rows={workflows} storageKey="syrus.repository_detail.delivery_ref_movements.visible_columns" t={t} />
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

  const columns: DataTableColumnDef<RepositoryDeliveryPrIngestion>[] = [
    { key: "pr", label: t("delivery.col_pr"), required: true, cellClassName: "text-gray-700 dark:text-gray-300", renderCell: (ingestion) => ingestion.pr_number ? `#${ingestion.pr_number}` : "—" },
    { key: "job", label: t("delivery.col_job"), renderCell: (ingestion) => <Link className="text-brand hover:underline" to={withRoutePrefix(ingestion.job_path, prefix)}>{ingestion.job_slug}</Link> },
    {
      key: "classification",
      label: t("delivery.col_classification"),
      renderCell: (ingestion) => (
        <>
          <TonePill tone={ingestion.classification === "external_unknown" ? "gray" : "blue"}>{ingestion.classification}</TonePill>
          {ingestion.source_repo_slug ? <span className="ml-1 text-xs text-gray-500 dark:text-gray-400">{ingestion.source_repo_slug}</span> : null}
        </>
      )
    },
    { key: "when", label: t("delivery.col_when"), cellClassName: "text-gray-500 dark:text-gray-400", renderCell: (ingestion) => ingestion.created_at ? <RelativeTimestamp value={ingestion.created_at} /> : null }
  ]

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-gray-700 dark:text-gray-300">{t("delivery.recent_pr_ingestions_heading")}</h3>
      <DeliveryColumnTable columns={columns} getRowKey={(ingestion) => `${ingestion.job_id}-${ingestion.pr_number}`} rows={ingestions} storageKey="syrus.repository_detail.delivery_pr_ingestions.visible_columns" t={t} />
    </div>
  )
}
