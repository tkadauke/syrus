import { useMutation, useQuery } from "@tanstack/react-query"
import { useState, type ReactNode } from "react"
import { explainSql, fetchAdminPerformance, type AdminPerformancePayload, type BrowserTraceSummary, type PerformanceComparison, type PerformanceEvent, type SlowPhaseSummary, type SlowRequestSummary, type SqlExplainResult, type SqlFingerprintSummary } from "../api/adminPerformance"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"

type RevisionScope = "current" | "all"
type PerformanceTab = "overview" | "browser" | "requests" | "sql" | "phases" | "events"
type ExplainModalTab = "visual" | "table" | "json" | "sql"
type ExplainMode = "explain" | "analyze"

const PERFORMANCE_TABS: PerformanceTab[] = ["overview", "browser", "requests", "sql", "phases", "events"]
const EXPLAIN_MODAL_TABS: ExplainModalTab[] = ["visual", "table", "json", "sql"]
const OVERVIEW_ROW_LIMIT = 5

export function AdminPerformance() {
  const { t } = useT("syrus_dev")
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

export default AdminPerformance

function PerformanceView({ payload }: { payload: AdminPerformancePayload }) {
  const { t } = useT("syrus_dev")
  const eventCount = payload.events.length
  const [activeTab, setActiveTab] = useState<PerformanceTab>("overview")
  const [explainSqlText, setExplainSqlText] = useState<string | null>(null)
  const [requestDetail, setRequestDetail] = useState<SlowRequestSummary | null>(null)
  const openExplain = (sql: string) => {
    setRequestDetail(null)
    setExplainSqlText(sql)
  }

  return (
    <div className="space-y-6">
      <section aria-label={t("performance.aria_summary")} className="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
        <Metric title={t("performance.enabled")} value={payload.enabled ? t("performance.yes") : t("performance.no")} tone={payload.enabled ? "ok" : "warn"} />
        <Metric title={t("performance.events")} value={eventCount} context={t("performance.events_context", { max: payload.storage.max_events })} />
        <Metric title={t("performance.revision")} value={payload.revision_scope === "all" ? t("performance.all_revisions_short") : shortRevision(payload.current_revision)} context={payload.revision_scope === "all" ? t("performance.all_revisions_context") : t("performance.current_revision_context")} />
        <Metric title={t("performance.storage")} value={payload.storage.kind} context={t("performance.retention", { hours: Math.round(payload.storage.expires_in_seconds / 3600) })} />
        <Metric title={t("performance.thresholds")} value={formatMs(payload.thresholds.slow_request_ms)} context={t("performance.threshold_context", { phase: formatMs(payload.thresholds.slow_phase_ms), sql: formatMs(payload.thresholds.slow_sql_ms) })} />
      </section>

      <nav aria-label={t("performance.tabs_aria")} className="flex flex-wrap gap-2 border-b border-gray-200 dark:border-gray-700">
        {PERFORMANCE_TABS.map((tab) => (
          <button
            className={tabButtonClass(activeTab === tab)}
            key={tab}
            onClick={() => setActiveTab(tab)}
            type="button"
          >
            {t(`performance.tab_${tab}`)}
          </button>
        ))}
      </nav>

      {activeTab === "overview" ? (
        <>
          <RegressionTable payload={payload} />
          <BrowserTracesTable rows={(payload.summaries.browser_traces ?? []).slice(0, OVERVIEW_ROW_LIMIT)} />
          <SlowRequestsTable onInspect={setRequestDetail} rows={payload.summaries.slow_requests.slice(0, OVERVIEW_ROW_LIMIT)} />
          <SqlFingerprintsTable onExplain={openExplain} rows={payload.summaries.sql_fingerprints.slice(0, OVERVIEW_ROW_LIMIT)} />
          <SlowPhasesTable rows={payload.summaries.slow_phases.slice(0, OVERVIEW_ROW_LIMIT)} />
        </>
      ) : null}
      {activeTab === "browser" ? <BrowserTracesTable rows={payload.summaries.browser_traces ?? []} /> : null}
      {activeTab === "requests" ? <SlowRequestsTable onInspect={setRequestDetail} rows={payload.summaries.slow_requests} /> : null}
      {activeTab === "sql" ? <SqlFingerprintsTable onExplain={openExplain} rows={payload.summaries.sql_fingerprints} /> : null}
      {activeTab === "phases" ? <SlowPhasesTable rows={payload.summaries.slow_phases} /> : null}
      {activeTab === "events" ? <EventsTable rows={payload.events} /> : null}
      {requestDetail ? <SlowRequestSqlModal events={payload.events} onClose={() => setRequestDetail(null)} onExplain={openExplain} request={requestDetail} /> : null}
      {explainSqlText ? <SqlExplainModal initialSql={explainSqlText} onClose={() => setExplainSqlText(null)} /> : null}
    </div>
  )
}

function RegressionTable({ payload }: { payload: AdminPerformancePayload }) {
  const { t } = useT("syrus_dev")
  const rows = [
    ...comparisonRows(t("performance.slow_requests"), payload.baseline?.comparisons?.slow_requests ?? []),
    ...comparisonRows(t("performance.slow_phases"), payload.baseline?.comparisons?.slow_phases ?? []),
    ...comparisonRows(t("performance.browser_traces"), payload.baseline?.comparisons?.browser_traces ?? []),
    ...comparisonRows(t("performance.sql_fingerprints"), payload.baseline?.comparisons?.sql_fingerprints ?? [])
  ].filter((row) => row.status !== "unchanged").slice(0, 20)

  const title = payload.baseline?.revision
    ? t("performance.regressions_with_baseline", { revision: shortRevision(payload.baseline.revision) })
    : t("performance.regressions")

  return (
    <TableSection empty={payload.baseline?.revision ? t("performance.no_regressions") : t("performance.no_baseline")} rowCount={rows.length} title={title}>
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("performance.col_kind")}</th>
            <th className="px-4 py-2">{t("performance.col_item")}</th>
            <th className="px-4 py-2">{t("performance.col_status")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_current")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_baseline")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_delta")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_count")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <tr key={`${row.kind}-${row.key}`}>
              <td className="whitespace-nowrap px-4 py-2 text-xs font-medium text-gray-600 dark:text-gray-300">{row.kind}</td>
              <td className="max-w-3xl px-4 py-2 font-mono text-xs text-gray-900 dark:text-gray-100">
                <div className="truncate" title={row.label}>{row.label}</div>
              </td>
              <td className="whitespace-nowrap px-4 py-2 text-xs">
                <span className={comparisonPillClass(row.status)}>{row.status}</span>
              </td>
              <NumberCell value={formatMs(row.current_average_duration_ms)} />
              <NumberCell value={formatMs(row.baseline_average_duration_ms)} />
              <NumberCell value={formatDelta(row)} />
              <NumberCell value={`${row.current_count} / ${row.baseline_count ?? "-"}`} />
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function comparisonRows(kind: string, rows: PerformanceComparison[]) {
  return rows.map((row) => ({ ...row, kind }))
}

function comparisonPillClass(status: PerformanceComparison["status"]) {
  const base = "inline-flex rounded-full px-2 py-0.5 font-medium"
  if (status === "regressed") return `${base} bg-red-50 text-red-700 ring-1 ring-red-200 dark:bg-red-950/40 dark:text-red-300 dark:ring-red-800`
  if (status === "improved") return `${base} bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-300 dark:ring-emerald-800`
  if (status === "new") return `${base} bg-amber-50 text-amber-700 ring-1 ring-amber-200 dark:bg-amber-950/40 dark:text-amber-300 dark:ring-amber-800`
  return `${base} bg-gray-100 text-gray-600 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:ring-gray-700`
}

function SlowRequestsTable({ onInspect, rows }: { onInspect: (row: SlowRequestSummary) => void; rows: SlowRequestSummary[] }) {
  const { t } = useT("syrus_dev")
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
            <th className="px-4 py-2 text-right">{t("performance.col_actions")}</th>
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
              <td className="whitespace-nowrap px-4 py-2 text-right">
                <button className={smallActionClass()} onClick={() => onInspect(row)} type="button">
                  {t("performance.details")}
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function SlowRequestSqlModal({ events, onClose, onExplain, request }: { events: PerformanceEvent[]; onClose: () => void; onExplain: (sql: string) => void; request: SlowRequestSummary }) {
  const { t } = useT("syrus_dev")
  const requestEvents = events
    .filter((event) => event.event === "syrus.performance.slow_request")
    .filter((event) => event.method === request.method && event.path === request.path && event.controller === request.controller && event.action === request.action)
    .sort((a, b) => (b.occurred_at ?? "").localeCompare(a.occurred_at ?? ""))

  return (
    <div aria-label={t("performance.request_sql_modal_aria")} aria-modal="true" className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" role="dialog">
      <section className="flex max-h-[90vh] w-full max-w-6xl flex-col overflow-hidden rounded border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-950">
        <header className="flex items-start justify-between gap-4 border-b border-gray-200 px-5 py-4 dark:border-gray-700">
          <div className="min-w-0">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("performance.request_sql_heading")}</h2>
            <p className="mt-1 truncate font-mono text-sm text-gray-600 dark:text-gray-300" title={`${request.method} ${request.path}`}>{request.method} {request.path}</p>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{request.controller}#{request.action}</p>
          </div>
          <button className={secondaryActionClass()} onClick={onClose} type="button">
            {t("performance.close")}
          </button>
        </header>
        <div className="border-b border-gray-200 px-5 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
          {t("performance.request_sql_help")}
        </div>
        <div className="min-h-0 flex-1 space-y-4 overflow-auto p-5">
          {requestEvents.length > 0 ? requestEvents.map((event, index) => (
            <article className="overflow-hidden rounded border border-gray-200 dark:border-gray-700" key={`${event.request_id ?? event.occurred_at}-${index}`}>
              <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 bg-gray-50 px-4 py-3 text-xs text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">
                <div className="font-mono">{event.request_id || t("performance.request_without_id")}</div>
                <div>{formatDate(event.occurred_at)} · {formatMs(event.duration_ms)} · {t("performance.sql_context", { count: event.sql_count ?? 0, duration: formatMs(event.sql_duration_ms) })}</div>
              </div>
              <RequestSqlTable fingerprints={event.top_sql_fingerprints ?? []} onExplain={onExplain} />
            </article>
          )) : <PanelMessage>{t("performance.request_sql_no_events")}</PanelMessage>}
        </div>
      </section>
    </div>
  )
}

function RequestSqlTable({ fingerprints, onExplain }: { fingerprints: NonNullable<PerformanceEvent["top_sql_fingerprints"]>; onExplain: (sql: string) => void }) {
  const { t } = useT("syrus_dev")
  if (fingerprints.length === 0) return <PanelMessage>{t("performance.request_sql_no_fingerprints")}</PanelMessage>

  return (
    <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
      <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
        <tr>
          <th className="px-4 py-2">{t("performance.col_sql")}</th>
          <th className="px-4 py-2 text-right">{t("performance.col_count")}</th>
          <th className="px-4 py-2 text-right">{t("performance.col_total")}</th>
          <th className="px-4 py-2 text-right">{t("performance.col_avg")}</th>
          <th className="px-4 py-2 text-right">{t("performance.col_max")}</th>
          <th className="px-4 py-2 text-right">{t("performance.col_actions")}</th>
        </tr>
      </thead>
      <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
        {fingerprints.map((row, index) => {
          const count = row.count ?? 0
          const total = row.total_duration_ms ?? null
          const average = total != null && count > 0 ? total / count : null
          return (
            <tr key={`${row.fingerprint}-${index}`}>
              <td className="max-w-4xl px-4 py-2">
                <div className="text-xs font-medium text-gray-700 dark:text-gray-200">{row.name || t("performance.sql_unknown")}</div>
                <div className="mt-1 max-h-20 overflow-hidden break-words font-mono text-xs text-gray-600 dark:text-gray-300">{row.sample_sql || row.fingerprint}</div>
              </td>
              <NumberCell value={count || "-"} />
              <NumberCell value={formatMs(total)} />
              <NumberCell value={formatMs(average)} />
              <NumberCell value={formatMs(row.max_duration_ms)} />
              <td className="whitespace-nowrap px-4 py-2 text-right">
                <button className={smallActionClass()} disabled={!row.sample_sql} onClick={() => row.sample_sql && onExplain(row.sample_sql)} type="button">
                  {t("performance.explain")}
                </button>
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}

function SlowPhasesTable({ rows }: { rows: SlowPhaseSummary[] }) {
  const { t } = useT("syrus_dev")
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

function BrowserTracesTable({ rows }: { rows: BrowserTraceSummary[] }) {
  const { t } = useT("syrus_dev")
  return (
    <TableSection empty={t("performance.no_browser_traces")} rowCount={rows.length} title={t("performance.browser_traces")}>
      <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("performance.col_trace")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_count")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_browser_total")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_browser_avg")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_browser_max")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_backend_api")}</th>
            <th className="px-4 py-2 text-right">{t("performance.col_frontend_overhead")}</th>
            <th className="px-4 py-2">{t("performance.col_request_ids")}</th>
            <th className="px-4 py-2">{t("performance.col_last_seen")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <tr key={`${row.name}-${row.path}`}>
              <td className="max-w-xl px-4 py-2">
                <div className="font-mono text-xs text-gray-900 dark:text-gray-100">{row.name}</div>
                <div className="mt-1 truncate font-mono text-xs text-gray-500 dark:text-gray-400" title={row.path ?? undefined}>{row.path ?? "-"}</div>
              </td>
              <NumberCell value={row.count} />
              <NumberCell value={formatMs(row.total_duration_ms)} />
              <NumberCell value={formatMs(row.average_duration_ms)} />
              <NumberCell value={formatMs(row.max_duration_ms)} />
              <NumberCell value={`${formatMs(row.average_api_duration_ms)} / ${formatMs(row.max_api_duration_ms)}`} />
              <NumberCell value={`${formatMs(frontendOverhead(row.average_duration_ms, row.average_api_duration_ms))} / ${formatMs(frontendOverhead(row.max_duration_ms, row.max_api_duration_ms))}`} />
              <td className="max-w-md px-4 py-2 font-mono text-xs text-gray-600 dark:text-gray-300">
                <div className="truncate" title={row.recent_api_request_ids.join(", ")}>{row.recent_api_request_ids.join(", ") || "-"}</div>
              </td>
              <td className="whitespace-nowrap px-4 py-2 text-xs text-gray-600 dark:text-gray-300">{formatDate(row.last_seen_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function frontendOverhead(browserDuration: number | null | undefined, apiDuration: number | null | undefined) {
  if (browserDuration == null || apiDuration == null) return null
  return Math.max(0, browserDuration - apiDuration)
}

function SqlFingerprintsTable({ onExplain, rows }: { onExplain: (sql: string) => void; rows: SqlFingerprintSummary[] }) {
  const { t } = useT("syrus_dev")
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
            <th className="px-4 py-2 text-right">{t("performance.col_actions")}</th>
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
              <td className="whitespace-nowrap px-4 py-2 text-right">
                <button
                  className="rounded border border-gray-300 bg-white px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
                  disabled={!row.sample_sql}
                  onClick={() => row.sample_sql && onExplain(row.sample_sql)}
                  type="button"
                >
                  {t("performance.explain")}
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

function SqlExplainModal({ initialSql, onClose }: { initialSql: string; onClose: () => void }) {
  const { t } = useT("syrus_dev")
  const [activeTab, setActiveTab] = useState<ExplainModalTab>("visual")
  const [displayedMode, setDisplayedMode] = useState<ExplainMode>("explain")
  const [resultsByMode, setResultsByMode] = useState<Partial<Record<ExplainMode, SqlExplainResult>>>({})
  const mutation = useMutation({
    mutationFn: ({ mode }: { mode: ExplainMode }) => explainSql(initialSql, { analyze: mode === "analyze", timeoutMs: mode === "analyze" ? 1000 : undefined }),
    onSuccess: (nextResult, variables) => {
      setResultsByMode((current) => ({ ...current, [variables.mode]: nextResult }))
      setDisplayedMode(variables.mode)
      setActiveTab("visual")
    }
  })
  const result = resultsByMode[displayedMode] ?? null
  const explainResult = resultsByMode.explain ?? null
  const isLoading = mutation.isPending
  const analyzeSafe = explainResult?.analyze_safe === true || resultsByMode.analyze?.analyze_safe === true
  const analyzeDisabled = isLoading || explainResult == null || !analyzeSafe
  const warning = result?.placeholder_substituted ? [t("performance.explain_placeholder_warning"), ...result.warnings] : result?.warnings ?? []
  const showOrRun = (mode: ExplainMode) => {
    if (resultsByMode[mode]) {
      mutation.reset()
      setDisplayedMode(mode)
      setActiveTab("visual")
    } else {
      mutation.mutate({ mode })
    }
  }

  return (
    <div aria-label={t("performance.explain_modal_aria")} aria-modal="true" className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" role="dialog">
      <section className="flex max-h-[90vh] w-full max-w-6xl flex-col overflow-hidden rounded border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-950">
        <header className="flex items-start justify-between gap-4 border-b border-gray-200 px-5 py-4 dark:border-gray-700">
          <div>
            <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("performance.explain_heading")}</h2>
            <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">{t("performance.explain_help")}</p>
          </div>
          <button className="rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" onClick={onClose} type="button">
            {t("performance.close")}
          </button>
        </header>
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 px-5 py-3 dark:border-gray-700">
          <div className="flex flex-wrap gap-2">
            <button className={primaryActionClass()} disabled={isLoading} onClick={() => showOrRun("explain")} type="button">
              {isLoading ? t("performance.explain_running") : t("performance.run_explain")}
            </button>
            <button className={secondaryActionClass()} disabled={analyzeDisabled} onClick={() => showOrRun("analyze")} type="button" title={explainResult && !analyzeSafe ? explainResult.analyze_safety_reason : t("performance.run_analyze_title")}>
              {t("performance.run_analyze")}
            </button>
          </div>
          <div className="text-xs text-gray-500 dark:text-gray-400">
            {result ? t("performance.explain_mode_context", { mode: result.mode, adapter: result.adapter }) : t("performance.explain_not_run")}
          </div>
        </div>
        {mutation.isError ? <PanelMessage tone="error">{errorMessage(mutation.error, t("performance.explain_error"))}</PanelMessage> : null}
        {warning.length > 0 ? (
          <div className="border-b border-amber-200 bg-amber-50 px-5 py-3 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
            {warning.map((item) => <div key={item}>{item}</div>)}
          </div>
        ) : null}
        {result ? (
          <>
            <nav aria-label={t("performance.explain_tabs_aria")} className="flex flex-wrap gap-2 border-b border-gray-200 px-5 dark:border-gray-700">
              {EXPLAIN_MODAL_TABS.map((tab) => (
                <button className={tabButtonClass(activeTab === tab)} key={tab} onClick={() => setActiveTab(tab)} type="button">
                  {t(`performance.explain_tab_${tab}`)}
                </button>
              ))}
            </nav>
            <div className="min-h-0 flex-1 overflow-auto p-5">
              {activeTab === "visual" ? <VisualPlan result={result} /> : null}
              {activeTab === "table" ? <ExplainRowsTable rows={result.rows} /> : null}
              {activeTab === "json" ? <JsonBlock value={result.json_plan ?? result.rows} /> : null}
              {activeTab === "sql" ? <SqlBlock sql={result.normalized_sql} /> : null}
            </div>
          </>
        ) : (
          <div className="overflow-auto p-5">
            <SqlBlock sql={initialSql} />
          </div>
        )}
      </section>
    </div>
  )
}

function EventsTable({ rows }: { rows: PerformanceEvent[] }) {
  const { t } = useT("syrus_dev")
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
                {row.api_requests?.length ? <div className="mt-1">{t("performance.browser_api_context", { count: row.api_requests.length, ids: row.api_requests.map((request) => request.request_id).filter(Boolean).join(", ") || "-" })}</div> : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableSection>
  )
}

type PlanNode = {
  title: string
  subtitle?: string
  risk: "low" | "medium" | "high" | "neutral"
  metrics: Array<[string, ReactNode]>
  children: PlanNode[]
}

function VisualPlan({ result }: { result: SqlExplainResult }) {
  const { t } = useT("syrus_dev")
  const nodes = planNodes(result)
  if (nodes.length === 0) {
    return <PanelMessage>{t("performance.explain_no_visual")}</PanelMessage>
  }

  return (
    <div className="space-y-3">
      {result.mode === "analyze" ? (
        <PanelMessage>{t("performance.analyze_notice", { timeout: result.timeout_ms ?? "-" })}</PanelMessage>
      ) : null}
      <div className="space-y-3">
        {nodes.map((node, index) => <PlanNodeCard key={`${node.title}-${index}`} node={node} />)}
      </div>
    </div>
  )
}

function PlanNodeCard({ depth = 0, node }: { depth?: number; node: PlanNode }) {
  return (
    <div className={`${depth > 0 ? "ml-5 border-l border-gray-200 pl-4 dark:border-gray-700" : ""}`}>
      <article className={`rounded border p-3 ${planRiskClass(node.risk)}`}>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="font-mono text-sm font-semibold">{node.title}</h3>
            {node.subtitle ? <p className="mt-1 font-mono text-xs opacity-80">{node.subtitle}</p> : null}
          </div>
          <span className="rounded-full bg-white/70 px-2 py-0.5 text-xs font-medium uppercase dark:bg-black/20">{node.risk}</span>
        </div>
        {node.metrics.length > 0 ? (
          <dl className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
            {node.metrics.map(([label, value]) => (
              <div className="rounded bg-white/70 px-2 py-1 dark:bg-black/20" key={label}>
                <dt className="text-[11px] uppercase opacity-70">{label}</dt>
                <dd className="mt-0.5 break-words font-mono text-xs">{value ?? "-"}</dd>
              </div>
            ))}
          </dl>
        ) : null}
      </article>
      {node.children.length > 0 ? (
        <div className="mt-3 space-y-3">
          {node.children.map((child, index) => <PlanNodeCard depth={depth + 1} key={`${child.title}-${index}`} node={child} />)}
        </div>
      ) : null}
    </div>
  )
}

function ExplainRowsTable({ rows }: { rows: Array<Record<string, unknown>> }) {
  const { t } = useT("syrus_dev")
  const columns = Array.from(new Set(rows.flatMap((row) => Object.keys(row))))
  if (rows.length === 0 || columns.length === 0) return <PanelMessage>{t("performance.explain_no_rows")}</PanelMessage>

  return (
    <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="min-w-full divide-y divide-gray-200 text-xs dark:divide-gray-700">
        <thead className="bg-gray-50 text-left font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>{columns.map((column) => <th className="px-3 py-2" key={column}>{column}</th>)}</tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row, index) => (
            <tr key={index}>
              {columns.map((column) => <td className="max-w-xl whitespace-pre-wrap break-words px-3 py-2 font-mono text-gray-700 dark:text-gray-200" key={column}>{stringValue(row[column])}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function JsonBlock({ value }: { value: unknown }) {
  return <pre className="max-h-[60vh] overflow-auto rounded border border-gray-200 bg-gray-50 p-4 text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100">{JSON.stringify(value, null, 2)}</pre>
}

function SqlBlock({ sql }: { sql: string }) {
  return <pre className="max-h-[60vh] overflow-auto whitespace-pre-wrap rounded border border-gray-200 bg-gray-50 p-4 font-mono text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100">{sql}</pre>
}

function planNodes(result: SqlExplainResult): PlanNode[] {
  if (result.json_plan) return nodesFromJsonPlan(result.json_plan)
  if (result.rows.length > 0 && result.rows.some((row) => row.table || row.type || row.key || row.rows)) {
    return result.rows.map((row) => nodeFromExplainRow(row))
  }
  return result.rows.map((row, index) => {
    const text = Object.values(row).map((value) => stringValue(value)).join(" ")
    return {
      title: `Step ${index + 1}`,
      subtitle: text,
      risk: text.match(/\btable scan\b|rows=\d{5,}/i) ? "high" : "neutral",
      metrics: [],
      children: []
    }
  })
}

function nodesFromJsonPlan(plan: Record<string, unknown>): PlanNode[] {
  const root = plan.query_block
  if (isRecord(root)) return [nodeFromJsonRecord("query_block", root)]
  return [nodeFromJsonRecord("plan", plan)]
}

function nodeFromJsonRecord(label: string, record: Record<string, unknown>): PlanNode {
  if (isRecord(record.table)) return tableNode(record.table)
  const children: PlanNode[] = []
  for (const key of [ "nested_loop", "query_block", "ordering_operation", "grouping_operation", "duplicates_removal", "attached_subqueries", "materialized_from_subquery" ]) {
    const value = record[key]
    if (Array.isArray(value)) {
      value.forEach((item, index) => {
        if (isRecord(item)) children.push(nodeFromJsonRecord(`${key}[${index}]`, item))
      })
    } else if (isRecord(value)) {
      children.push(nodeFromJsonRecord(key, value))
    }
  }

  return {
    title: humanPlanLabel(label),
    risk: "neutral",
    metrics: compactMetrics(record, [ "select_id", "cost_info", "used_columns" ]),
    children
  }
}

function tableNode(table: Record<string, unknown>): PlanNode {
  const accessType = stringValue(table.access_type)
  const rowsExamined = table.rows_examined_per_scan ?? table.rows_produced_per_join
  const title = table.table_name ? `Table ${stringValue(table.table_name)}` : "Table access"
  const key = table.key || table.possible_keys
  return {
    title,
    subtitle: accessType ? `access: ${accessType}` : undefined,
    risk: accessRisk(accessType),
    metrics: [
      [ "access", accessType || "-" ],
      [ "key", stringValue(key) || "-" ],
      [ "rows", stringValue(rowsExamined) || "-" ],
      [ "filtered", stringValue(table.filtered) || "-" ],
      [ "cost", costSummary(table.cost_info) || "-" ],
      [ "condition", stringValue(table.attached_condition) || "-" ]
    ],
    children: isRecord(table.materialized_from_subquery) ? [nodeFromJsonRecord("materialized_from_subquery", table.materialized_from_subquery)] : []
  }
}

function nodeFromExplainRow(row: Record<string, unknown>): PlanNode {
  const accessType = stringValue(row.type)
  return {
    title: row.table ? `Table ${stringValue(row.table)}` : "Explain row",
    subtitle: row.select_type ? stringValue(row.select_type) : undefined,
    risk: accessRisk(accessType),
    metrics: [
      [ "access", accessType || "-" ],
      [ "key", stringValue(row.key) || "-" ],
      [ "possible keys", stringValue(row.possible_keys) || "-" ],
      [ "rows", stringValue(row.rows) || "-" ],
      [ "filtered", stringValue(row.filtered) || "-" ],
      [ "extra", stringValue(row.Extra ?? row.extra) || "-" ]
    ],
    children: []
  }
}

function compactMetrics(record: Record<string, unknown>, keys: string[]): Array<[string, ReactNode]> {
  return keys.filter((key) => record[key] != null).map((key) => [humanPlanLabel(key), stringValue(record[key])])
}

function accessRisk(accessType: string) {
  const normalized = accessType.toLowerCase()
  if (normalized === "all") return "high"
  if ([ "index", "range", "index_merge" ].includes(normalized)) return "medium"
  if ([ "system", "const", "eq_ref", "ref" ].includes(normalized)) return "low"
  return "neutral"
}

function planRiskClass(risk: PlanNode["risk"]) {
  if (risk === "high") return "border-red-200 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950/40 dark:text-red-100"
  if (risk === "medium") return "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100"
  if (risk === "low") return "border-emerald-200 bg-emerald-50 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-100"
  return "border-gray-200 bg-white text-gray-900 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
}

function humanPlanLabel(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (char) => char.toUpperCase())
}

function costSummary(value: unknown) {
  if (!isRecord(value)) return stringValue(value)
  return stringValue(value.query_cost ?? value.read_cost ?? value.eval_cost)
}

function stringValue(value: unknown): string {
  if (value == null) return ""
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return JSON.stringify(value)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function scopeButtonClass(active: boolean) {
  return active
    ? "rounded bg-gray-900 px-3 py-1.5 font-medium text-white dark:bg-gray-100 dark:text-gray-900"
    : "rounded px-3 py-1.5 font-medium text-gray-600 hover:text-gray-900 dark:text-gray-300 dark:hover:text-gray-100"
}

function primaryActionClass() {
  return "rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 disabled:cursor-not-allowed disabled:bg-gray-400 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-gray-200"
}

function secondaryActionClass() {
  return "rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
}

function smallActionClass() {
  return "rounded border border-gray-300 bg-white px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
}

function tabButtonClass(active: boolean) {
  return active
    ? "border-b-2 border-gray-900 px-3 py-2 text-sm font-semibold text-gray-900 dark:border-gray-100 dark:text-gray-100"
    : "border-b-2 border-transparent px-3 py-2 text-sm font-medium text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
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

function formatDelta(row: PerformanceComparison) {
  const delta = row.delta_average_duration_ms
  if (delta == null) return "-"
  const sign = delta > 0 ? "+" : ""
  const percent = row.delta_percent == null ? "" : ` (${sign}${row.delta_percent.toFixed(1)}%)`
  return `${sign}${formatMs(delta)}${percent}`
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
