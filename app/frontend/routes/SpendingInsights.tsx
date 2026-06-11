import { useQuery } from "@tanstack/react-query"
import { useMemo, useState, type FormEvent } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { fetchSpending, type SpendingBreakdownRow, type SpendingPayload, type SpendingTriggerRow } from "../api/spending"

type SortKey = "label" | "jobs_count" | "total_usd" | "average_job_usd" | "last_30_days_usd" | "runs_count" | "average_usd"
type SortState = { key: SortKey; direction: "asc" | "desc" }

export function SpendingInsightsRoute() {
  const location = useLocation()
  const spending = useQuery({
    queryKey: ["insights", "spending", location.search],
    queryFn: () => fetchSpending(location.search)
  })

  if (spending.isPending) return <main aria-label="Spending insights" className="p-6 text-sm text-gray-600">Loading...</main>
  if (spending.isError) {
    return (
      <main aria-label="Spending insights" className="p-6">
        <p className="text-sm text-red-700">Unable to load spending insights.</p>
      </main>
    )
  }

  return <SpendingInsights payload={spending.data} pathname={location.pathname} search={location.search} />
}

function SpendingInsights({ payload, pathname, search }: { payload: SpendingPayload; pathname: string; search: string }) {
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""

  return (
    <main aria-label="Spending insights" className="mx-auto max-w-[96rem] space-y-5 p-6">
      <header className="flex flex-col gap-4 border-b border-gray-200 pb-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500">Insights</p>
          <h1 className="mt-1 text-3xl font-semibold text-gray-900">Spending</h1>
          <p className="mt-2 text-sm text-gray-600">{payload.scope.label} / {payload.filters.start_date} to {payload.filters.end_date}</p>
        </div>
        <DateRangeForm pathname={pathname} search={search} payload={payload} />
      </header>

      <section aria-label="Spending totals" className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        <Metric title="This week" value={formatCurrency(payload.totals.week_usd)} context="Workflow runs" />
        <Metric title="This month" value={formatCurrency(payload.totals.month_usd)} context="Workflow runs" />
        <Metric title="Lifetime" value={formatCurrency(payload.totals.lifetime_usd)} context={`Runs ${formatCurrency(payload.totals.workflow_lifetime_usd)} / chats ${formatCurrency(payload.totals.chat_lifetime_usd)}`} />
        <Metric title="Avg job" value={formatCurrency(payload.totals.average_job_30d_usd)} context="Last 30 days" />
        <Metric title="Avg merged PR" value={formatCurrency(payload.totals.average_merged_pr_30d_usd)} context="Last 30 days" />
      </section>

      <section aria-label="Spend trend" className="rounded border border-gray-200 bg-white p-4">
        <div className="mb-3 flex items-center justify-between gap-3">
          <h2 className="text-base font-semibold text-gray-900">Trend</h2>
          <span className="text-xs text-gray-500">{payload.trend.length} days</span>
        </div>
        <TrendChart points={payload.trend} />
      </section>

      <div className="grid gap-5 xl:grid-cols-2">
        <BreakdownTable title="By Epic" rows={payload.breakdowns.epics} prefix={prefix} columns="standard" emptyLabel="No Epic spend in this window." />
        <BreakdownTable title="By User" rows={payload.breakdowns.users} prefix={prefix} columns="users" emptyLabel="No user spend in this window." />
        <BreakdownTable title="By Repository" rows={payload.breakdowns.repositories} prefix={prefix} columns="standard" emptyLabel="No repository spend in this window." />
        <TriggerTable rows={payload.breakdowns.trigger_kinds} />
      </div>

      <TopRunsTable payload={payload} prefix={prefix} />
    </main>
  )
}

function DateRangeForm({ pathname, search, payload }: { pathname: string; search: string; payload: SpendingPayload }) {
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
      <label className="grid gap-1 text-xs font-medium text-gray-600">
        Start
        <input className="rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900" type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} />
      </label>
      <label className="grid gap-1 text-xs font-medium text-gray-600">
        End
        <input className="rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900" type="date" value={endDate} onChange={(event) => setEndDate(event.target.value)} />
      </label>
      {showAgentProvider ? (
        <label className="grid gap-1 text-xs font-medium text-gray-600">
          Model
          <select className="rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900" value={agentProvider} onChange={(event) => setAgentProvider(event.target.value)}>
            <option value="">All models</option>
            {payload.filters.agent_providers.map((provider) => (
              <option key={provider.value} value={provider.value}>{provider.label}</option>
            ))}
          </select>
        </label>
      ) : null}
      <button className="rounded bg-gray-900 px-4 py-2 text-sm font-medium text-white hover:bg-gray-700" type="submit">Apply</button>
    </form>
  )
}

function Metric({ title, value, context }: { title: string; value: string; context: string }) {
  return (
    <article className="rounded border border-gray-200 bg-white p-4">
      <h2 className="text-sm font-medium text-gray-700">{title}</h2>
      <p className="mt-2 text-3xl font-semibold text-gray-900">{value}</p>
      <p className="mt-1 truncate text-xs text-gray-500">{context}</p>
    </article>
  )
}

function TrendChart({ points }: { points: SpendingPayload["trend"] }) {
  const max = Math.max(...points.map((point) => point.total_usd), 0)
  const width = Math.max(points.length * 7, 320)

  if (points.length === 0) {
    return <div className="flex h-48 items-center justify-center text-sm text-gray-500">No spending in this window.</div>
  }

  return (
    <div className="overflow-x-auto">
      <svg aria-label="Daily spend" className="h-48 min-w-full" role="img" viewBox={`0 0 ${width} 180`} preserveAspectRatio="none">
        <line x1="0" y1="160" x2={width} y2="160" stroke="#e5e7eb" />
        {points.map((point, index) => {
          const barHeight = max > 0 ? Math.max(2, (point.total_usd / max) * 145) : 0
          return (
            <rect
              fill="#2563eb"
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

function BreakdownTable({ title, rows, prefix, columns, emptyLabel }: { title: string; rows: SpendingBreakdownRow[]; prefix: string; columns: "standard" | "users"; emptyLabel: string }) {
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <section aria-label={title} className="overflow-hidden rounded border border-gray-200 bg-white">
      <TableHeader title={title} />
      {rows.length === 0 ? <EmptyTable label={emptyLabel} /> : (
        <table className="min-w-full divide-y divide-gray-200 text-sm">
          <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
            <tr>
              <SortableHeader label={title.replace("By ", "")} sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label="Jobs" sortKey="jobs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label="Total" sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={columns === "users" ? "Last 30" : "Avg job"} sortKey={columns === "users" ? "last_30_days_usd" : "average_job_usd"} sort={sort} setSort={setSort} align="right" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white">
            {sorted.map((row) => (
              <tr key={row.id}>
                <td className="max-w-0 px-4 py-3">
                  <Link className="truncate font-medium text-blue-700 underline hover:no-underline" to={withRoutePrefix(row.path, prefix)}>
                    {row.display_number ? `${row.display_number} / ${row.label}` : row.label}
                  </Link>
                </td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700">{row.jobs_count}</td>
                <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900">{formatCurrency(row.total_usd)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700">{formatCurrency(columns === "users" ? row.last_30_days_usd || 0 : row.average_job_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function TriggerTable({ rows }: { rows: SpendingTriggerRow[] }) {
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <section aria-label="By Trigger kind" className="overflow-hidden rounded border border-gray-200 bg-white">
      <TableHeader title="By Trigger Kind" />
      {rows.length === 0 ? <EmptyTable label="No trigger spend in this window." /> : (
        <table className="min-w-full divide-y divide-gray-200 text-sm">
          <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
            <tr>
              <SortableHeader label="Trigger" sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label="Runs" sortKey="runs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label="Total" sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label="Avg run" sortKey="average_usd" sort={sort} setSort={setSort} align="right" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white">
            {sorted.map((row) => (
              <tr key={row.trigger_kind}>
                <td className="px-4 py-3 font-medium text-gray-900">{humanize(row.trigger_kind)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700">{row.runs_count}</td>
                <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900">{formatCurrency(row.total_usd)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700">{formatCurrency(row.average_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function TopRunsTable({ payload, prefix }: { payload: SpendingPayload; prefix: string }) {
  return (
    <section aria-label="Top runs" className="overflow-hidden rounded border border-gray-200 bg-white">
      <TableHeader title="Top Runs" />
      {payload.top_runs.length === 0 ? <EmptyTable label="No billed runs in this window." /> : (
        <table className="min-w-full divide-y divide-gray-200 text-sm">
          <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">Run</th>
              <th className="px-4 py-2 font-medium">Job</th>
              <th className="px-4 py-2 font-medium">Repository</th>
              <th className="px-4 py-2 text-right font-medium">Cost</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white">
            {payload.top_runs.map((run) => (
              <tr key={run.id}>
                <td className="px-4 py-3">
                  <div className="font-medium text-gray-900">Run #{run.id}</div>
                  <div className="text-xs text-gray-500">{humanize(run.trigger_kind)} / {run.agent_provider}</div>
                </td>
                <td className="max-w-0 px-4 py-3">
                  <Link className="truncate text-blue-700 underline hover:no-underline" to={withRoutePrefix(run.job.path, prefix)}>{run.job.title || `Job #${run.job.id}`}</Link>
                  {run.epic ? <div className="truncate text-xs text-gray-500">{run.epic.display_number} / {run.epic.title}</div> : null}
                </td>
                <td className="px-4 py-3">
                  <Link className="font-mono text-xs text-blue-700 underline hover:no-underline" to={withRoutePrefix(run.repository.path, prefix)}>{run.repository.slug}</Link>
                </td>
                <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900">{formatCurrency(run.cost_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function TableHeader({ title }: { title: string }) {
  return <h2 className="border-b border-gray-200 px-4 py-3 text-base font-semibold text-gray-900">{title}</h2>
}

function EmptyTable({ label }: { label: string }) {
  return <div className="px-4 py-8 text-sm text-gray-500">{label}</div>
}

function SortableHeader({ label, sortKey, sort, setSort, align = "left" }: { label: string; sortKey: SortKey; sort: SortState; setSort: (sort: SortState) => void; align?: "left" | "right" }) {
  const active = sort.key === sortKey
  const nextDirection = active && sort.direction === "desc" ? "asc" : "desc"
  return (
    <th className={`px-4 py-2 font-medium ${align === "right" ? "text-right" : "text-left"}`}>
      <button className="inline-flex items-center gap-1 hover:text-gray-900" type="button" onClick={() => setSort({ key: sortKey, direction: nextDirection })}>
        {label}
        <span aria-hidden="true" className="text-gray-400">{active ? (sort.direction === "desc" ? "desc" : "asc") : "sort"}</span>
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

function formatCurrency(value: number) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: value >= 10 ? 2 : 4 }).format(value)
}

function humanize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return path.startsWith("/") ? `${prefix}${path}` : path
}
