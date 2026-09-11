import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, decimalCost, displayValue, EmptyState, StatePill } from "../toolCardUi"
import { JobRefLink, Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_list_runs (the tool-card work). Renders a
// dense cross-Job table of Runs: state, trigger kind, timing, and cost.
type RunRow = {
  key: string
  id: string
  jobId: string | null
  workflowId: string | null
  state: string | null
  triggerKind: string | null
  startedAt: string | null
  finishedAt: string | null
  costUsd: string | null
}

function parseRow(value: unknown, index: number): RunRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    key: `${id}-${index}`,
    id,
    jobId: displayValue(value.job_id),
    workflowId: displayValue(value.workflow_id),
    state: displayValue(value.state),
    triggerKind: displayValue(value.trigger_kind),
    startedAt: displayValue(value.started_at),
    finishedAt: displayValue(value.finished_at),
    costUsd: decimalCost(value.cost_usd)
  }
}

function runRows(context: ToolCardContext): RunRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.runs)) return null

  return parsed.runs.flatMap((run, index) => {
    const row = parseRow(run, index)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = runRows(context)
  if (!rows) return null
  return `${rows.length} Run${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = runRows(context)
  if (!rows) return null

  if (rows.length === 0) return <EmptyState>No Runs found.</EmptyState>

  return (
    <CardShell>
      <Table>
        <THead columns={["Run", "Job", "Workflow", "State", "Trigger", "Started", "Finished", "Cost"]} />
        <TBody>
          {rows.map((row) => (
            <tr key={row.key}>
              <Td mono>RUN-{row.id}</Td>
              <Td>
                <JobRefLink jobId={row.jobId} />
              </Td>
              <Td mono>{row.workflowId ? `WF-${row.workflowId}` : "—"}</Td>
              <Td>{row.state ? <StatePill state={row.state} /> : "—"}</Td>
              <Td>{row.triggerKind ? <Badge>{row.triggerKind}</Badge> : "—"}</Td>
              <Td mono>{row.startedAt || "—"}</Td>
              <Td mono>{row.finishedAt || "—"}</Td>
              <Td mono>{row.costUsd || "—"}</Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

const adminListRunsToolCard: ToolCardRenderer = {
  toolName: "admin_list_runs",
  collapsedSummary,
  renderExpanded
}

export default adminListRunsToolCard
