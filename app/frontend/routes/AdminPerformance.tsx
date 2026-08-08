import { useQuery } from "@tanstack/react-query"
import { useState, type ReactNode } from "react"
import { fetchAdminPerformance, type AdminPerformancePayload, type PerformanceEvent, type SlowPhaseSummary, type SlowRequestSummary, type SqlFingerprintSummary } from "../api/adminPerformance"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

type RevisionScope = "current" | "all"

export function AdminPerformance() {
  const { t } = useT("admin")
  const [revisionScope, setRevisionScope] = useState<RevisionScope>("current")
  usePageTitle(t("page_title_performance"))
  const performance = useQuery({
    queryKey: ["admin", "performance", revisionScope],
    queryFn: () => fetchAdminPerformance(200, revisionScope)
  })

  return (
    <main aria-label={t("performance.aria")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex items-end justify-between gap-4 border-b border-gray-200 pb-4 dark:border-gray-700">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("performance.heading")}</h1>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <div className="inline-flex rounded border border-gray-300 bg-white p-0.5 text-sm dark:border-gray-600 dark:bg-gray-900" role="group" aria-label={t("performance.revision_filter")}>
            <button className={scopeButtonClass(revisionScope === "current")} onClick={() => setRevisionScope("current")} type="button">{t("performance.current_revision")}</button>
            <button className={scopeButtonClass(revisionScope === "all")} onClick={() => setRevisionScope("all")} type="button">{t("performance.all_revisions")}</button>
          </div>
          <button
            className="inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
            disabled={performance.isFetching}
            onClick={() => void performance.refetch()}
            type="button"
          >
            {performance.isFetching ? t("performance.refreshing") : t("performance.refresh")}
          </button>
        </div>
      </header>

      {performance.isPending ? <PanelMessage>{t("performance.loading")}</PanelMessage> : null}
      {performance.isError ? <PanelMessage tone="error">{errorMessage(performance.error, t("performance.error_load"))}</PanelMessage> : null}
      {performance.isSuccess ? <PerformanceView payload={performance.data} /> : null}
    </main>
  )
}

function PerformanceView({ payload }: { payload: AdminPerformancePayload }) {
  const { t } = useT("admin")
  const eventCount = payload.events.length

  return (
    <div className="space-y-6">
      <section aria-label={t("performance.aria_summary")} className="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
        <Metric title={t("performance.enabled")} value={payload.enabled ? t("performance.yes") : t("performance.no")} tone={payload.enabled ? "ok" : "warn"} />
        <Metric title={t("performance.events")} value={eventCount} context={t("performance.events_context", { max: payload.storage.max_events })} />
        <Metric title={t("performance.revision")} value={payload.revision_scope === "all" ? t("performance.all_revisions_short") : shortRevision(payload.current_revision)} context={payload.revision_scope === "all" ? t("performance.all_revisions_context") : t("performance.current_revision_context")} />
        <Metric title={t("performance.storage")} value={payload.storage.kind} context={t("performance.retention", { hours: Math.round(payload.storage.expires_in_seconds / 3600) })} />
        <Metric title={t("performance.thresholds")} value={formatMs(payload.thresholds.slow_request_ms)} context={t("performance.threshold_context", { phase: formatMs(payload.thresholds.slow_phase_ms), sql: formatMs(payload.thresholds.slow_sql_ms) })} />
      </section>

      <SlowRequestsTable rows={payload.summaries.slow_requests} />
      <SlowPhasesTable rows={payload.summaries.slow_phases} />
      <SqlFingerprintsTable rows={payload.summaries.sql_fingerprints} />
      <EventsTable rows={payload.events} />
    </div>
  )
}

function SlowRequestsTable({ rows }: { rows: SlowRequestSummary[] }) {
  const { t } = useT("admin")
  return (
    <TableSection empty={t("performance.no_slow_requests")} rowCount={rows.length} title={t("performance.slow_requests")}>
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("performance.col_request")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_count")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_total")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_avg")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_max")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_sql")}</th>
            <th className="px-4 py-2">{t("performance.col_last_seen")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <tr key={`${row.method}-${row.path}-${row.controller}-${row.action}`}>
              <td className="max-w-xl px-4 py-2">
                <div className="font-mono text-xs text-gray-900 dark:text-gray-100">{row.method} {row.path}</div>
                <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{row.controller}#{row.action}</div>
              </td>
              <NumberCell value={row.count} />
              <NumberCell value={formatMs(row.total_duration_ms)} />
              <NumberCell value={formatMs(row.average_duration_ms)} />
              <NumberCell value={formatMs(row.max_duration_ms)} />
              <NumberCell value={`${row.average_sql_count ?? "-"} / ${formatMs(row.average_sql_duration_ms)}`} />
              <td className="px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{formatDate(row.last_seen_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function SlowPhasesTable({ rows }: { rows: SlowPhaseSummary[] }) {
  const { t } = useT("admin")
  return (
    <TableSection empty={t("performance.no_slow_phases")} rowCount={rows.length} title={t("performance.slow_phases")}>
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("performance.col_phase")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_count")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_total")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_avg")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_max")}</th>
            <th className="px-4 py-2">{t("performance.col_metadata")}</th>
            <th className="px-4 py-2">{t("performance.col_last_seen")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => {
            const metadata = compactJson(row.recent_metadata)
            return (
              <tr key={row.phase}>
                <td className="px-4 py-2 font-mono text-xs text-gray-900 dark:text-gray-100">{row.phase}</td>
                <NumberCell value={row.count} />
                <NumberCell value={formatMs(row.total_duration_ms)} />
                <NumberCell value={formatMs(row.average_duration_ms)} />
                <NumberCell value={formatMs(row.max_duration_ms)} />
                <td className="max-w-md overflow-hidden px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">
                  <div className="truncate" title={metadata !== "-" ? metadata : undefined}>{metadata}</div>
                </td>
                <td className="whitespace-nowrap px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{formatDate(row.last_seen_at)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </TableSection>
  )
}

function SqlFingerprintsTable({ rows }: { rows: SqlFingerprintSummary[] }) {
  const { t } = useT("admin")
  return (
    <TableSection empty={t("performance.no_sql")} rowCount={rows.length} title={t("performance.sql_fingerprints")}>
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("performance.col_sql")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_count")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_total")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_avg")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_max")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <tr key={row.fingerprint}>
              <td className="max-w-4xl px-4 py-2">
                <div className="text-xs font-medium text-gray-700 dark:text-gray-200">{row.name || t("performance.sql_unknown")}</div>
                <div className="mt-1 max-h-16 overflow-hidden break-words font-mono text-xs text-gray-600 dark:text-gray-300">{row.sample_sql || row.fingerprint}</div>
              </td>
              <NumberCell value={row.count} />
              <NumberCell value={formatMs(row.total_duration_ms)} />
              <NumberCell value={formatMs(row.average_duration_ms)} />
              <NumberCell value={formatMs(row.max_duration_ms)} />
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function EventsTable({ rows }: { rows: PerformanceEvent[] }) {
  const { t } = useT("admin")
  return (
    <TableSection empty={t("performance.no_events")} rowCount={rows.length} title={t("performance.recent_events")}>
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("performance.col_time")}</th>
            <th className="px-4 py-2">{t("performance.col_revision")}</th>
            <th className="px-4 py-2">{t("performance.col_event")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_duration")}</th>
            <th className="px-4 py-2">{t("performance.col_context")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row, index) => (
            <tr key={`${row.occurred_at}-${row.event}-${index}`}>
              <td className="whitespace-nowrap px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{formatDate(row.occurred_at)}</td>
              <td className="whitespace-nowrap px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">{shortRevision(row.app_revision)}</td>
              <td className="px-4 py-2 font-mono text-xs text-gray-900 dark:text-gray-100">{shortEvent(row.event)}</td>
              <NumberCell value={formatMs(row.duration_ms)} />
              <td className="max-w-4xl px-4 py-2 text-xs text-gray-600 dark:text-gray-300">
                <div className="font-mono">{row.phase || row.path || row.name || row.fingerprint || "-"}</div>
                {row.sql_count != null ? <div className="mt-1">{t("performance.sql_context", { count: row.sql_count, duration: formatMs(row.sql_duration_ms) })}</div> : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function scopeButtonClass(active: boolean) {
  return active
    ? "rounded bg-gray-900 px-3 py-1.5 font-medium text-white dark:bg-gray-100 dark:text-gray-900"
    : "rounded px-3 py-1.5 font-medium text-gray-600 hover:text-gray-900 dark:text-gray-300 dark:hover:text-gray-100"
}

function TableSection({ children, empty, rowCount, title }: { children: ReactNode; empty: string; rowCount: number; title: string }) {
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="border-b border-gray-200 px-4 py-3 text-sm font-semibold text-gray-900 dark:border-gray-700 dark:text-gray-100">{title}</div>
      {rowCount > 0 ? <div className="overflow-x-auto">{children}</div> : <PanelMessage>{empty}</PanelMessage>}
    </section>
  )
}

function Metric({ context, title, tone = "idle", value }: { context?: string; title: string; tone?: "idle" | "ok" | "warn"; value: ReactNode }) {
  const toneClass = tone === "ok"
    ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200"
    : tone === "warn"
      ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "border-gray-200 bg-white text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"

  return (
    <article className={`rounded border px-4 py-3 ${toneClass}`}>
      <h2 className="text-xs font-medium uppercase opacity-75">{title}</h2>
      <div className="mt-2 text-2xl font-semibold">{value}</div>
      {context ? <p className="mt-1 text-xs opacity-80">{context}</p> : null}
    </article>
  )
}

function NumberCell({ value }: { value: ReactNode }) {
  return <td className="whitespace-nowrap px-4 py-2 text-right font-mono text-xs text-gray-700 dark:text-gray-200">{value}</td>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`rounded border p-4 text-sm ${tone === "error" ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300" : "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"}`}>{children}</div>
}

function formatMs(value: number | null | undefined) {
  if (value == null) return "-"
  if (value >= 1000) return `${(value / 1000).toFixed(2)}s`
  return `${Math.round(value)}ms`
}

function formatDate(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

function compactJson(value: Record<string, unknown> | null | undefined) {
  if (!value || Object.keys(value).length === 0) return "-"
  return JSON.stringify(value)
}

function shortEvent(value: string) {
  return value.replace("syrus.performance.", "")
}

function shortRevision(value: string | null | undefined) {
  if (!value) return "-"
  return value.length > 12 ? value.slice(0, 12) : value
}
