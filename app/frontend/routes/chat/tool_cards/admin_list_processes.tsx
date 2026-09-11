import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, numberValue, StatePill } from "../toolCardUi"
import { formatBytesLarge, formatPercent, Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_list_processes (the tool-card work).
// Renders SpawnedProcess rows as a dense ops table: kind, host/pid, state,
// resource usage, timing, and the Run/Workflow it's attributed to.
type ProcessRow = {
  key: string
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
  if (!hostname) return null

  return {
    key: `${displayValue(value.id) ?? index}`,
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
  const rows = processRows(context)
  if (!rows) return null

  if (rows.length === 0) return <EmptyState>No processes found.</EmptyState>

  return (
    <CardShell>
      <Table>
        <THead columns={["Kind", "Host", "Pid", "State", "CPU", "RSS", "Started", "Heartbeat", "Run/Workflow", "Outcome"]} />
        <TBody>
          {rows.map((row) => (
            <tr key={row.key}>
              <Td>{row.kind || "—"}</Td>
              <Td mono>{row.hostname}</Td>
              <Td mono>{row.pid || "—"}</Td>
              <Td>
                <StateBadge state={row.state} />
              </Td>
              <Td mono>{formatPercent(row.cpu)}</Td>
              <Td mono>{formatBytesLarge(row.rss)}</Td>
              <Td mono>{row.startedAt || "—"}</Td>
              <Td mono>{row.lastHeartbeatAt || "—"}</Td>
              <Td mono>{row.runId ? `RUN-${row.runId}` : row.workflowId ? `WF-${row.workflowId}` : "—"}</Td>
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
