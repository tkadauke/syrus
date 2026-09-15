import { withRoutePrefix } from "@app/lib/routing"
import { formatCurrency } from "@app/lib/format"
import { FilterBar } from "@app/components/FilterBar"
import { DataTable, LinkText, Metric as MetricUi, Notice, Page, Section, Text } from "@app/components/ui"
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
      <Page.Root aria-label={t("aria_insights")} size="wide">
        <Text muted>{t("common:loading")}</Text>
      </Page.Root>
    )
  }
  if (spending.isError) {
    return (
      <Page.Root aria-label={t("aria_insights")} size="wide">
        <Notice tone="danger">{t("unable_to_load")}</Notice>
      </Page.Root>
    )
  }

  return <SpendingInsights payload={spending.data} pathname={location.pathname} search={location.search} />
}

function SpendingInsights({ payload, pathname, search }: { payload: SpendingPayload; pathname: string; search: string }) {
  const { t } = useT("spending")
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""

  return (
    <Page.Root aria-label={t("aria_insights")} size="wide">
      <Page.Header>
        <Page.HeadingGroup>
          <Text variant="label" muted>
            {t("eyebrow")}
          </Text>
          <Page.Title>{t("title")}</Page.Title>
          <Page.Description>
            {t("scope_range", {
              scope: payload.scope.admin ? t("scope_all_users") : payload.scope.label,
              start: payload.filters.start_date,
              end: payload.filters.end_date
            })}
          </Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      <FilterBar
        filter={payload.filter}
        filterSchema={payload.controls.filter_schema}
        legacyFilterKeys={legacyFilterKeys}
        pathname={pathname}
        search={search}
      />

      <MetricUi.Group aria-label={t("totals_aria")} className="sm:grid-cols-2 xl:grid-cols-5">
        <SpendingMetric title={t("metric_week")} value={formatSpendingCurrency(payload.totals.week_usd)} context={t("context_workflow_runs")} />
        <SpendingMetric title={t("metric_month")} value={formatSpendingCurrency(payload.totals.month_usd)} context={t("context_workflow_runs")} />
        <SpendingMetric
          title={t("metric_lifetime")}
          value={formatSpendingCurrency(payload.totals.lifetime_usd)}
          context={t("context_runs_chats", {
            runs: formatSpendingCurrency(payload.totals.workflow_lifetime_usd),
            chats: formatSpendingCurrency(payload.totals.chat_lifetime_usd)
          })}
        />
        <SpendingMetric title={t("metric_avg_job")} value={formatSpendingCurrency(payload.totals.average_job_30d_usd)} context={t("context_last_30_days")} />
        <SpendingMetric
          title={t("metric_avg_merged_pr")}
          value={formatSpendingCurrency(payload.totals.average_merged_pr_30d_usd)}
          context={t("context_last_30_days")}
        />
      </MetricUi.Group>

      <Section.Root aria-label={t("trend_aria")}>
        <Section.Header className="mb-3">
          <Section.Title>{t("trend")}</Section.Title>
          <Text as="span" variant="caption" muted>
            {t("trend_days", { count: payload.trend.length })}
          </Text>
        </Section.Header>
        <TrendChart points={payload.trend} />
      </Section.Root>

      <div className="grid gap-5 xl:grid-cols-2">
        <BreakdownTable
          title={t("by_epic")}
          entityLabel={t("entity_epic")}
          rows={payload.breakdowns.epics}
          prefix={prefix}
          columns="standard"
          emptyLabel={t("empty_epic")}
        />
        <BreakdownTable
          title={t("by_user")}
          entityLabel={t("entity_user")}
          rows={payload.breakdowns.users}
          prefix={prefix}
          columns="users"
          emptyLabel={t("empty_user")}
        />
        <BreakdownTable
          title={t("by_repository")}
          entityLabel={t("entity_repository")}
          rows={payload.breakdowns.repositories}
          prefix={prefix}
          columns="standard"
          emptyLabel={t("empty_repository")}
        />
        <TriggerTable rows={payload.breakdowns.trigger_kinds} />
      </div>

      <TopRunsTable payload={payload} prefix={prefix} />
    </Page.Root>
  )
}

const legacyFilterKeys = ["start_date", "end_date", "repository_id", "epic_id", "user_id", "agent_provider", "trigger_kind"]

function SpendingMetric({ title, value, context }: { title: string; value: string; context: string }) {
  return <MetricUi.Card description={context} label={title} value={value} />
}

function TrendChart({ points }: { points: SpendingPayload["trend"] }) {
  const { t } = useT("spending")
  const max = Math.max(...points.map((point) => point.total_usd), 0)
  const width = Math.max(points.length * 7, 320)

  if (points.length === 0) {
    return (
      <Text className="flex h-48 items-center justify-center" muted>
        {t("no_spending")}
      </Text>
    )
  }

  return (
    <div className="overflow-x-auto">
      <svg aria-label={t("daily_spend")} className="h-48 min-w-full" role="img" viewBox={`0 0 ${width} 180`} preserveAspectRatio="none">
        <line x1="0" y1="160" x2={width} y2="160" stroke="#e5e7eb" />
        {points.map((point, index) => {
          const barHeight = max > 0 ? Math.max(2, (point.total_usd / max) * 145) : 0
          return (
            <rect fill="#b6492e" height={barHeight} key={point.date} rx="1" width="4" x={index * 7 + 1} y={160 - barHeight}>
              <title>
                {point.date}: {formatSpendingCurrency(point.total_usd)}
              </title>
            </rect>
          )
        })}
      </svg>
    </div>
  )
}

function BreakdownTable({
  title,
  entityLabel,
  rows,
  prefix,
  columns,
  emptyLabel
}: {
  title: string
  entityLabel: string
  rows: SpendingBreakdownRow[]
  prefix: string
  columns: "standard" | "users"
  emptyLabel: string
}) {
  const { t } = useT("spending")
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <Section.Root aria-label={title} padding="none">
      <TableHeader title={title} />
      {rows.length === 0 ? (
        <EmptyTable label={emptyLabel} />
      ) : (
        <DataTable.Root className="min-w-[40rem] table-fixed w-full" wrapperClassName="rounded-none border-0">
          <colgroup>
            <col />
            <col className="w-20" />
            <col className="w-32" />
            <col className="w-32" />
          </colgroup>
          <DataTable.Header>
            <DataTable.Row>
              <SortableHeader label={entityLabel} sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label={t("col_jobs")} sortKey="jobs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("col_total")} sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader
                label={columns === "users" ? t("col_last_30") : t("col_avg_job")}
                sortKey={columns === "users" ? "last_30_days_usd" : "average_job_usd"}
                sort={sort}
                setSort={setSort}
                align="right"
              />
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {sorted.map((row) => (
              <DataTable.Row key={row.id}>
                <DataTable.Cell className="max-w-0">
                  <LinkText className="block truncate" title={breakdownLabel(row)} to={withRoutePrefix(row.path, prefix)}>
                    {breakdownLabel(row)}
                  </LinkText>
                </DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums text-text-muted">
                  {row.jobs_count}
                </DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums font-medium">
                  {formatSpendingCurrency(row.total_usd)}
                </DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums text-text-muted">
                  {formatSpendingCurrency(columns === "users" ? row.last_30_days_usd || 0 : row.average_job_usd)}
                </DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
    </Section.Root>
  )
}

function TriggerTable({ rows }: { rows: SpendingTriggerRow[] }) {
  const { t } = useT("spending")
  const [sort, setSort] = useState<SortState>({ key: "total_usd", direction: "desc" })
  const sorted = useMemo(() => sortRows(rows, sort), [rows, sort])

  return (
    <Section.Root aria-label={t("trigger_aria")} padding="none">
      <TableHeader title={t("by_trigger_kind")} />
      {rows.length === 0 ? (
        <EmptyTable label={t("empty_trigger")} />
      ) : (
        <DataTable.Root wrapperClassName="rounded-none border-0">
          <DataTable.Header>
            <DataTable.Row>
              <SortableHeader label={t("col_trigger")} sortKey="label" sort={sort} setSort={setSort} />
              <SortableHeader label={t("col_runs")} sortKey="runs_count" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("col_total")} sortKey="total_usd" sort={sort} setSort={setSort} align="right" />
              <SortableHeader label={t("col_avg_run")} sortKey="average_usd" sort={sort} setSort={setSort} align="right" />
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {sorted.map((row) => (
              <DataTable.Row key={row.trigger_kind}>
                <DataTable.Cell className="font-medium">{humanize(row.trigger_kind)}</DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums text-text-muted">
                  {row.runs_count}
                </DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums font-medium">
                  {formatSpendingCurrency(row.total_usd)}
                </DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums text-text-muted">
                  {formatSpendingCurrency(row.average_usd)}
                </DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
    </Section.Root>
  )
}

function TopRunsTable({ payload, prefix }: { payload: SpendingPayload; prefix: string }) {
  const { t } = useT("spending")
  return (
    <Section.Root aria-label={t("top_runs_aria")} padding="none">
      <TableHeader title={t("top_runs")} />
      {payload.top_runs.length === 0 ? (
        <EmptyTable label={t("empty_top_runs")} />
      ) : (
        <DataTable.Root className="min-w-[56rem] table-fixed w-full" wrapperClassName="rounded-none border-0">
          <colgroup>
            <col className="w-1/4" />
            <col className="w-1/2" />
            <col className="w-40" />
            <col className="w-28" />
          </colgroup>
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("col_run")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_job")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("col_repository")}</DataTable.HeadCell>
              <DataTable.HeadCell align="right">{t("col_cost")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {payload.top_runs.map((run) => (
              <DataTable.Row key={run.id}>
                <DataTable.Cell>
                  <Text as="div" className="font-medium">
                    {t("run_number", { id: run.id })}
                  </Text>
                  <Text as="div" variant="caption" muted>
                    {humanize(run.trigger_kind)} / {run.agent_provider}
                  </Text>
                </DataTable.Cell>
                <DataTable.Cell className="max-w-0">
                  <LinkText className="block truncate" title={run.job.title || `JOB-${run.job.id}`} to={withRoutePrefix(run.job.path, prefix)}>
                    {run.job.title || `JOB-${run.job.id}`}
                  </LinkText>
                  {run.epic ? (
                    <Text as="div" className="truncate" title={`${run.epic.display_number} / ${run.epic.title}`} variant="caption" muted>
                      {run.epic.display_number} / {run.epic.title}
                    </Text>
                  ) : null}
                </DataTable.Cell>
                <DataTable.Cell className="max-w-0">
                  <LinkText className="block truncate font-mono text-xs" title={run.repository.slug} to={withRoutePrefix(run.repository.path, prefix)}>
                    {run.repository.slug}
                  </LinkText>
                </DataTable.Cell>
                <DataTable.Cell align="right" className="tabular-nums font-medium">
                  {formatSpendingCurrency(run.cost_usd)}
                </DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
    </Section.Root>
  )
}

function TableHeader({ title }: { title: string }) {
  return (
    <Section.Header className="border-b border-border px-4 py-3">
      <Section.Title>{title}</Section.Title>
    </Section.Header>
  )
}

function EmptyTable({ label }: { label: string }) {
  return (
    <Text className="px-4 py-8" muted>
      {label}
    </Text>
  )
}

function SortableHeader({
  label,
  sortKey,
  sort,
  setSort,
  align = "left"
}: {
  label: string
  sortKey: SortKey
  sort: SortState
  setSort: (sort: SortState) => void
  align?: "left" | "right"
}) {
  const active = sort.key === sortKey
  const nextDirection = active && sort.direction === "desc" ? "asc" : "desc"
  return (
    <DataTable.HeadCell
      align={align}
      onSort={() => setSort({ key: sortKey, direction: nextDirection })}
      sortDirection={active ? (sort.direction === "desc" ? "descending" : "ascending") : "none"}
    >
      {label}
    </DataTable.HeadCell>
  )
}

function sortRows<T extends SpendingBreakdownRow | SpendingTriggerRow>(rows: T[], sort: SortState) {
  return [...rows].sort((a, b) => {
    const aValue = sortValue(a, sort.key)
    const bValue = sortValue(b, sort.key)
    const comparison = typeof aValue === "string" || typeof bValue === "string" ? String(aValue).localeCompare(String(bValue)) : Number(aValue) - Number(bValue)

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
