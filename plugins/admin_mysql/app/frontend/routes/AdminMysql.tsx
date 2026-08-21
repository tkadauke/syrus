import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type ReactNode } from "react"
import { killMysqlQuery, fetchAdminMysql, type MysqlProcess, type MysqlSnapshot } from "../api/adminMysql"

export function AdminMysql() {
  const [limit, setLimit] = useState(50)
  const [includeSlowLog, setIncludeSlowLog] = useState(false)
  const queryClient = useQueryClient()
  const mysql = useQuery({
    queryKey: ["admin", "mysql", limit, includeSlowLog],
    queryFn: () => fetchAdminMysql(limit, includeSlowLog),
    refetchInterval: includeSlowLog ? false : 10_000
  })
  const killQuery = useMutation({
    mutationFn: killMysqlQuery,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["admin", "mysql"] })
    }
  })

  function onKill(process: MysqlProcess) {
    if (!window.confirm(`Kill current query for MySQL thread ${process.id}? The connection will stay open.`)) return
    killQuery.mutate(process.id)
  }

  return (
    <main aria-label="MySQL admin" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex flex-wrap items-start justify-between gap-4 border-b border-gray-200 pb-5 dark:border-gray-800">
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">Admin</p>
          <h1 className="mt-1 text-3xl font-semibold text-gray-900 dark:text-gray-100">MySQL</h1>
          <p className="mt-2 max-w-3xl text-sm text-gray-600 dark:text-gray-300">
            Live MySQL state from SHOW commands, information_schema, and Performance Schema. This page does not read Syrus performance logs.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <label className="text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="mysql-limit">Rows</label>
          <select
            className="rounded border border-gray-300 bg-white px-2 py-1 text-sm dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            id="mysql-limit"
            onChange={(event) => setLimit(Number(event.target.value))}
            value={limit}
          >
            {[25, 50, 100, 200].map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
          <button
            className="rounded border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900"
            onClick={() => void mysql.refetch()}
            type="button"
          >
            Refresh
          </button>
        </div>
      </header>

      {mysql.isPending ? <Panel>Loading MySQL state...</Panel> : null}
      {mysql.isError ? <Panel tone="error">{mysql.error instanceof Error ? mysql.error.message : "Failed to load MySQL state"}</Panel> : null}
      {killQuery.isError ? <Panel tone="error">{killQuery.error instanceof Error ? killQuery.error.message : "Failed to kill query"}</Panel> : null}
      {killQuery.data && !killQuery.data.killed ? <Panel tone="error">{killQuery.data.error?.message || "MySQL refused the kill request"}</Panel> : null}
      {killQuery.data?.killed ? <Panel tone="success">Killed query for thread {killQuery.data.thread_id}.</Panel> : null}

      {mysql.data ? (
        <MysqlDashboard
          includeSlowLog={includeSlowLog}
          killingThreadId={killQuery.isPending ? killQuery.variables : null}
          payload={mysql.data}
          onKill={onKill}
          onToggleSlowLog={() => setIncludeSlowLog((value) => !value)}
        />
      ) : null}
    </main>
  )
}

function MysqlDashboard({
  includeSlowLog,
  killingThreadId,
  onKill,
  onToggleSlowLog,
  payload
}: {
  includeSlowLog: boolean
  killingThreadId: number | null
  onKill: (process: MysqlProcess) => void
  onToggleSlowLog: () => void
  payload: MysqlSnapshot
}) {
  const summary = payload.connection_summary
  return (
    <div className="space-y-6">
      <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <MetricCard label="Threads running" value={formatValue(summary.threads_running)} detail={`${formatValue(summary.threads_connected)} connected`} />
        <MetricCard label="Connections used" value={connectionPercent(summary)} detail={`${formatValue(summary.max_used_connections)} max seen / ${formatValue(summary.max_connections)} limit`} />
        <MetricCard label="Sleeping connections" value={formatValue(summary.sleeping_connections)} detail={`wait timeout ${formatValue(summary.wait_timeout)}s`} />
        <MetricCard label="Buffer pool" value={formatBytes(Number(payload.variables.innodb_buffer_pool_size))} detail={`database ${payload.database}`} />
      </section>

      <section className="grid gap-6 xl:grid-cols-2">
        <KeyValuePanel
          title="MySQL variables"
          values={{
            version: payload.variables.version,
            max_connections: payload.variables.max_connections,
            innodb_buffer_pool_size: formatBytes(Number(payload.variables.innodb_buffer_pool_size)),
            innodb_redo_log_capacity: formatBytes(Number(payload.variables.innodb_redo_log_capacity)),
            innodb_flush_log_at_trx_commit: payload.variables.innodb_flush_log_at_trx_commit,
            sync_binlog: payload.variables.sync_binlog,
            slow_query_log: payload.variables.slow_query_log,
            log_output: payload.variables.log_output,
            long_query_time: payload.variables.long_query_time,
            performance_schema: payload.variables.performance_schema
          }}
        />
        <KeyValuePanel
          title="InnoDB and query counters"
          values={{
            Slow_queries: payload.status.Slow_queries,
            Created_tmp_tables: payload.status.Created_tmp_tables,
            Created_tmp_disk_tables: payload.status.Created_tmp_disk_tables,
            Handler_commit: payload.status.Handler_commit,
            Handler_rollback: payload.status.Handler_rollback,
            Innodb_row_lock_current_waits: payload.status.Innodb_row_lock_current_waits,
            Innodb_row_lock_waits: payload.status.Innodb_row_lock_waits,
            Innodb_row_lock_time: payload.status.Innodb_row_lock_time,
            Innodb_data_fsyncs: payload.status.Innodb_data_fsyncs,
            Innodb_os_log_fsyncs: payload.status.Innodb_os_log_fsyncs,
            Innodb_log_waits: payload.status.Innodb_log_waits
          }}
        />
      </section>

      <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">Process list</h2>
          <p className="text-xs text-gray-500 dark:text-gray-400">Generated {new Date(payload.generated_at).toLocaleString()}</p>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-800">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">ID</th>
                <th className="px-4 py-2">Command</th>
                <th className="px-4 py-2">Time</th>
                <th className="px-4 py-2">State</th>
                <th className="px-4 py-2">Host</th>
                <th className="px-4 py-2">Info</th>
                <th className="px-4 py-2">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
              {payload.process_list.map((process) => (
                <tr key={process.id}>
                  <td className="px-4 py-2 font-mono text-gray-800 dark:text-gray-100">{process.id}</td>
                  <td className="px-4 py-2">{process.command}</td>
                  <td className="px-4 py-2">{process.time_seconds}s</td>
                  <td className="px-4 py-2">{process.state || "-"}</td>
                  <td className="px-4 py-2 font-mono text-xs">{process.host}</td>
                  <td className="max-w-2xl truncate px-4 py-2 font-mono text-xs" title={process.info || ""}>{process.info || "-"}</td>
                  <td className="px-4 py-2">
                    {process.command && process.command !== "Sleep" ? (
                      <button
                        className="rounded border border-red-300 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-900 dark:text-red-300 dark:hover:bg-red-950"
                        disabled={killingThreadId === process.id}
                        onClick={() => onKill(process)}
                        type="button"
                      >
                        {killingThreadId === process.id ? "Killing..." : "Kill query"}
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="grid gap-6 xl:grid-cols-2">
        <StatementDigestPanel payload={payload} />
        <SlowLogPanel includeSlowLog={includeSlowLog} payload={payload} onToggleSlowLog={onToggleSlowLog} />
      </section>
    </div>
  )
}

function StatementDigestPanel({ payload }: { payload: MysqlSnapshot }) {
  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <div className="border-b border-gray-200 px-4 py-3 dark:border-gray-800">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">Statement digests</h2>
        <p className="text-xs text-gray-500 dark:text-gray-400">Performance Schema summary ordered by total time.</p>
      </div>
      {!payload.statement_digests.available ? (
        <UnavailablePanel
          fallback="Performance Schema statement digests are unavailable."
          error={payload.statement_digests.error}
        />
      ) : (
        <div className="max-h-[32rem] overflow-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-800">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">Total</th>
                <th className="px-4 py-2">Max</th>
                <th className="px-4 py-2">Count</th>
                <th className="px-4 py-2">Statement</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
              {payload.statement_digests.rows.map((row, index) => (
                <tr key={`${row.digest_text}-${index}`}>
                  <td className="px-4 py-2">{formatSeconds(row.total_seconds)}</td>
                  <td className="px-4 py-2">{formatSeconds(row.max_seconds)}</td>
                  <td className="px-4 py-2">{row.count}</td>
                  <td className="max-w-xl truncate px-4 py-2 font-mono text-xs" title={row.digest_text || ""}>{row.digest_text || "-"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function SlowLogPanel({ includeSlowLog, onToggleSlowLog, payload }: { includeSlowLog: boolean; onToggleSlowLog: () => void; payload: MysqlSnapshot }) {
  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <div className="flex flex-wrap items-start justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
        <div>
          <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">Slow log</h2>
          <p className="text-xs text-gray-500 dark:text-gray-400">
            slow_query_log {String(payload.slow_log.config.slow_query_log || "unknown")} · log_output {String(payload.slow_log.config.log_output || "unknown")} · long_query_time {String(payload.slow_log.config.long_query_time || "unknown")}s
          </p>
        </div>
        <button
          className="rounded border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900"
          onClick={onToggleSlowLog}
          type="button"
        >
          {includeSlowLog ? "Hide slow log rows" : "Load slow log rows"}
        </button>
      </div>
      {!payload.slow_log.available ? (
        <UnavailablePanel fallback="Slow log rows are unavailable." error={payload.slow_log.error} />
      ) : (
        <div className="max-h-[32rem] overflow-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-800">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">Time</th>
                <th className="px-4 py-2">Query time</th>
                <th className="px-4 py-2">Rows examined</th>
                <th className="px-4 py-2">SQL</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
              {payload.slow_log.rows.map((row, index) => (
                <tr key={`${row.start_time}-${index}`}>
                  <td className="px-4 py-2">{row.start_time ? new Date(row.start_time).toLocaleString() : "-"}</td>
                  <td className="px-4 py-2">{row.query_time}</td>
                  <td className="px-4 py-2">{row.rows_examined}</td>
                  <td className="max-w-xl truncate px-4 py-2 font-mono text-xs" title={row.sql_text || ""}>{row.sql_text || "-"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function UnavailablePanel({ error, fallback }: { error?: { message: string; hint?: string; setup_sql?: string[] }; fallback: string }) {
  return (
    <div className="space-y-3 p-4">
      <Panel>
        <div className="space-y-2">
          <p className="font-medium text-gray-900 dark:text-gray-100">{error?.message || fallback}</p>
          {error?.hint ? <p>{error.hint}</p> : null}
          {error?.setup_sql?.length ? (
            <pre className="overflow-x-auto rounded bg-gray-100 p-3 font-mono text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-100">
              {error.setup_sql.join("\n")}
            </pre>
          ) : null}
        </div>
      </Panel>
    </div>
  )
}

function KeyValuePanel({ title, values }: { title: string; values: Record<string, unknown> }) {
  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <h2 className="border-b border-gray-200 px-4 py-3 text-lg font-semibold text-gray-900 dark:border-gray-800 dark:text-gray-100">{title}</h2>
      <dl className="grid grid-cols-1 gap-px bg-gray-100 text-sm dark:bg-gray-800 sm:grid-cols-2">
        {Object.entries(values).map(([key, value]) => (
          <div className="bg-white px-4 py-3 dark:bg-gray-950" key={key}>
            <dt className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{key}</dt>
            <dd className="mt-1 break-all font-mono text-gray-900 dark:text-gray-100">{formatValue(value)}</dd>
          </div>
        ))}
      </dl>
    </section>
  )
}

function MetricCard({ detail, label, value }: { detail: string; label: string; value: string }) {
  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-950">
      <p className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</p>
      <p className="mt-2 text-2xl font-semibold text-gray-900 dark:text-gray-100">{value}</p>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{detail}</p>
    </section>
  )
}

function Panel({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "error" | "success" }) {
  const classes = tone === "error"
    ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
    : tone === "success"
      ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-gray-200 bg-white text-gray-700 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-200"
  return <div className={`rounded border px-4 py-3 text-sm ${classes}`}>{children}</div>
}

function connectionPercent(summary: MysqlSnapshot["connection_summary"]) {
  if (!summary.threads_connected || !summary.max_connections) return "-"
  return `${Math.round((summary.threads_connected / summary.max_connections) * 100)}%`
}

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return "-"
  const units = ["B", "KiB", "MiB", "GiB", "TiB"]
  let current = value
  let index = 0
  while (current >= 1024 && index < units.length - 1) {
    current /= 1024
    index += 1
  }
  return `${current.toFixed(index === 0 ? 0 : 1)} ${units[index]}`
}

function formatSeconds(value: number | null) {
  if (value == null) return "-"
  return `${value.toFixed(value >= 10 ? 1 : 3)}s`
}

function formatValue(value: unknown) {
  if (value == null || value === "") return "-"
  return String(value)
}

export default AdminMysql
