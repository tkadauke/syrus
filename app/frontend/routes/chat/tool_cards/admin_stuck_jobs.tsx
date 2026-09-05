import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState, InternalLink, StatePill } from "../toolCardUi"

// Core-owned tool card for admin_stuck_jobs (EPIC-291 / JOB-4221). Renders
// the admin stuck-Job watchlist as a compact ops dashboard: kind, severity/
// attention state, detail, stuck reason context, and a recommended-action
// hint where the repair plan provides one.
type StuckItemRow = {
  key: string
  jobId: string | null
  jobPath: string | null
  title: string | null
  kind: string
  attentionState: string | null
  detail: string | null
  stepKind: string | null
  ageLabel: string | null
  repairAction: string | null
}

function parseRow(value: unknown, index: number): StuckItemRow | null {
  if (!isPlainObject(value)) return null
  const kind = displayValue(value.kind)
  if (!kind) return null

  return {
    key: `${displayValue(value.job_id) ?? index}-${kind}`,
    jobId: displayValue(value.job_id ?? value.id),
    jobPath: displayValue(value.job_path),
    title: displayValue(value.title),
    kind,
    attentionState: displayValue(value.attention_state),
    detail: displayValue(value.detail),
    stepKind: displayValue(value.step_kind),
    ageLabel: displayValue(value.age_label),
    repairAction: isPlainObject(value.repair_plan) ? displayValue(value.repair_plan.action) : null
  }
}

function stuckRows(context: ToolCardContext): StuckItemRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.items)) return null

  return parsed.items.flatMap((item, index) => {
    const row = parseRow(item, index)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = stuckRows(context)
  if (!rows) return null
  return `${rows.length} stuck item${rows.length === 1 ? "" : "s"}`
}

function JobCell({ row }: { row: StuckItemRow }) {
  if (!row.jobId) return <>—</>
  const label = row.title ? `JOB-${row.jobId} — ${row.title}` : `JOB-${row.jobId}`
  return row.jobPath ? <InternalLink href={row.jobPath}>{label}</InternalLink> : <span className="font-mono">{label}</span>
}

function renderExpanded(context: ToolCardContext) {
  const rows = stuckRows(context)
  if (!rows) return null

  if (rows.length === 0) return <EmptyState>No stuck Jobs found.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Job</th>
            <th className="px-2 py-1 font-semibold" scope="col">Kind</th>
            <th className="px-2 py-1 font-semibold" scope="col">Attention</th>
            <th className="px-2 py-1 font-semibold" scope="col">Detail</th>
            <th className="px-2 py-1 font-semibold" scope="col">Step</th>
            <th className="px-2 py-1 font-semibold" scope="col">Age</th>
            <th className="px-2 py-1 font-semibold" scope="col">Next action</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="max-w-[14rem] truncate px-2 py-1 text-gray-800 dark:text-gray-200"><JobCell row={row} /></td>
              <td className="whitespace-nowrap px-2 py-1"><Badge>{row.kind.replace(/_/g, " ")}</Badge></td>
              <td className="whitespace-nowrap px-2 py-1">{row.attentionState ? <StatePill state={row.attentionState} /> : "—"}</td>
              <td className="max-w-[20rem] truncate px-2 py-1 text-gray-600 dark:text-gray-300" title={row.detail ?? undefined}>{row.detail || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.stepKind || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.ageLabel || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.repairAction ? row.repairAction.replace(/_/g, " ") : "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const adminStuckJobsToolCard: ToolCardRenderer = {
  toolName: "admin_stuck_jobs",
  collapsedSummary,
  renderExpanded
}

export default adminStuckJobsToolCard
