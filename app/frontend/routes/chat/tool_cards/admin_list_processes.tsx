import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, EntityReference, numberValue, Row, StatePill } from "../toolCardUi"
import { TextPreview } from "../toolCardMarkdown"
import { formatBytesLarge, formatPercent, Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_list_processes (the tool-card work).
// Renders SpawnedProcess rows as a dense ops table: kind, host/pid, state,
// resource usage, timing, and the Run/Workflow it's attributed to.
type ProcessRow = {
  key: string
  id: string
  kind: string | null
  hostname: string
  pid: string | null
  state: string | null
  startedAt: string | null
  lastHeartbeatAt: string | null
  cpu: number | null
  rss: number | null
  runId: string | null
  workflowId: string | null
  outcome: string | null
}

function parseRow(value: unknown, index: number): ProcessRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  const id = displayValue(value.id)
  if (!hostname || !id) return null

  return {
    key: `${id}-${index}`,
    id,
    kind: displayValue(value.kind),
    hostname,
    pid: displayValue(value.pid),
    state: displayValue(value.state),
    startedAt: displayValue(value.started_at),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    cpu: numberValue(value.cpu),
    rss: numberValue(value.rss),
    runId: displayValue(value.run_id),
    workflowId: displayValue(value.workflow_id),
    outcome: displayValue(value.outcome)
  }
}

function processRows(context: ToolCardContext): ProcessRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.processes)) return null

  return parsed.processes.flatMap((process, index) => {
    const row = parseRow(process, index)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = processRows(context)
  if (!rows) return null
  return `${rows.length} process${rows.length === 1 ? "" : "es"}`
}

function StateBadge({ state }: { state: string | null }) {
  if (!state) return <>—</>
  return <StatePill state={state} tone={state === "running" ? "info" : "neutral"} />
}

function renderExpanded(context: ToolCardContext) {
  const state = displayValue(context.input?.state) ?? "running"
  const kind = displayValue(context.input?.kind) ?? "All"
  const limit = displayValue(context.input?.limit) ?? "20"

  const filters = (
    <div className="grid grid-cols-3 gap-2">
      <Row label="State" value={state} />
      <Row label="Kind" value={kind} />
      <Row label="Limit" value={limit} />
    </div>
  )

  if (context.resultError) {
    return (
      <CardShell>
        {filters}
        <EmptyState>Processes could not be loaded.</EmptyState>
        {context.resultBody ? <TextPreview maxLines={4} text={context.resultBody} title="Error details" /> : null}
      </CardShell>
    )
  }

  const rows = processRows(context)
  if (!rows) return null

  if (rows.length === 0)
    return (
      <CardShell>
        {filters}
        <EmptyState>No processes found.</EmptyState>
      </CardShell>
    )

  return (
    <CardShell>
      {filters}
      <Table responsive>
        <THead columns={["ID", "Kind", "Host", "Pid", "State", "CPU", "RSS", "Started", "Heartbeat", "Run", "Workflow", "Outcome"]} />
        <TBody>
          {rows.map((row) => (
            <tr key={row.key}>
              <Td mono primary>
                <EntityReference id={row.id} kind="artifact" wrap="nowrap" />
              </Td>
              <Td>{row.kind || "—"}</Td>
              <Td mono>
                <EntityReference id={row.hostname} kind="artifact" wrap="nowrap" />
              </Td>
              <Td mono>{row.pid || "—"}</Td>
              <Td>
                <StateBadge state={row.state} />
              </Td>
              <Td mono>{formatPercent(row.cpu)}</Td>
              <Td mono>{formatBytesLarge(row.rss)}</Td>
              <Td mono>{row.startedAt || "—"}</Td>
              <Td mono>{row.lastHeartbeatAt || "—"}</Td>
              <Td mono>{row.runId ? <EntityReference href={`/admin/runs/${row.runId}/transcript`} id={row.runId} kind="run" wrap="nowrap" /> : "—"}</Td>
              <Td mono>
                {row.workflowId ? <EntityReference href={`/admin/workflows/${row.workflowId}`} id={row.workflowId} kind="workflow" wrap="nowrap" /> : "—"}
              </Td>
              <Td>{row.outcome || "—"}</Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

const adminListProcessesToolCard: ToolCardRenderer = {
  toolName: "admin_list_processes",
  collapsedSummary,
  renderExpanded
}

export default adminListProcessesToolCard
