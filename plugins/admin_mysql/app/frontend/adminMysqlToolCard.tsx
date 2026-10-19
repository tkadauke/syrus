import { useState, type ReactNode } from "react"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Button, DataTable, Notice, Surface, Text } from "@app/components/ui"
import { Table, TBody, Td, THead } from "@app/routes/chat/adminToolCard"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { redactToolCardText } from "@app/toolCardSecurity"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"

type HealthState = "healthy" | "degraded" | "unavailable" | "error"
type MysqlError = { className: string | null; message: string | null; hint: string | null; setupSql: string[] }

type ConnectionSummary = {
  activeQueries: number
  threadsConnected: number | null
  threadsRunning: number | null
  sleepingConnections: number | null
  maxConnections: number | null
  abortedConnects: number | null
  maxConnectionErrors: number | null
}
type ProcessRow = {
  id: string
  user: string | null
  host: string | null
  database: string | null
  command: string | null
  timeSeconds: number | null
  state: string | null
  info: string | null
  lockedOrWaiting: boolean
}

type StatementDigestRow = {
  text: string
  schemaName: string | null
  count: number | null
  totalSeconds: number | null
  avgSeconds: number | null
  maxSeconds: number | null
  rowsExamined: number | null
  rowsSent: number | null
  firstSeen: string | null
  lastSeen: string | null
}

type SlowLogRow = {
  startTime: string | null
  userHost: string | null
  queryTime: string | null
  lockTime: string | null
  rowsSent: number | null
  rowsExamined: number | null
  database: string | null
  sqlText: string | null
}

type SectionSummary<T> = { available: true; rows: T[]; error: null } | { available: false; rows: T[]; error: MysqlError | null }

type StatusPayload = {
  available: boolean
  generatedAt: string | null
  adapter: string | null
  database: string | null
  health: HealthState
  connection: ConnectionSummary
  variables: Record<string, unknown>
  status: Record<string, unknown>
  processes: ProcessRow[]
  statementDigests: SectionSummary<StatementDigestRow>
  slowLog: SectionSummary<SlowLogRow>
  error: MysqlError | null
}

function integer(value: unknown): number | null {
  return numberValue(value)
}

function parseMysqlError(value: unknown): MysqlError | null {
  if (!isPlainObject(value)) return null

  return {
    className: redact(displayValue(value.class)),
    message: redact(displayValue(value.message)),
    hint: redact(displayValue(value.hint)),
    setupSql: Array.isArray(value.setup_sql)
      ? value.setup_sql.flatMap((sql) => {
          const text = redact(displayValue(sql))
          return text ? [text] : []
        })
      : []
  }
}

function MysqlErrorNotice({ error }: { error: MysqlError }) {
  return (
    <Notice contentClassName="space-y-1" tone="danger">
      <div className="font-mono">{error.message ?? error.className ?? "Unknown error"}</div>
      {error.className && error.message ? <div className="font-mono text-xs">{error.className}</div> : null}
      {error.hint ? <div>{error.hint}</div> : null}
      {error.setupSql.length > 0 ? <TextPreview modalLabel="Setup SQL" text={error.setupSql.join("\n")} /> : null}
    </Notice>
  )
}

function redact(value: string | null): string | null {
  return value == null ? null : redactToolCardText(value)
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
    maxConnections: integer(summary.max_connections),
    abortedConnects: integer(summary.aborted_connects),
    maxConnectionErrors: integer(summary.max_connection_errors)
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
    user: redact(displayValue(value.user)),
    host: redact(displayValue(value.host)),
    database: redact(displayValue(value.database)),
    command: displayValue(value.command),
    timeSeconds: integer(value.time_seconds),
    state,
    info: redact(info),
    lockedOrWaiting: processLockedOrWaiting(state, info)
  }
}

function parseDigest(value: unknown): StatementDigestRow | null {
  if (!isPlainObject(value)) return null
  const text = displayValue(value.digest_text)
  if (!text) return null

  return {
    text: redact(text)!,
    schemaName: redact(displayValue(value.schema_name)),
    count: integer(value.count),
    totalSeconds: numberValue(value.total_seconds),
    avgSeconds: numberValue(value.avg_seconds),
    maxSeconds: numberValue(value.max_seconds),
    rowsExamined: integer(value.rows_examined),
    rowsSent: integer(value.rows_sent),
    firstSeen: displayValue(value.first_seen),
    lastSeen: displayValue(value.last_seen)
  }
}

function parseSlowLogRow(value: unknown): SlowLogRow | null {
  if (!isPlainObject(value)) return null
  const sqlText = displayValue(value.sql_text)

  return {
    startTime: displayValue(value.start_time),
    userHost: redact(displayValue(value.user_host)),
    queryTime: displayValue(value.query_time),
    lockTime: displayValue(value.lock_time),
    rowsSent: integer(value.rows_sent),
    rowsExamined: integer(value.rows_examined),
    database: redact(displayValue(value.database)),
    sqlText: redact(sqlText)
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

function slowLogDeferred(section: SectionSummary<SlowLogRow>) {
  return section.available === false && section.error?.message === "slow-log rows are loaded on demand"
}

function statusHealth(payload: {
  available: boolean
  error: MysqlError | null
  processes: ProcessRow[]
  statementDigests: SectionSummary<StatementDigestRow>
  slowLog: SectionSummary<SlowLogRow>
  status: Record<string, unknown>
}): HealthState {
  if (payload.error) return "error"
  if (!payload.available) return "unavailable"
  if (payload.processes.some((process) => process.lockedOrWaiting)) return "degraded"
  const rowLockWaits = integer(payload.status.Innodb_row_lock_current_waits)
  if (rowLockWaits != null && rowLockWaits > 0) return "degraded"
  if (payload.statementDigests.available === false) return "degraded"
  if (payload.slowLog.available === false && !slowLogDeferred(payload.slowLog)) return "degraded"
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
    adapter: displayValue(parsed.adapter),
    database: redact(displayValue(parsed.database)),
    connection: parseConnectionSummary(parsed.connection_summary, processes),
    variables: isPlainObject(parsed.variables) ? parsed.variables : {},
    status,
    processes,
    statementDigests: parseSection(parsed.statement_digests, parseDigest),
    slowLog: parseSection(parsed.slow_log, parseSlowLogRow),
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

  const slowCount = payload.slowLog.rows.length
  const lockedCount = payload.processes.filter((process) => process.lockedOrWaiting).length
  const fragments = [`${payload.health}`, `${payload.connection.activeQueries} active`]
  if (slowCount > 0) fragments.push(`${slowCount} slow`)
  if (lockedCount > 0) fragments.push(`${lockedCount} waiting`)
  return `MySQL ${fragments.join(" · ")}`
}

function StatusErrorBody({ context }: { context: ToolCardContext }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="error" tone="failure" />
        <Text as="span" className="font-medium">
          MySQL status failed
        </Text>
      </div>
      <Text as="div" className="whitespace-pre-wrap break-words">
        {redactToolCardText(context.resultBody)}
      </Text>
    </CardShell>
  )
}

function QueryPreview({ text }: { text: string }) {
  return <TextPreview modalLabel="SQL text" text={redactToolCardText(text)} />
}

function ProcessTable({ rows }: { rows: ProcessRow[] }) {
  if (rows.length === 0) return <EmptyState>No active MySQL process rows returned.</EmptyState>

  return (
    <Table responsive>
      <THead columns={["Thread", "User", "Host", "Database", "Command", "Time", "State", "Query"]} />
      <TBody>
        {rows.map((row) => (
          <DataTable.Row key={row.id}>
            <Td mono>
              <EntityReference id={row.id} kind="artifact" label={`#${row.id}`} slug={row.id} />
            </Td>
            <Td>{row.user ?? "-"}</Td>
            <Td>{row.host ?? "-"}</Td>
            <Td>{row.database ?? "-"}</Td>
            <Td>{row.command ?? "-"}</Td>
            <Td mono>{seconds(row.timeSeconds)}</Td>
            <Td wrap>
              <div className="flex flex-wrap items-center gap-1">
                {row.lockedOrWaiting ? <StatePill state="waiting" tone="warning" /> : null}
                <span>{row.state ?? "-"}</span>
              </div>
            </Td>
            <Td maxWidth wrap>
              {row.info ? <QueryPreview text={row.info} /> : "-"}
            </Td>
          </DataTable.Row>
        ))}
      </TBody>
    </Table>
  )
}

function ExpandableRows<T>({ children, rows, initial = 3 }: { children: (rows: T[]) => ReactNode; rows: T[]; initial?: number }) {
  const [showAll, setShowAll] = useState(false)
  return (
    <div className="space-y-2">
      {children(showAll ? rows : rows.slice(0, initial))}
      {rows.length > initial ? (
        <Button onClick={() => setShowAll((value) => !value)} size="sm" variant="secondary">
          {showAll ? "Show less" : `Show all (${rows.length})`}
        </Button>
      ) : null}
    </div>
  )
}

function DigestSummary({ section }: { section: SectionSummary<StatementDigestRow> }) {
  if (!section.available && section.rows.length === 0)
    return section.error ? <MysqlErrorNotice error={section.error} /> : <EmptyState>Statement digests unavailable.</EmptyState>
  if (section.rows.length === 0) return <EmptyState>No statement digest rows returned.</EmptyState>

  return (
    <div className="space-y-2">
      {!section.available && section.error ? <MysqlErrorNotice error={section.error} /> : null}
      <ExpandableRows rows={section.rows}>
        {(rows) => (
          <div className="space-y-1">
            {rows.map((row, index) => (
              <Surface padding="sm" variant="inset" key={`${row.text}-${index}`}>
                <div className="mb-1 flex flex-wrap gap-2">
                  {row.schemaName ? <Badge>schema: {row.schemaName}</Badge> : null}
                  <Badge>{row.count ?? 0} runs</Badge>
                  <Badge>{decimal(row.totalSeconds)} total</Badge>
                  <Badge>{decimal(row.avgSeconds)} avg</Badge>
                  <Badge>{decimal(row.maxSeconds)} max</Badge>
                  {row.rowsExamined != null ? <Badge>{row.rowsExamined} rows examined</Badge> : null}
                  {row.rowsSent != null ? <Badge>{row.rowsSent} rows sent</Badge> : null}
                  {row.firstSeen ? <Badge>first: {row.firstSeen}</Badge> : null}
                  {row.lastSeen ? <Badge>last: {row.lastSeen}</Badge> : null}
                </div>
                <QueryPreview text={row.text} />
              </Surface>
            ))}
          </div>
        )}
      </ExpandableRows>
    </div>
  )
}

function SlowLogSummary({ section }: { section: SectionSummary<SlowLogRow> }) {
  if (!section.available && section.rows.length === 0) {
    if (slowLogDeferred(section)) {
      return (
        <Notice>
          <div className="font-mono">{section.error?.message}</div>
          {section.error?.hint ? <div className="mt-1">{section.error.hint}</div> : null}
        </Notice>
      )
    }
    return section.error ? <MysqlErrorNotice error={section.error} /> : <EmptyState>Slow-log rows unavailable.</EmptyState>
  }
  if (section.rows.length === 0) return <EmptyState>No slow-log rows returned.</EmptyState>

  return (
    <div className="space-y-1">
      {!section.available && section.error ? <MysqlErrorNotice error={section.error} /> : null}
      <ExpandableRows rows={section.rows}>
        {(rows) => (
          <div className="space-y-1">
            {rows.map((row, index) => (
              <Surface padding="sm" variant="inset" key={`${row.startTime ?? "slow"}-${index}`}>
                <div className="mb-1 flex flex-wrap gap-2">
                  {row.queryTime ? <Badge>{row.queryTime} query</Badge> : null}
                  {row.lockTime ? <Badge>{row.lockTime} lock</Badge> : null}
                  {row.rowsSent != null ? <Badge>{row.rowsSent} rows sent</Badge> : null}
                  {row.rowsExamined != null ? <Badge>{row.rowsExamined} rows examined</Badge> : null}
                  {row.database ? <Badge>database: {row.database}</Badge> : null}
                  {row.userHost ? <Badge>user: {row.userHost}</Badge> : null}
                  {row.startTime ? <Badge>{row.startTime}</Badge> : null}
                </div>
                {row.sqlText ? <QueryPreview text={row.sqlText} /> : <Text tone="muted">No SQL text.</Text>}
              </Surface>
            ))}
          </div>
        )}
      </ExpandableRows>
    </div>
  )
}

function VariableBadge({ label, value }: { label: string; value: unknown }) {
  const displayed = displayValue(value)
  const serialized = JSON.stringify(value)
  const text = displayed ?? (typeof value === "boolean" || value == null ? String(value) : serialized ? redactToolCardText(serialized) : String(value))
  return (
    <Badge>
      {label}: {text}
    </Badge>
  )
}

export function StatusCard({ context }: { context: ToolCardContext }) {
  if (context.resultError && !isPlainObject(context.parsedResult)) return <StatusErrorBody context={context} />

  const payload = parseStatusPayload(context)
  if (!payload) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={payload.health} tone={healthTone(payload.health)} />
        {payload.generatedAt ? <Badge>{payload.generatedAt}</Badge> : null}
        {Object.entries(context.input ?? {}).map(([key, value]) => (
          <VariableBadge key={key} label={key} value={value} />
        ))}
      </div>
      {payload.error ? <MysqlErrorNotice error={payload.error} /> : null}
      <dl className="grid gap-1 sm:grid-cols-3">
        <Row label="Adapter" value={payload.adapter ?? "-"} />
        <Row label="Database" value={payload.database ?? "-"} />
        <Row label="Active queries" value={String(payload.connection.activeQueries)} />
        <Row label="Threads connected" value={payload.connection.threadsConnected?.toString() ?? "-"} />
        <Row label="Threads running" value={payload.connection.threadsRunning?.toString() ?? "-"} />
        <Row label="Sleeping" value={payload.connection.sleepingConnections?.toString() ?? "-"} />
        <Row label="Max connections" value={payload.connection.maxConnections?.toString() ?? "-"} />
        <Row label="Aborted connects" value={payload.connection.abortedConnects?.toString() ?? "-"} />
        <Row label="Max connection errors" value={payload.connection.maxConnectionErrors?.toString() ?? "-"} />
        <Row label="Slow queries" value={displayValue(payload.status.Slow_queries) ?? "-"} />
      </dl>
      <KeyValueSection label="Variables" values={payload.variables} />
      <KeyValueSection label="Status" values={payload.status} />
      <div>
        <SectionLabel>Process list</SectionLabel>
        <ExpandableRows initial={8} rows={payload.processes}>
          {(rows) => <ProcessTable rows={rows} />}
        </ExpandableRows>
      </div>
      <div>
        <SectionLabel>Slow queries and log</SectionLabel>
        <SlowLogSummary section={payload.slowLog} />
      </div>
      <div>
        <SectionLabel>Statement digests</SectionLabel>
        <DigestSummary section={payload.statementDigests} />
      </div>
    </CardShell>
  )
}

function KeyValueSection({ label, values }: { label: string; values: Record<string, unknown> }) {
  const entries = Object.entries(values)
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      {entries.length === 0 ? (
        <EmptyState>No {label.toLowerCase()} returned.</EmptyState>
      ) : (
        <div className="mt-1 flex flex-wrap gap-1">
          {entries.map(([key, value]) => (
            <VariableBadge key={key} label={key} value={value} />
          ))}
        </div>
      )}
    </div>
  )
}
