import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, numberValue, Row, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_read_operational_logs (the tool-card work /
// Search results can run to dozens of rows of raw log text, so
// the applied filters and count render up front and the actual rows stay
// behind a disclosure -- a friendlier version of the same collapse pattern
// run_command uses for stdout/stderr.
const LOG_PREVIEW_ROW_LIMIT = 50
const MESSAGE_PREVIEW_CHARS = 240

type LogRow = {
  key: string
  occurredAt: string | null
  level: string | null
  role: string | null
  hostname: string | null
  message: string | null
  jobId: string | null
  workflowId: string | null
  runId: string | null
}

type LogsCard =
  { enabled: false; error: string | null; message: string | null } | { enabled: true; retentionSeconds: number | null; count: number | null; logs: LogRow[] }

function parseLogRow(value: unknown, index: number): LogRow | null {
  if (!isPlainObject(value)) return null

  return {
    key: `${displayValue(value.id) ?? index}`,
    occurredAt: displayValue(value.occurred_at),
    level: displayValue(value.level),
    role: displayValue(value.role),
    hostname: displayValue(value.hostname),
    message: displayValue(value.message),
    jobId: displayValue(value.job_id),
    workflowId: displayValue(value.workflow_id),
    runId: displayValue(value.run_id)
  }
}

function parseLogsCard(context: ToolCardContext): LogsCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.enabled !== "boolean") return null

  if (!parsed.enabled) return { enabled: false, error: displayValue(parsed.error), message: displayValue(parsed.message) }

  if (!Array.isArray(parsed.logs)) return null
  return {
    enabled: true,
    retentionSeconds: numberValue(parsed.retention_seconds),
    count: numberValue(parsed.count),
    logs: parsed.logs.flatMap((log, index) => {
      const row = parseLogRow(log, index)
      return row ? [row] : []
    })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseLogsCard(context)
  if (!card) return null
  if (!card.enabled) return "Operational log indexing disabled"

  const count = card.count ?? card.logs.length
  return `${count} log line${count === 1 ? "" : "s"}`
}

function levelTone(level: string | null) {
  const normalized = (level || "").toLowerCase()
  if (normalized === "error" || normalized === "fatal") return "failure" as const
  if (normalized === "warn") return "warning" as const
  if (normalized === "info") return "info" as const
  return "neutral" as const
}

function AppliedFilters({ input }: { input?: Record<string, unknown> }) {
  if (!input) return null

  const entries: Array<[string, string]> = [
    ["query", displayValue(input.query) ?? ""],
    ["level", displayValue(input.level) ?? ""],
    ["role", displayValue(input.role) ?? ""],
    ["hostname", displayValue(input.hostname) ?? ""],
    ["since", displayValue(input.since) ?? ""]
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
  const card = parseLogsCard(context)
  if (!card) return null

  if (!card.enabled) {
    return (
      <CardShell>
        <div className="rounded border border-amber-200 bg-amber-50 px-2 py-1 text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
          {card.message || "Operational log indexing is unavailable."}
        </div>
        {card.error ? <div className="font-mono text-2xs text-gray-500 dark:text-gray-400">{card.error}</div> : null}
      </CardShell>
    )
  }

  const visibleLogs = card.logs.slice(0, LOG_PREVIEW_ROW_LIMIT)
  const omitted = card.logs.length - visibleLogs.length

  return (
    <CardShell>
      <AppliedFilters input={context.input} />
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Rows returned" value={String(card.count ?? card.logs.length)} />
        {card.retentionSeconds != null ? <Row label="Retention" value={`${Math.round(card.retentionSeconds / 3600)}h`} /> : null}
      </dl>
      {card.logs.length === 0 ? (
        <EmptyState>No matching log lines.</EmptyState>
      ) : (
        <Disclosure label={`Log preview (${card.logs.length})`}>
          <div className="max-h-96 overflow-auto">
            <Table>
              <THead columns={["Time", "Level", "Role", "Host", "Message", "Attribution"]} />
              <TBody>
                {visibleLogs.map((log) => (
                  <tr key={log.key}>
                    <Td mono>{log.occurredAt || "—"}</Td>
                    <Td>{log.level ? <StatePill state={log.level} tone={levelTone(log.level)} /> : "—"}</Td>
                    <Td>{log.role || "—"}</Td>
                    <Td mono>{log.hostname || "—"}</Td>
                    <Td maxWidth title={log.message ?? undefined}>
                      {(log.message || "—").length > MESSAGE_PREVIEW_CHARS ? `${log.message!.slice(0, MESSAGE_PREVIEW_CHARS)}…` : log.message || "—"}
                    </Td>
                    <Td mono>
                      {[log.jobId ? `JOB-${log.jobId}` : null, log.workflowId ? `WF-${log.workflowId}` : null, log.runId ? `RUN-${log.runId}` : null]
                        .filter(Boolean)
                        .join(" ") || "—"}
                    </Td>
                  </tr>
                ))}
              </TBody>
            </Table>
          </div>
          {omitted > 0 ? (
            <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">
              Showing first {LOG_PREVIEW_ROW_LIMIT} of {card.logs.length} rows.
            </div>
          ) : null}
        </Disclosure>
      )}
    </CardShell>
  )
}

const adminReadOperationalLogsToolCard: ToolCardRenderer = {
  toolName: "admin_read_operational_logs",
  collapsedSummary,
  renderExpanded
}

export default adminReadOperationalLogsToolCard
