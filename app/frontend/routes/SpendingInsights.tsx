import { withRoutePrefix } from "../lib/routing"
import { formatCurrency } from "../lib/format"
import { useQuery } from "@tanstack/react-query"
import { useMemo, useState, type FormEvent } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { fetchSpending, type SpendingBreakdownRow, type SpendingPayload, type SpendingTriggerRow } from "../api/spending"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"

type SortKey = "label" | "jobs_count" | "total_usd" | "average_job_usd" | "last_30_days_usd" | "runs_count" | "average_usd"
type SortState = { key: SortKey; direction: "asc" | "desc" }

export function SpendingInsightsRoute() {
  const { t } = useT("common")
  usePageTitle(t("spending.title"))
  const location = useLocation()
  const spending = useQuery({
    queryKey: ["insights", "spending", location.search],
    queryFn: () => fetchSpending(location.search)
  })

  if (spending.isPending) return <main aria-label={t("spending.aria_insights")} className="p-6 text-sm text-gray-600 dark:text-gray-400">{t("loading")}</main>
  if (spending.isError) {
    return (
      <main aria-label={t("spending.aria_insights")} className="p-6">
        <p className="text-sm text-red-700 dark:text-red-300">{t("spending.unable_to_load")}</p>
      </main>
    )
  }

  return <SpendingInsights payload={spending.data} pathname={location.pathname} search={location.search} />
}

function SpendingInsights({ payload, pathname, search }: { payload: SpendingPayload; pathname: string; search: string }) {
  const { t } = useT("common")
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""

  return (
    <main aria-label={t("spending.aria_insights")} className="mx-auto max-w-[96rem] space-y-5 p-6">
      <header className="flex flex-col gap-4 border-b border-gray-200 dark:border-gray-700 pb-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("spending.eyebrow")}</p>
          <h1 className="mt-1 text-3xl font-semibold text-gray-900 dark:text-gray-100">{t("spending.title")}</h1>
          <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t("spending.scope_range", { scope: payload.scope.label, start: payload.filters.start_date, end: payload.filters.end_date })}</p>
        </div>
        <DateRangeForm pathname={pathname} search={search} payload={payload} />
      </header>

      <section aria-label={t("spending.totals_aria")} className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        <Metric title={t("spending.metric_week")} value={formatCurrency(payload.totals.week_usd)} context={t("spending.context_workflow_runs")} />
        <Metric title={t("spending.metric_month")} value={formatCurrency(payload.totals.month_usd)} context={t("spending.context_workflow_runs")} />
        <Metric title={t("spending.metric_lifetime")} value={formatCurrency(payload.totals.lifetime_usd)} context={t("spending.context_runs_chats", { runs: formatCurrency(payload.totals.workflow_lifetime_usd), chats: formatCurrency(payload.totals.chat_lifetime_usd) })} />
        <Metric title={t("spending.metric_avg_job")} value={formatCurrency(payload.totals.average_job_30d_usd)} context={t("spending.context_last_30_days")} />
        <Metric title={t("spending.metric_avg_merged_pr")} value={formatCurrency(payload.totals.average_merged_pr_30d_usd)} context={t("spending.context_last_30_days")} />
      </section>

      <section aria-label={t("spending.trend_aria")} className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <div className="mb-3 flex items-center justify-between gap-3">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("spending.trend")}</h2>
          <span className="text-xs text-gray-500 dark:text-gray-400">{t("spending.trend_days", { count: payload.trend.length })}</span>
        </div>
        <TrendChart points={payload.trend} />
      </section>

      <div className="grid gap-5 xl:grid-cols-2">
        <BreakdownTable title={t("spending.by_epic")} entityLabel={t("spending.entity_epic")} rows={payload.breakdowns.epics} prefix={prefix} columns="standard" emptyLabel={t("spending.empty_epic")} />
        <BreakdownTable title={t("spending.by_user")} entityLabel={t("spending.entity_user")} rows={payload.breakdowns.users} prefix={prefix} columns="users" emptyLabel={t("spending.empty_user")} />
        <BreakdownTable title={t("spending.by_repository")} entityLabel={t("spending.entity_repository")} rows={payload.breakdowns.repositories} prefix={prefix} columns="standard" emptyLabel={t("spending.empty_repository")} />
        <TriggerTable rows={payload.breakdowns.trigger_kinds} />
      </div>

      <TopRunsTable payload={payload} prefix={prefix} />
    </main>
  )
}

function DateRangeForm({ pathname, search, payload }: { pathname: string; search: string; payload: SpendingPayload }) {
  const { t } = useT("common")
  const navigate = useNavigate()
  const params = new URLSearchParams(search)
  const [startDate, setStartDate] = useState(params.get("start_date") || payload.filters.start_date)
  const [endDate, setEndDate] = useState(params.get("end_date") || payload.filters.end_date)
  const [agentProvider, setAgentProvider] = useState(params.get("agent_provider") || payload.filters.agent_provider || "")
  const showAgentProvider = payload.filters.agent_providers.length > 1

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const next = new URLSearchParams(search)
    next.set("start_date", startDate)
    next.set("end_date", endDate)
    if (agentProvider) {
      next.set("agent_provider", agentProvider)
    } else {
      next.delete("agent_provider")
    }
    navigate(`${pathname}?${next.toString()}`)
  }

  return (
    <form className="flex flex-wrap items-end gap-3" onSubmit={submit}>
      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("spending.form_start")}
        <input className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100" type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} />
      </label>
      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("spending.form_end")}
        <input className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100" type="date" value={endDate} onChange={(event) => setEndDate(event.target.value)} />
      </label>
      {showAgentProvider ? (
        <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
          {t("spending.form_model")}
          <select className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100" value={agentProvider} onChange={(event) => setAgentProvider(event.target.value)}>
            <option value="">{t("spending.form_all_models")}</option>
            {payload.filters.agent_providers.map((provider) => (
              <option key={provider.value} value={provider.value}>{provider.label}</option>
            ))}
          </select>
        </label>
      ) : null}
      <button className="rounded bg-gray-900 px-4 py-2 text-sm font-medium text-white hover:bg-gray-700" type="submit">{t("spending.form_apply")}</button>
    </form>
  )
}

function Metric({ title, value, context }: { title: string; value: string; context: string }) {
  return (
    <article className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-medium text-gray-700 dark:text-gray-300">{title}</h2>
      <p className="mt-2 text-3xl font-semibold text-gray-900 dark:text-gray-100">{value}</p>
      <p className="mt-1 truncate text-xs text-gray-500 dark:text-gray-400">{context}</p>
    </article>
  )
}

function TrendChart({ points }: { points: SpendingPayload["trend"] }) {
  const { t } = useT("common")
  const max = Math.max(...points.map((point) => point.total_usd), 0)
  const width = Math.max(points.length * 7, 320)

  if (points.length === 0) {
    return <div className="flex h-48 items-center justify-center text-sm text-gray-500 dark:text-gray-400">{t("spending.no_spending")}</div>
  }

  return (
    <div className="overflow-x-auto">
      <svg aria-label={t("spending.daily_spend")} className="h-48 min-w-full" role="img" viewBox={`0 0 ${width} 180`} preserveAspectRatio="none">
        <line x1="0" y1="160" x2={width} y2="160" stroke="#e5e7eb" />
        {points.map((point, index) => {
          const barHeight = max > 0 ? Math.max(2, (point.total_usd / max) * 145) : 0
          return (
            <rect
              fill="#b6492e"
              height={barHeight}
              key={point.date}
              rx="1"
              width="4"
              x={index * 7 + 1}
              y={160 - barHeight}
            >
              <title>{point.date}: {formatCurrency(point.total_usd)}</title>
            </rect>
          )
        })}
      </svg>
    </div>
  )
}

function BreakdownTable({ title, entityLabel, rows, prefix, columns, emptyLabel }: { title: string; entityLabel: string; rows: SpendingBreakdownRow[]; prefix: string; columns: "standard" | "users"; emptyLabel: string }) {
  const { t } = useT("common")
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <section aria-label={title} className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <TableHeader title={title} />
      {rows.length === 0 ? <EmptyTable label={emptyLabel} /> : (
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <SortableHeader label={entityLabel} sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label={t("spending.col_jobs")} sortKey="jobs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("spending.col_total")} sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={columns === "users" ? t("spending.col_last_30") : t("spending.col_avg_job")} sortKey={columns === "users" ? "last_30_days_usd" : "average_job_usd"} sort={sort} setSort={setSort} align="right" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 bg-white dark:bg-gray-900">
            {sorted.map((row) => (
              <tr key={row.id}>
                <td className="max-w-0 px-4 py-3">
                  <Link className="truncate font-medium text-blue-700 dark:text-blue-300 underline hover:no-underline" to={withRoutePrefix(row.path, prefix)}>
                    {row.display_number ? `${row.display_number} / ${row.label}` : row.label}
                  </Link>
                </td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{row.jobs_count}</td>
                <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900 dark:text-gray-100">{formatCurrency(row.total_usd)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{formatCurrency(columns === "users" ? row.last_30_days_usd || 0 : row.average_job_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function TriggerTable({ rows }: { rows: SpendingTriggerRow[] }) {
  const { t } = useT("common")
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <section aria-label={t("spending.trigger_aria")} className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <TableHeader title={t("spending.by_trigger_kind")} />
      {rows.length === 0 ? <EmptyTable label={t("spending.empty_trigger")} /> : (
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <SortableHeader label={t("spending.col_trigger")} sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label={t("spending.col_runs")} sortKey="runs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("spending.col_total")} sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("spending.col_avg_run")} sortKey="average_usd" sort={sort} setSort={setSort} align="right" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 bg-white dark:bg-gray-900">
            {sorted.map((row) => (
              <tr key={row.trigger_kind}>
                <td className="px-4 py-3 font-medium text-gray-900 dark:text-gray-100">{humanize(row.trigger_kind)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{row.runs_count}</td>
                <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900 dark:text-gray-100">{formatCurrency(row.total_usd)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{formatCurrency(row.average_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function TopRunsTable({ payload, prefix }: { payload: SpendingPayload; prefix: string }) {
  const { t } = useT("common")
  return (
    <section aria-label={t("spending.top_runs_aria")} className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <TableHeader title={t("spending.top_runs")} />
      {payload.top_runs.length === 0 ? <EmptyTable label={t("spending.empty_top_runs")} /> : (
        <div className="overflow-x-auto">
          <table className="min-w-[56rem] table-fixed divide-y divide-gray-200 dark:divide-gray-700 text-sm w-full">
            <colgroup>
              <col className="w-1/4" />
              <col className="w-1/2" />
              <col className="w-40" />
              <col className="w-28" />
            </colgroup>
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2 font-medium">{t("spending.col_run")}</th>
                <th className="px-4 py-2 font-medium">{t("spending.col_job")}</th>
                <th className="px-4 py-2 font-medium">{t("spending.col_repository")}</th>
                <th className="px-4 py-2 text-right font-medium">{t("spending.col_cost")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 bg-white dark:bg-gray-900">
              {payload.top_runs.map((run) => (
                <tr key={run.id}>
                  <td className="px-4 py-3">
                    <div className="font-medium text-gray-900 dark:text-gray-100">{t("spending.run_number", { id: run.id })}</div>
                    <div className="text-xs text-gray-500 dark:text-gray-400">{humanize(run.trigger_kind)} / {run.agent_provider}</div>
                  </td>
                  <td className="max-w-0 px-4 py-3">
                    <Link className="block truncate text-blue-700 dark:text-blue-300 underline hover:no-underline" title={run.job.title || `JOB-${run.job.id}`} to={withRoutePrefix(run.job.path, prefix)}>{run.job.title || `JOB-${run.job.id}`}</Link>
                    {run.epic ? <div className="truncate text-xs text-gray-500 dark:text-gray-400" title={`${run.epic.display_number} / ${run.epic.title}`}>{run.epic.display_number} / {run.epic.title}</div> : null}
                  </td>
                  <td className="max-w-0 px-4 py-3">
                    <Link className="block truncate font-mono text-xs text-blue-700 dark:text-blue-300 underline hover:no-underline" title={run.repository.slug} to={withRoutePrefix(run.repository.path, prefix)}>{run.repository.slug}</Link>
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900 dark:text-gray-100">{formatCurrency(run.cost_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function TableHeader({ title }: { title: string }) {
  return <h2 className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-base font-semibold text-gray-900 dark:text-gray-100">{title}</h2>
}

function EmptyTable({ label }: { label: string }) {
  return <div className="px-4 py-8 text-sm text-gray-500 dark:text-gray-400">{label}</div>
}

function SortableHeader({ label, sortKey, sort, setSort, align = "left" }: { label: string; sortKey: SortKey; sort: SortState; setSort: (sort: SortState) => void; align?: "left" | "right" }) {
  const { t } = useT("common")
  const active = sort.key === sortKey
  const nextDirection = active && sort.direction === "desc" ? "asc" : "desc"
  return (
    <th className={`px-4 py-2 font-medium ${align === "right" ? "text-right" : "text-left"}`}>
      <button className="inline-flex items-center gap-1 hover:text-gray-900 dark:hover:text-gray-100" type="button" onClick={() => setSort({ key: sortKey, direction: nextDirection })}>
        {label}
        <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{active ? (sort.direction === "desc" ? t("spending.sort_desc") : t("spending.sort_asc")) : t("spending.sort_none")}</span>
      </button>
    </th>
  )
}

function sortRows<T extends SpendingBreakdownRow | SpendingTriggerRow>(rows: T[], sort: SortState) {
  return [...rows].sort((a, b) => {
    const aValue = sortValue(a, sort.key)
    const bValue = sortValue(b, sort.key)
    const comparison = typeof aValue === "string" || typeof bValue === "string"
      ? String(aValue).localeCompare(String(bValue))
      : Number(aValue) - Number(bValue)

    return sort.direction === "asc" ? comparison : -comparison
  })
}

function sortValue(row: SpendingBreakdownRow | SpendingTriggerRow, key: SortKey) {
  if (key === "label") return "label" in row ? row.label : row.trigger_kind
  if (key === "jobs_count") return row.jobs_count
  if (key === "total_usd") return row.total_usd
  if (key === "runs_count") return "runs_count" in row ? row.runs_count : 0
  if (key === "average_usd") return "average_usd" in row ? row.average_usd : 0
  if (key === "last_30_days_usd") return "last_30_days_usd" in row ? row.last_30_days_usd || 0 : 0
  return "average_job_usd" in row ? row.average_job_usd : 0
}

function humanize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}

