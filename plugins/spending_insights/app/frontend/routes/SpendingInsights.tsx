import { withRoutePrefix } from "@app/lib/routing"
import { formatCurrency } from "@app/lib/format"
import { FilterBar } from "@app/components/FilterBar"
import { Notice, Page, PageDescription, PageHeader, PageHeading, Section, SectionHeading, Text } from "@app/components/pluginUi"
import { useQuery } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { fetchSpending, type SpendingBreakdownRow, type SpendingPayload, type SpendingTriggerRow } from "../api/spending"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"

type SortKey = "label" | "jobs_count" | "total_usd" | "average_job_usd" | "last_30_days_usd" | "runs_count" | "average_usd"
type SortState = { key: SortKey; direction: "asc" | "desc" }
const formatSpendingCurrency = (value: number) => formatCurrency(value, 2)

export function SpendingInsightsRoute() {
  const { t } = useT("spending")
  usePageTitle(t("title"))
  const location = useLocation()
  const spending = useQuery({
    queryKey: ["insights", "spending", location.search],
    queryFn: () => fetchSpending(location.search)
  })

  if (spending.isPending) {
    return (
      <Page aria-label={t("aria_insights")} size="wide">
        <Notice>{t("common:loading")}</Notice>
      </Page>
    )
  }
  if (spending.isError) {
    return (
      <Page aria-label={t("aria_insights")} size="wide">
        <Notice tone="error">{t("unable_to_load")}</Notice>
      </Page>
    )
  }

  return <SpendingInsights payload={spending.data} pathname={location.pathname} search={location.search} />
}

function SpendingInsights({ payload, pathname, search }: { payload: SpendingPayload; pathname: string; search: string }) {
  const { t } = useT("spending")
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""

  return (
    <Page aria-label={t("aria_insights")} className="space-y-5" size="wide">
      <PageHeader className="flex flex-col gap-4 border-b border-border pb-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <Text className="font-medium uppercase" size="xs" tone="muted">{t("eyebrow")}</Text>
          <PageHeading>{t("title")}</PageHeading>
          <PageDescription>{t("scope_range", { scope: payload.scope.admin ? t("scope_all_users") : payload.scope.label, start: payload.filters.start_date, end: payload.filters.end_date })}</PageDescription>
        </div>
      </PageHeader>

      <FilterBar
        filter={payload.filter}
        filterSchema={payload.controls.filter_schema}
        legacyFilterKeys={legacyFilterKeys}
        pathname={pathname}
        search={search}
      />

      <section aria-label={t("totals_aria")} className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        <Metric title={t("metric_week")} value={formatSpendingCurrency(payload.totals.week_usd)} context={t("context_workflow_runs")} />
        <Metric title={t("metric_month")} value={formatSpendingCurrency(payload.totals.month_usd)} context={t("context_workflow_runs")} />
        <Metric title={t("metric_lifetime")} value={formatSpendingCurrency(payload.totals.lifetime_usd)} context={t("context_runs_chats", { runs: formatSpendingCurrency(payload.totals.workflow_lifetime_usd), chats: formatSpendingCurrency(payload.totals.chat_lifetime_usd) })} />
        <Metric title={t("metric_avg_job")} value={formatSpendingCurrency(payload.totals.average_job_30d_usd)} context={t("context_last_30_days")} />
        <Metric title={t("metric_avg_merged_pr")} value={formatSpendingCurrency(payload.totals.average_merged_pr_30d_usd)} context={t("context_last_30_days")} />
      </section>

      <Section aria-label={t("trend_aria")}>
        <div className="mb-3 flex items-center justify-between gap-3">
          <SectionHeading>{t("trend")}</SectionHeading>
          <Text as="span" size="xs" tone="muted">{t("trend_days", { count: payload.trend.length })}</Text>
        </div>
        <TrendChart points={payload.trend} />
      </Section>

      <div className="grid gap-5 xl:grid-cols-2">
        <BreakdownTable title={t("by_epic")} entityLabel={t("entity_epic")} rows={payload.breakdowns.epics} prefix={prefix} columns="standard" emptyLabel={t("empty_epic")} />
        <BreakdownTable title={t("by_user")} entityLabel={t("entity_user")} rows={payload.breakdowns.users} prefix={prefix} columns="users" emptyLabel={t("empty_user")} />
        <BreakdownTable title={t("by_repository")} entityLabel={t("entity_repository")} rows={payload.breakdowns.repositories} prefix={prefix} columns="standard" emptyLabel={t("empty_repository")} />
        <TriggerTable rows={payload.breakdowns.trigger_kinds} />
      </div>

      <TopRunsTable payload={payload} prefix={prefix} />
    </Page>
  )
}

const legacyFilterKeys = ["start_date", "end_date", "repository_id", "epic_id", "user_id", "agent_provider", "trigger_kind"]

function Metric({ title, value, context }: { title: string; value: string; context: string }) {
  return (
    <Section as="article">
      <Text className="font-medium" tone="secondary">{title}</Text>
      <Text className="mt-2 text-3xl font-semibold" size="base" tone="primary">{value}</Text>
      <Text className="mt-1 truncate" size="xs" tone="muted">{context}</Text>
    </Section>
  )
}

function TrendChart({ points }: { points: SpendingPayload["trend"] }) {
  const { t } = useT("spending")
  const max = Math.max(...points.map((point) => point.total_usd), 0)
  const width = Math.max(points.length * 7, 320)

  if (points.length === 0) {
    return <div className="flex h-48 items-center justify-center text-sm text-gray-500 dark:text-gray-400">{t("no_spending")}</div>
  }

  return (
    <div className="overflow-x-auto">
      <svg aria-label={t("daily_spend")} className="h-48 min-w-full" role="img" viewBox={`0 0 ${width} 180`} preserveAspectRatio="none">
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
              <title>{point.date}: {formatSpendingCurrency(point.total_usd)}</title>
            </rect>
          )
        })}
      </svg>
    </div>
  )
}

function BreakdownTable({ title, entityLabel, rows, prefix, columns, emptyLabel }: { title: string; entityLabel: string; rows: SpendingBreakdownRow[]; prefix: string; columns: "standard" | "users"; emptyLabel: string }) {
  const { t } = useT("spending")
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <Section aria-label={title} className="overflow-hidden p-0">
      <TableHeader title={title} />
      {rows.length === 0 ? <EmptyTable label={emptyLabel} /> : (
        <div className="overflow-x-auto">
          <table className="min-w-[40rem] table-fixed w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
            <colgroup>
              <col />
              <col className="w-20" />
              <col className="w-32" />
              <col className="w-32" />
            </colgroup>
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <SortableHeader label={entityLabel} sortKey="label" sort={sort} setSort={setSort} />
                <SortableHeader label={t("col_jobs")} sortKey="jobs_count" sort={sort} setSort={setSort} align="right" />
                <SortableHeader label={t("col_total")} sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
                <SortableHeader label={columns === "users" ? t("col_last_30") : t("col_avg_job")} sortKey={columns === "users" ? "last_30_days_usd" : "average_job_usd"} sort={sort} setSort={setSort} align="right" />
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 bg-white dark:bg-gray-900">
              {sorted.map((row) => (
                <tr key={row.id}>
                  <td className="max-w-0 px-4 py-3">
                    <Link className="block truncate font-medium text-brand dark:text-brand-emphasis underline hover:no-underline" title={breakdownLabel(row)} to={withRoutePrefix(row.path, prefix)}>
                      {breakdownLabel(row)}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{row.jobs_count}</td>
                  <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900 dark:text-gray-100">{formatSpendingCurrency(row.total_usd)}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{formatSpendingCurrency(columns === "users" ? row.last_30_days_usd || 0 : row.average_job_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Section>
  )
}

function TriggerTable({ rows }: { rows: SpendingTriggerRow[] }) {
  const { t } = useT("spending")
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <Section aria-label={t("trigger_aria")} className="overflow-hidden p-0">
      <TableHeader title={t("by_trigger_kind")} />
      {rows.length === 0 ? <EmptyTable label={t("empty_trigger")} /> : (
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <SortableHeader label={t("col_trigger")} sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label={t("col_runs")} sortKey="runs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("col_total")} sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("col_avg_run")} sortKey="average_usd" sort={sort} setSort={setSort} align="right" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 bg-white dark:bg-gray-900">
            {sorted.map((row) => (
              <tr key={row.trigger_kind}>
                <td className="px-4 py-3 font-medium text-gray-900 dark:text-gray-100">{humanize(row.trigger_kind)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{row.runs_count}</td>
                <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900 dark:text-gray-100">{formatSpendingCurrency(row.total_usd)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-gray-700 dark:text-gray-300">{formatSpendingCurrency(row.average_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Section>
  )
}

function TopRunsTable({ payload, prefix }: { payload: SpendingPayload; prefix: string }) {
  const { t } = useT("spending")
  return (
    <Section aria-label={t("top_runs_aria")} className="overflow-hidden p-0">
      <TableHeader title={t("top_runs")} />
      {payload.top_runs.length === 0 ? <EmptyTable label={t("empty_top_runs")} /> : (
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
                <th className="px-4 py-2 font-medium">{t("col_run")}</th>
                <th className="px-4 py-2 font-medium">{t("col_job")}</th>
                <th className="px-4 py-2 font-medium">{t("col_repository")}</th>
                <th className="px-4 py-2 text-right font-medium">{t("col_cost")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 bg-white dark:bg-gray-900">
              {payload.top_runs.map((run) => (
                <tr key={run.id}>
                  <td className="px-4 py-3">
                    <div className="font-medium text-gray-900 dark:text-gray-100">{t("run_number", { id: run.id })}</div>
                    <div className="text-xs text-gray-500 dark:text-gray-400">{humanize(run.trigger_kind)} / {run.agent_provider}</div>
                  </td>
                  <td className="max-w-0 px-4 py-3">
                    <Link className="block truncate text-brand dark:text-brand-emphasis underline hover:no-underline" title={run.job.title || `JOB-${run.job.id}`} to={withRoutePrefix(run.job.path, prefix)}>{run.job.title || `JOB-${run.job.id}`}</Link>
                    {run.epic ? <div className="truncate text-xs text-gray-500 dark:text-gray-400" title={`${run.epic.display_number} / ${run.epic.title}`}>{run.epic.display_number} / {run.epic.title}</div> : null}
                  </td>
                  <td className="max-w-0 px-4 py-3">
                    <Link className="block truncate font-mono text-xs text-brand dark:text-brand-emphasis underline hover:no-underline" title={run.repository.slug} to={withRoutePrefix(run.repository.path, prefix)}>{run.repository.slug}</Link>
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900 dark:text-gray-100">{formatSpendingCurrency(run.cost_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Section>
  )
}

function TableHeader({ title }: { title: string }) {
  return <SectionHeading className="border-b border-border px-4 py-3">{title}</SectionHeading>
}

function EmptyTable({ label }: { label: string }) {
  return <div className="px-4 py-8 text-sm text-gray-500 dark:text-gray-400">{label}</div>
}

function SortableHeader({ label, sortKey, sort, setSort, align = "left" }: { label: string; sortKey: SortKey; sort: SortState; setSort: (sort: SortState) => void; align?: "left" | "right" }) {
  const { t } = useT("spending")
  const active = sort.key === sortKey
  const nextDirection = active && sort.direction === "desc" ? "asc" : "desc"
  return (
    <th className={`px-4 py-2 font-medium ${align === "right" ? "text-right" : "text-left"}`}>
      <button className="inline-flex items-center gap-1 hover:text-gray-900 dark:hover:text-gray-100" type="button" onClick={() => setSort({ key: sortKey, direction: nextDirection })}>
        {label}
        <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{active ? (sort.direction === "desc" ? t("sort_desc") : t("sort_asc")) : t("sort_none")}</span>
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

function breakdownLabel(row: SpendingBreakdownRow) {
  return row.display_number ? `${row.display_number} / ${row.label}` : row.label
}

function humanize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}

export default SpendingInsightsRoute
