import type { ReactNode } from "react"
import { useT } from "@app/hooks/useT"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, numberValue, Row, SectionLabel, StatePill, truncateLines } from "@app/routes/chat/toolCardUi"

type HealthState = "healthy" | "degraded" | "unavailable" | "error"
type MysqlError = { className: string | null; message: string | null; hint: string | null }

type ConnectionSummary = {
  activeQueries: number
  threadsConnected: number | null
  threadsRunning: number | null
  sleepingConnections: number | null
  maxUsedConnections: number | null
  maxConnections: number | null
  abortedConnects: number | null
  maxConnectionErrors: number | null
  waitTimeout: number | null
  interactiveTimeout: number | null
}
type ProcessRow = {
  id: string
  command: string | null
  timeSeconds: number | null
  state: string | null
  info: string | null
  lockedOrWaiting: boolean
}

type StatementDigestRow = {
  text: string
  count: number | null
  totalSeconds: number | null
  avgSeconds: number | null
  maxSeconds: number | null
  rowsExamined: number | null
}

type SlowSqlEventRow = {
  occurredAt: string | null
  durationMs: number | null
  source: string | null
  sql: string | null
}

type SectionSummary<T> = { available: true; rows: T[]; error: null } | { available: false; rows: T[]; error: MysqlError | null }

type StatusPayload = {
  available: boolean
  generatedAt: string | null
  health: HealthState
  connection: ConnectionSummary
  variables: Record<string, unknown>
  status: Record<string, unknown>
  processes: ProcessRow[]
  statementDigests: SectionSummary<StatementDigestRow>
  slowSqlEvents: SectionSummary<SlowSqlEventRow>
  error: MysqlError | null
}

function integer(value: unknown): number | null {
  return numberValue(value)
}

function parseMysqlError(value: unknown): MysqlError | null {
  if (!isPlainObject(value)) return null

  return {
    className: displayValue(value.class),
    message: displayValue(value.message),
    hint: displayValue(value.hint)
  }
}

function MysqlErrorNotice({ error }: { error: MysqlError }) {
  const { t } = useT("admin_mysql")
  return (
    <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
      <div className="font-mono">{error.message ?? error.className ?? t("tool_unknown_mysql_error")}</div>
      {error.hint ? <div className="mt-1 text-red-600 dark:text-red-400">{error.hint}</div> : null}
    </div>
  )
}

function TableShell({ children }: { children: ReactNode }) {
  return <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">{children}</div>
}

function TruncatedNotice({ label }: { label: string }) {
  const { t } = useT("admin_mysql")
  return <div className="text-2xs text-gray-500 dark:text-gray-400">{t("tool_truncated_notice", { label })}</div>
}

function seconds(value: number | null): string {
  if (value == null) return "-"
  if (value < 60) return `${value}s`
  if (value < 3600) return `${Math.floor(value / 60)}m ${value % 60}s`
  return `${Math.floor(value / 3600)}h ${Math.floor((value % 3600) / 60)}m`
}

function decimal(value: number | null, suffix = "s"): string {
  if (value == null) return "-"
  return `${value.toFixed(value >= 10 ? 1 : 3).replace(/\.?0+$/, "")}${suffix}`
}

function shortText(text: string, maxChars = 160): { preview: string; truncated: boolean } {
  if (text.length <= maxChars) return { preview: text, truncated: false }
  return { preview: `${text.slice(0, maxChars).trimEnd()}...`, truncated: true }
}

function processLockedOrWaiting(state: string | null, info: string | null) {
  const text = `${state ?? ""} ${info ?? ""}`.toLowerCase()
  return /\block|\blocked|\bwait|\bwaiting|\bmetadata lock|\btable lock/.test(text)
}

function parseConnectionSummary(value: unknown, processes: ProcessRow[]): ConnectionSummary {
  const summary = isPlainObject(value) ? value : {}
  const activeQueries = processes.filter((process) => !["sleep", "binlog dump"].includes((process.command ?? "").toLowerCase())).length

  return {
    activeQueries,
    threadsConnected: integer(summary.threads_connected),
    threadsRunning: integer(summary.threads_running),
    sleepingConnections: integer(summary.sleeping_connections),
    maxUsedConnections: integer(summary.max_used_connections),
    maxConnections: integer(summary.max_connections),
    abortedConnects: integer(summary.aborted_connects),
    maxConnectionErrors: integer(summary.max_connection_errors),
    waitTimeout: integer(summary.wait_timeout),
    interactiveTimeout: integer(summary.interactive_timeout)
  }
}

function parseProcess(value: unknown): ProcessRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  const state = displayValue(value.state)
  const info = displayValue(value.info)
  return {
    id,
    command: displayValue(value.command),
    timeSeconds: integer(value.time_seconds),
    state,
    info,
    lockedOrWaiting: processLockedOrWaiting(state, info)
  }
}

function parseDigest(value: unknown): StatementDigestRow | null {
  if (!isPlainObject(value)) return null
  const text = displayValue(value.digest_text)
  if (!text) return null

  return {
    text,
    count: integer(value.count),
    totalSeconds: numberValue(value.total_seconds),
    avgSeconds: numberValue(value.avg_seconds),
    maxSeconds: numberValue(value.max_seconds),
    rowsExamined: integer(value.rows_examined)
  }
}

function parseSlowSqlEvent(value: unknown): SlowSqlEventRow | null {
  if (!isPlainObject(value)) return null
  return {
    occurredAt: displayValue(value.occurred_at),
    durationMs: numberValue(value.duration_ms),
    source: displayValue(value.controller) ?? displayValue(value.job_class) ?? displayValue(value.phase) ?? displayValue(value.name),
    sql: displayValue(value.sql)
  }
}

function parseSection<T>(value: unknown, parseRow: (row: unknown) => T | null): SectionSummary<T> {
  if (!isPlainObject(value)) return { available: false, rows: [], error: null }
  const rows = Array.isArray(value.rows)
    ? value.rows.flatMap((row) => {
        const parsed = parseRow(row)
        return parsed ? [parsed] : []
      })
    : []

  return value.available === true ? { available: true, rows, error: null } : { available: false, rows, error: parseMysqlError(value.error) }
}

function statusHealth(payload: {
  available: boolean
  error: MysqlError | null
  processes: ProcessRow[]
  statementDigests: SectionSummary<StatementDigestRow>
  slowSqlEvents: SectionSummary<SlowSqlEventRow>
  status: Record<string, unknown>
}): HealthState {
  if (payload.error) return "error"
  if (!payload.available) return "unavailable"
  if (payload.processes.some((process) => process.lockedOrWaiting)) return "degraded"
  const rowLockWaits = integer(payload.status.Innodb_row_lock_current_waits)
  if (rowLockWaits != null && rowLockWaits > 0) return "degraded"
  if (payload.statementDigests.available === false) return "degraded"
  if (payload.slowSqlEvents.available === false) return "degraded"
  return "healthy"
}

export function parseStatusPayload(context: ToolCardContext): StatusPayload | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.available !== "boolean") return null

  const processes = Array.isArray(parsed.process_list)
    ? parsed.process_list.flatMap((row) => {
        const process = parseProcess(row)
        return process ? [process] : []
      })
    : []
  const status = isPlainObject(parsed.status) ? parsed.status : {}
  const payload = {
    available: parsed.available,
    generatedAt: displayValue(parsed.generated_at),
    connection: parseConnectionSummary(parsed.connection_summary, processes),
    variables: isPlainObject(parsed.variables) ? parsed.variables : {},
    status,
    processes,
    statementDigests: parseSection(parsed.statement_digests, parseDigest),
    slowSqlEvents: parseSection(parsed.slow_sql_events, parseSlowSqlEvent),
    error: parseMysqlError(parsed.error)
  }

  return { ...payload, health: statusHealth(payload) }
}

function healthTone(health: HealthState): "success" | "warning" | "failure" | "neutral" {
  if (health === "healthy") return "success"
  if (health === "degraded") return "warning"
  if (health === "error") return "failure"
  return "neutral"
}

export function statusSummary(context: ToolCardContext): string | null {
  if (context.resultError && !isPlainObject(context.parsedResult)) return "MySQL status failed"

  const payload = parseStatusPayload(context)
  if (!payload) return null

  const slowCount = payload.slowSqlEvents.rows.length
  const lockedCount = payload.processes.filter((process) => process.lockedOrWaiting).length
  const fragments = [`${payload.health}`, `${payload.connection.activeQueries} active`]
  if (slowCount > 0) fragments.push(`${slowCount} slow`)
  if (lockedCount > 0) fragments.push(`${lockedCount} waiting`)
  return `MySQL ${fragments.join(" · ")}`
}

function StatusErrorBody({ context }: { context: ToolCardContext }) {
  const { t } = useT("admin_mysql")
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="error" tone="failure" />
        <span className="font-medium text-gray-900 dark:text-gray-100">{t("tool_status_failed")}</span>
      </div>
      <div className="whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{context.resultBody}</div>
    </CardShell>
  )
}

function QueryPreview({ text }: { text: string }) {
  const { t } = useT("admin_mysql")
  const { preview, truncated } = shortText(text)
  const lines = truncateLines(text, 6)
  return (
    <div>
      <div className="whitespace-pre-wrap break-words font-mono">{preview}</div>
      {truncated || lines.truncated ? (
        <Disclosure label={t("tool_show_full_payload", { count: lines.totalLines })}>
          <div className="whitespace-pre-wrap break-words font-mono">{text}</div>
        </Disclosure>
      ) : null}
    </div>
  )
}

function ProcessTable({ rows }: { rows: ProcessRow[] }) {
  const { t } = useT("admin_mysql")
  if (rows.length === 0) return <EmptyState>{t("tool_no_active_processes")}</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">
              {t("tool_thread")}
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              {t("col_command")}
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              {t("col_time")}
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              {t("col_state")}
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              {t("tool_query")}
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-700 dark:text-gray-300">#{row.id}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-700 dark:text-gray-300">{row.command ?? "-"}</td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-700 dark:text-gray-300">{seconds(row.timeSeconds)}</td>
              <td className="px-2 py-1 text-gray-700 dark:text-gray-300">
                <div className="flex flex-wrap items-center gap-1">
                  {row.lockedOrWaiting ? <StatePill state="waiting" tone="warning" /> : null}
                  <span>{row.state ?? "-"}</span>
                </div>
              </td>
              <td className="max-w-[22rem] px-2 py-1 text-gray-700 dark:text-gray-300">{row.info ? <QueryPreview text={row.info} /> : "-"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableShell>
  )
}

function DigestSummary({ section }: { section: SectionSummary<StatementDigestRow> }) {
  const { t } = useT("admin_mysql")
  if (!section.available) {
    return section.error ? (
      <MysqlErrorNotice error={section.error} />
    ) : (
      <div className="text-gray-500 dark:text-gray-400">{t("tool_statement_digests_unavailable")}</div>
    )
  }
  if (section.rows.length === 0) return <div className="text-gray-500 dark:text-gray-400">{t("tool_no_statement_digests")}</div>

  return (
    <div className="space-y-1">
      {section.rows.slice(0, 3).map((row, index) => (
        <div className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={`${row.text}-${index}`}>
          <div className="mb-1 flex flex-wrap gap-2 text-2xs text-gray-500 dark:text-gray-400">
            <Badge>{t("tool_run_count", { count: row.count ?? 0 })}</Badge>
            <Badge>{t("tool_total_value", { value: decimal(row.totalSeconds) })}</Badge>
            <Badge>{t("tool_avg_value", { value: decimal(row.avgSeconds) })}</Badge>
            <Badge>{t("tool_max_value", { value: decimal(row.maxSeconds) })}</Badge>
            {row.rowsExamined != null ? <Badge>{t("tool_rows_examined", { count: row.rowsExamined })}</Badge> : null}
          </div>
          <QueryPreview text={row.text} />
        </div>
      ))}
      {section.rows.length > 3 ? <TruncatedNotice label={t("tool_statement_digest_preview")} /> : null}
    </div>
  )
}

function SlowSqlSummary({ section }: { section: SectionSummary<SlowSqlEventRow> }) {
  const { t } = useT("admin_mysql")
  if (!section.available) {
    return section.error ? <MysqlErrorNotice error={section.error} /> : <div className="text-gray-500 dark:text-gray-400">{t("tool_slow_sql_unavailable")}</div>
  }
  if (section.rows.length === 0) return <div className="text-gray-500 dark:text-gray-400">{t("tool_no_slow_sql_events")}</div>

  return (
    <div className="space-y-1">
      {section.rows.slice(0, 3).map((row, index) => (
        <div className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={`${row.occurredAt ?? "slow"}-${index}`}>
          <div className="mb-1 flex flex-wrap gap-2 text-2xs text-gray-500 dark:text-gray-400">
            {row.durationMs != null ? <Badge>{decimal(row.durationMs, "ms")}</Badge> : null}
            {row.source ? <Badge>{row.source}</Badge> : null}
            {row.occurredAt ? <Badge>{row.occurredAt}</Badge> : null}
          </div>
          {row.sql ? <QueryPreview text={row.sql} /> : <div className="text-gray-500 dark:text-gray-400">{t("tool_no_sql_text")}</div>}
        </div>
      ))}
      {section.rows.length > 3 ? <TruncatedNotice label={t("tool_slow_sql_preview")} /> : null}
    </div>
  )
}

function VariableBadge({ label, value }: { label: string; value: unknown }) {
  const text = displayValue(value)
  return text ? (
    <Badge>
      {label}: {text}
    </Badge>
  ) : null
}

export function StatusCard({ context }: { context: ToolCardContext }) {
  const { t } = useT("admin_mysql")
  if (context.resultError && !isPlainObject(context.parsedResult)) return <StatusErrorBody context={context} />

  const payload = parseStatusPayload(context)
  if (!payload) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={payload.health} tone={healthTone(payload.health)} />
        {payload.generatedAt ? <Badge>{payload.generatedAt}</Badge> : null}
        <VariableBadge label={t("tool_slow_query_log")} value={payload.variables.slow_query_log} />
        <VariableBadge label={t("tool_long_query_time")} value={payload.variables.long_query_time} />
      </div>
      {payload.error ? <MysqlErrorNotice error={payload.error} /> : null}
      <dl className="grid gap-1 sm:grid-cols-3">
        <Row label={t("tool_active_queries")} value={String(payload.connection.activeQueries)} />
        <Row label={t("tool_threads_connected")} value={payload.connection.threadsConnected?.toString() ?? "-"} />
        <Row label={t("metric_threads_running")} value={payload.connection.threadsRunning?.toString() ?? "-"} />
        <Row label={t("tool_sleeping")} value={payload.connection.sleepingConnections?.toString() ?? "-"} />
        <Row label={t("tool_max_used_connections")} value={payload.connection.maxUsedConnections?.toString() ?? "-"} />
        <Row label={t("tool_max_connections")} value={payload.connection.maxConnections?.toString() ?? "-"} />
        <Row label={t("tool_wait_timeout")} value={seconds(payload.connection.waitTimeout)} />
        <Row label={t("tool_interactive_timeout")} value={seconds(payload.connection.interactiveTimeout)} />
        <Row label={t("tool_slow_queries")} value={displayValue(payload.status.Slow_queries) ?? "-"} />
      </dl>
      <div>
        <SectionLabel>{t("process_list")}</SectionLabel>
        <ProcessTable rows={payload.processes.slice(0, 8)} />
      </div>
      <div>
        <SectionLabel>{t("slow_sql_events")}</SectionLabel>
        <SlowSqlSummary section={payload.slowSqlEvents} />
      </div>
      <div>
        <SectionLabel>{t("statement_digests")}</SectionLabel>
        <DigestSummary section={payload.statementDigests} />
      </div>
    </CardShell>
  )
}
