import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, decimalCost, displayValue, EmptyState, EntityReference, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

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
  if (context.resultError) return "Run search failed"
  const rows = runRows(context)
  if (!rows) return null
  return `${rows.length} Run${rows.length === 1 ? "" : "s"}`
}

function AppliedFilters({ input }: { input?: Record<string, unknown> }) {
  if (!input) return null

  const entries: Array<[string, string]> = [
    ["state", displayValue(input.state) ?? ""],
    ["trigger_kind", displayValue(input.trigger_kind) ?? ""],
    ["job_id", displayValue(input.job_id) ?? ""],
    ["since", displayValue(input.since) ?? ""],
    ["limit", displayValue(input.limit) ?? ""]
  ].filter(([, value]) => value.length > 0) as Array<[string, string]>

  if (entries.length === 0) return null

  return (
    <div className="flex flex-wrap gap-1">
      {entries.map(([key, value]) => (
        <Badge key={key}>
          {key}: {value}
        </Badge>
      ))}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) {
    return (
      <CardShell>
        <div className="rounded border border-danger-border bg-danger-surface px-2 py-1 text-danger-text">
          {displayValue(context.resultBody) || "Run search failed."}
        </div>
      </CardShell>
    )
  }

  const rows = runRows(context)
  if (!rows) return null

  return (
    <CardShell>
      <AppliedFilters input={context.input} />
      {rows.length === 0 ? (
        <EmptyState>No Runs found.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["Run", "Job", "Workflow", "State", "Trigger", "Started", "Finished", "Cost"]} />
          <TBody>
            {rows.map((row) => (
              <tr key={row.key}>
                <Td primary>
                  <EntityReference id={row.id} jobId={row.jobId} kind="run" workflowId={row.workflowId} wrap="nowrap" />
                </Td>
                <Td>{row.jobId ? <EntityReference id={row.jobId} kind="job" wrap="nowrap" /> : "—"}</Td>
                <Td>{row.workflowId ? <EntityReference id={row.workflowId} jobId={row.jobId} kind="workflow" wrap="nowrap" /> : "—"}</Td>
                <Td>{row.state ? <StatePill state={row.state} /> : "—"}</Td>
                <Td>{row.triggerKind ? <Badge>{row.triggerKind}</Badge> : "—"}</Td>
                <Td mono>{row.startedAt || "—"}</Td>
                <Td mono>{row.finishedAt || "—"}</Td>
                <Td mono>{row.costUsd || "—"}</Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </CardShell>
  )
}

const adminListRunsToolCard: ToolCardRenderer = {
  toolName: "admin_list_runs",
  collapsedSummary,
  renderExpanded
}

export default adminListRunsToolCard
