import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type ReactNode } from "react"
import { Checkbox } from "@app/components/Checkbox"
import { Button, Notice, Page, PageHeading, Section, SectionHeading, Text, Toolbar } from "@app/components/ui"
import { useConfirm } from "@app/hooks/useConfirm"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { killMysqlQuery, fetchAdminMysql, type MysqlProcess, type MysqlSnapshot } from "../api/adminMysql"

export function AdminMysql() {
  const { t } = useT("admin_mysql")
  usePageTitle(t("page_title"))
  const [limit, setLimit] = useState(50)
  const [includeSlowLog, setIncludeSlowLog] = useState(false)
  const [hideIdle, setHideIdle] = useState(true)
  const { confirm, dialog } = useConfirm()
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

  async function onKill(process: MysqlProcess) {
    const confirmed = await confirm({
      message: t("confirm_kill_query", { id: process.id }),
      destructive: true
    })
    if (!confirmed) return
    killQuery.mutate(process.id)
  }

  return (
    <Page.Root aria-label={t("aria_page")} gutter="responsive" size="wide">
      {dialog}
      <Page.Header className="flex flex-wrap items-start justify-between gap-4 border-b border-border pb-4">
        <div>
          <Text className="font-medium uppercase" variant="caption" tone="muted">{t("admin:section_label")}</Text>
          <PageHeading>{t("heading")}</PageHeading>
          <Page.Description className="max-w-3xl">
            {t("description")}
          </Page.Description>
        </div>
        <Toolbar>
          <label className="text-sm font-medium text-text-primary" htmlFor="mysql-limit">{t("rows")}</label>
          <select
            className="rounded border border-border bg-surface px-2 py-1 text-sm text-text-primary"
            id="mysql-limit"
            onChange={(event) => setLimit(Number(event.target.value))}
            value={limit}
          >
            {[25, 50, 100, 200].map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
          <Button onClick={() => void mysql.refetch()} size="sm" variant="secondary">
            {t("refresh")}
          </Button>
        </Toolbar>
      </Page.Header>

      {mysql.isPending ? <Notice>{t("loading")}</Notice> : null}
      {mysql.isError ? <Notice tone="danger">{mysql.error instanceof Error ? mysql.error.message : t("error_load")}</Notice> : null}
      {killQuery.isError ? <Notice tone="danger">{killQuery.error instanceof Error ? killQuery.error.message : t("error_kill")}</Notice> : null}
      {killQuery.data && !killQuery.data.killed ? <Notice tone="danger">{killQuery.data.error?.message || t("kill_refused")}</Notice> : null}
      {killQuery.data?.killed ? <Notice tone="success">{t("killed_query", { id: killQuery.data.thread_id })}</Notice> : null}

      {mysql.data ? (
        <MysqlDashboard
          hideIdle={hideIdle}
          includeSlowLog={includeSlowLog}
          killingThreadId={killQuery.isPending ? killQuery.variables : null}
          payload={mysql.data}
          onKill={onKill}
          onToggleHideIdle={() => setHideIdle((value) => !value)}
          onToggleSlowLog={() => setIncludeSlowLog((value) => !value)}
          t={t}
        />
      ) : null}
    </Page.Root>
  )
}

function MysqlDashboard({
  hideIdle,
  includeSlowLog,
  killingThreadId,
  onKill,
  onToggleHideIdle,
  onToggleSlowLog,
  payload,
  t
}: {
  hideIdle: boolean
  includeSlowLog: boolean
  killingThreadId: number | null
  onKill: (process: MysqlProcess) => void
  onToggleHideIdle: () => void
  onToggleSlowLog: () => void
  payload: MysqlSnapshot
  t: ReturnType<typeof useT>["t"]
}) {
  const summary = payload.connection_summary
  const activeProcesses = payload.process_list.filter((process) => process.command !== "Sleep")
  const idleCount = payload.process_list.length - activeProcesses.length
  const visibleProcesses = hideIdle ? activeProcesses : payload.process_list
  return (
    <div className="space-y-6">
      <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <MetricCard label={t("metric_threads_running")} value={formatValue(summary.threads_running)} detail={t("metric_threads_connected", { count: formatValue(summary.threads_connected) })} />
        <MetricCard label={t("metric_connections_used")} value={connectionPercent(summary)} detail={t("metric_connections_limit", { max: formatValue(summary.max_used_connections), limit: formatValue(summary.max_connections) })} />
        <MetricCard label={t("metric_sleeping_connections")} value={formatValue(summary.sleeping_connections)} detail={t("metric_wait_timeout", { seconds: formatValue(summary.wait_timeout) })} />
        <MetricCard label={t("metric_buffer_pool")} value={formatBytes(Number(payload.variables.innodb_buffer_pool_size))} detail={t("metric_database", { database: payload.database })} />
      </section>

      <section className="grid gap-6 xl:grid-cols-2">
        <KeyValuePanel
          title={t("variables_heading")}
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
          title={t("counters_heading")}
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

      <Section.Root className="overflow-hidden p-0">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3">
          <SectionHeading>{t("process_list")}</SectionHeading>
          <div className="flex flex-wrap items-center gap-3">
            <Checkbox
              checked={hideIdle}
              label={t("hide_idle_threads", { count: idleCount })}
              onChange={onToggleHideIdle}
            />
            <p className="text-xs text-gray-500 dark:text-gray-400">{t("generated", { time: new Date(payload.generated_at).toLocaleString() })}</p>
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-800">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">ID</th>
                <th className="px-4 py-2">{t("col_command")}</th>
                <th className="px-4 py-2">{t("col_time")}</th>
                <th className="px-4 py-2">{t("col_state")}</th>
                <th className="px-4 py-2">{t("col_host")}</th>
                <th className="px-4 py-2">{t("col_info")}</th>
                <th className="px-4 py-2">{t("col_actions")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
              {visibleProcesses.length === 0 ? (
                <tr>
                  <td className="px-4 py-3 text-sm text-gray-500 dark:text-gray-400" colSpan={7}>
                    {hideIdle && payload.process_list.length > 0 ? t("all_threads_hidden") : t("no_processes")}
                  </td>
                </tr>
              ) : null}
              {visibleProcesses.map((process) => (
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
                        {killingThreadId === process.id ? t("killing") : t("kill_query")}
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section.Root>

      <section className="grid gap-6 xl:grid-cols-2">
        <StatementDigestPanel payload={payload} t={t} />
        <SlowLogPanel includeSlowLog={includeSlowLog} payload={payload} t={t} onToggleSlowLog={onToggleSlowLog} />
      </section>
    </div>
  )
}

function StatementDigestPanel({ payload, t }: { payload: MysqlSnapshot; t: ReturnType<typeof useT>["t"] }) {
  return (
    <Section.Root className="min-w-0 overflow-hidden p-0">
      <div className="border-b border-border px-4 py-3">
        <SectionHeading>{t("statement_digests")}</SectionHeading>
        <Text variant="caption" tone="muted">{t("statement_digests_description")}</Text>
      </div>
      {!payload.statement_digests.available ? (
        <UnavailablePanel
          fallback={t("statement_digests_unavailable")}
          error={payload.statement_digests.error}
        />
      ) : (
        <div className="max-h-[32rem] overflow-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-800">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">{t("col_total")}</th>
                <th className="px-4 py-2">{t("col_max")}</th>
                <th className="px-4 py-2">{t("col_count")}</th>
                <th className="px-4 py-2">{t("col_statement")}</th>
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
    </Section.Root>
  )
}

function SlowLogPanel({ includeSlowLog, onToggleSlowLog, payload, t }: { includeSlowLog: boolean; onToggleSlowLog: () => void; payload: MysqlSnapshot; t: ReturnType<typeof useT>["t"] }) {
  return (
    <Section.Root className="min-w-0 overflow-hidden p-0">
      <div className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-3">
        <div>
          <SectionHeading>{t("slow_log")}</SectionHeading>
          <Text variant="caption" tone="muted">
            slow_query_log {String(payload.slow_log.config.slow_query_log || "unknown")} · log_output {String(payload.slow_log.config.log_output || "unknown")} · long_query_time {String(payload.slow_log.config.long_query_time || "unknown")}s
          </Text>
        </div>
        <button
          className="rounded border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900"
          onClick={onToggleSlowLog}
          type="button"
        >
          {includeSlowLog ? t("hide_slow_log") : t("load_slow_log")}
        </button>
      </div>
      {!payload.slow_log.available ? (
        <UnavailablePanel fallback={t("slow_log_unavailable")} error={payload.slow_log.error} />
      ) : (
        <div className="max-h-[32rem] overflow-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-800">
            <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">{t("col_time")}</th>
                <th className="px-4 py-2">{t("col_query_time")}</th>
                <th className="px-4 py-2">{t("col_rows_examined")}</th>
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
    </Section.Root>
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
    <Section.Root className="overflow-hidden p-0">
      <SectionHeading className="border-b border-border px-4 py-3">{title}</SectionHeading>
      <dl className="grid grid-cols-1 gap-px bg-gray-100 text-sm dark:bg-gray-800 sm:grid-cols-2">
        {Object.entries(values).map(([key, value]) => (
          <div className="bg-white px-4 py-3 dark:bg-gray-950" key={key}>
            <dt className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{key}</dt>
            <dd className="mt-1 break-all font-mono text-gray-900 dark:text-gray-100">{formatValue(value)}</dd>
          </div>
        ))}
      </dl>
    </Section.Root>
  )
}

function MetricCard({ detail, label, value }: { detail: string; label: string; value: string }) {
  return (
    <Section.Root>
      <Text className="font-semibold uppercase" variant="caption" tone="muted">{label}</Text>
      <Text className="mt-2 text-2xl font-semibold" tone="default">{value}</Text>
      <Text className="mt-1" variant="caption" tone="muted">{detail}</Text>
    </Section.Root>
  )
}

function Panel({ children }: { children: ReactNode }) {
  return <Notice>{children}</Notice>
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
