import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, durationLabel, EmptyState, StatePill } from "../toolCardUi"

// Core-owned tool card for list_job_workflows (EPIC-291 / JOB-4221). Renders
// a Workflow index as a dense table: trigger kind, state, summary, step/run
// counts, and duration.
type WorkflowRow = {
  key: string
  id: string
  triggerKind: string | null
  state: string
  summary: string | null
  stepCount: number | null
  runCount: number | null
  duration: string | null
}

function parseRow(value: unknown): WorkflowRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null

  return {
    key: id,
    id,
    triggerKind: displayValue(value.trigger_kind),
    state,
    summary: displayValue(value.summary),
    stepCount: value.step_count == null ? null : Number(value.step_count),
    runCount: value.run_count == null ? null : Number(value.run_count),
    duration: durationLabel(value.started_at, value.finished_at)
  }
}

function workflowRows(context: ToolCardContext): WorkflowRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.workflows)) return null

  return parsed.workflows.flatMap((workflow) => {
    const row = parseRow(workflow)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = workflowRows(context)
  if (!rows) return null
  return `${rows.length} Workflow${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = workflowRows(context)
  if (!rows) return null

  if (rows.length === 0) return <EmptyState>No Workflows found.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Workflow</th>
            <th className="px-2 py-1 font-semibold" scope="col">Trigger</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Summary</th>
            <th className="px-2 py-1 font-semibold" scope="col">Steps</th>
            <th className="px-2 py-1 font-semibold" scope="col">Runs</th>
            <th className="px-2 py-1 font-semibold" scope="col">Duration</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="whitespace-nowrap px-2 py-1 font-mono font-medium text-gray-900 dark:text-gray-100">WF-{row.id}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.triggerKind ? <Badge>{row.triggerKind}</Badge> : "—"}</td>
              <td className="whitespace-nowrap px-2 py-1"><StatePill state={row.state} /></td>
              <td className="max-w-[20rem] truncate px-2 py-1 text-gray-700 dark:text-gray-300" title={row.summary ?? undefined}>{row.summary || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.stepCount ?? "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.runCount ?? "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.duration || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listJobWorkflowsToolCard: ToolCardRenderer = {
  toolName: "list_job_workflows",
  collapsedSummary,
  renderExpanded
}

export default listJobWorkflowsToolCard
