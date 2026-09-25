import { withRoutePrefix } from "@app/lib/routing"
import { formatCurrency } from "@app/lib/format"
import { FilterBar } from "@app/components/FilterBar"
import { AdminEventLogTable, type AdminEventLogTableColumn } from "@app/components/AdminEventLogPanel"
import { Notice, Page, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
import { useQuery } from "@tanstack/react-query"
import { Link, useLocation } from "react-router-dom"
import { fetchSpending, type SpendingBreakdownRow, type SpendingPayload, type SpendingTriggerRow } from "../api/spending"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"

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
      <Page.Root aria-label={t("aria_insights")} gutter="responsive" size="wide">
        <Notice>{t("common:loading")}</Notice>
      </Page.Root>
    )
  }
  if (spending.isError) {
    return (
      <Page.Root aria-label={t("aria_insights")} gutter="responsive" size="wide">
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
    <Page.Root aria-label={t("aria_insights")} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="flex flex-col gap-4 border-b border-border pb-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <Text className="font-medium uppercase" variant="caption" tone="muted">
            {t("eyebrow")}
          </Text>
          <PageHeading>{t("title")}</PageHeading>
          <Page.Description>
            {t("scope_range", {
              scope: payload.scope.admin ? t("scope_all_users") : payload.scope.label,
              start: payload.filters.start_date,
              end: payload.filters.end_date
            })}
          </Page.Description>
        </div>
      </Page.Header>

      <Page.Nav>
        <FilterBar
          filter={payload.filter}
          filterSchema={payload.controls.filter_schema}
          legacyFilterKeys={legacyFilterKeys}
          pathname={pathname}
          search={search}
        />
      </Page.Nav>

      <section aria-label={t("totals_aria")} className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        <Metric title={t("metric_week")} value={formatSpendingCurrency(payload.totals.week_usd)} context={t("context_workflow_runs")} />
        <Metric title={t("metric_month")} value={formatSpendingCurrency(payload.totals.month_usd)} context={t("context_workflow_runs")} />
        <Metric
          title={t("metric_lifetime")}
          value={formatSpendingCurrency(payload.totals.lifetime_usd)}
          context={t("context_runs_chats", {
            runs: formatSpendingCurrency(payload.totals.workflow_lifetime_usd),
            chats: formatSpendingCurrency(payload.totals.chat_lifetime_usd)
          })}
        />
        <Metric title={t("metric_avg_job")} value={formatSpendingCurrency(payload.totals.average_job_30d_usd)} context={t("context_last_30_days")} />
        <Metric
          title={t("metric_avg_merged_pr")}
          value={formatSpendingCurrency(payload.totals.average_merged_pr_30d_usd)}
          context={t("context_last_30_days")}
        />
      </section>

      <Section.Root aria-label={t("trend_aria")}>
        <div className="mb-3 flex items-center justify-between gap-3">
          <SectionHeading>{t("trend")}</SectionHeading>
          <Text as="span" variant="caption" tone="muted">
            {t("trend_days", { count: payload.trend.length })}
          </Text>
        </div>
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
          storageKey="syrus.spending.epics.columns"
        />
        <BreakdownTable
          title={t("by_user")}
          entityLabel={t("entity_user")}
          rows={payload.breakdowns.users}
          prefix={prefix}
          columns="users"
          emptyLabel={t("empty_user")}
          storageKey="syrus.spending.users.columns"
        />
        <BreakdownTable
          title={t("by_repository")}
          entityLabel={t("entity_repository")}
          rows={payload.breakdowns.repositories}
          prefix={prefix}
          columns="standard"
          emptyLabel={t("empty_repository")}
          storageKey="syrus.spending.repositories.columns"
        />
        <TriggerTable rows={payload.breakdowns.trigger_kinds} />
      </div>

      <TopRunsTable payload={payload} prefix={prefix} />
    </Page.Root>
  )
}

const legacyFilterKeys = ["start_date", "end_date", "repository_id", "epic_id", "user_id", "agent_provider", "trigger_kind"]

function Metric({ title, value, context }: { title: string; value: string; context: string }) {
  return (
    <Section.Root>
      <Text className="font-medium" tone="muted">
        {title}
      </Text>
      <Text className="mt-2 text-3xl font-semibold" tone="default">
        {value}
      </Text>
      <Text className="mt-1 truncate" variant="caption" tone="muted">
        {context}
      </Text>
    </Section.Root>
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
  emptyLabel,
  storageKey
}: {
  title: string
  entityLabel: string
  rows: SpendingBreakdownRow[]
  prefix: string
  columns: "standard" | "users"
  emptyLabel: string
  storageKey: string
}) {
  const { t } = useT("spending")

  if (rows.length === 0) {
    return (
      <Section.Root aria-label={title} className="overflow-hidden p-0">
        <TableHeader title={title} />
        <EmptyTable label={emptyLabel} />
      </Section.Root>
    )
  }

  return (
    <AdminEventLogTable
      columns={breakdownColumns({ columns, entityLabel, prefix, t })}
      defaultSort={{ column: "total_usd", direction: "desc" }}
      getRowKey={(row) => row.id}
      localSort
      panel={{ summary: title }}
      rows={rows}
      storageKey={storageKey}
      tableClassName="table-fixed"
    />
  )
}

function TriggerTable({ rows }: { rows: SpendingTriggerRow[] }) {
  const { t } = useT("spending")

  if (rows.length === 0) {
    return (
      <Section.Root aria-label={t("trigger_aria")} className="overflow-hidden p-0">
        <TableHeader title={t("by_trigger_kind")} />
        <EmptyTable label={t("empty_trigger")} />
      </Section.Root>
    )
  }

  return (
    <AdminEventLogTable
      columns={triggerColumns(t)}
      defaultSort={{ column: "total_usd", direction: "desc" }}
      getRowKey={(row) => row.trigger_kind}
      localSort
      panel={{ summary: t("by_trigger_kind") }}
      rows={rows}
      storageKey="syrus.spending.trigger_kinds.columns"
      tableClassName="table-fixed"
    />
  )
}

function TopRunsTable({ payload, prefix }: { payload: SpendingPayload; prefix: string }) {
  const { t } = useT("spending")
  if (payload.top_runs.length === 0) {
    return (
      <Section.Root aria-label={t("top_runs_aria")} className="overflow-hidden p-0">
        <TableHeader title={t("top_runs")} />
        <EmptyTable label={t("empty_top_runs")} />
      </Section.Root>
    )
  }

  return (
    <AdminEventLogTable
      columns={topRunColumns({ prefix, t })}
      defaultSort={{ column: "cost_usd", direction: "desc" }}
      getRowKey={(run) => run.id}
      localSort
      panel={{ summary: t("top_runs") }}
      rows={payload.top_runs}
      storageKey="syrus.spending.top_runs.columns"
      tableClassName="table-fixed"
    />
  )
}

function TableHeader({ title }: { title: string }) {
  return <SectionHeading className="border-b border-border px-4 py-3">{title}</SectionHeading>
}

function EmptyTable({ label }: { label: string }) {
  return <div className="px-4 py-8 text-sm text-gray-500 dark:text-gray-400">{label}</div>
}

function breakdownColumns({
  columns,
  entityLabel,
  prefix,
  t
}: {
  columns: "standard" | "users"
  entityLabel: string
  prefix: string
  t: ReturnType<typeof useT>["t"]
}): Array<AdminEventLogTableColumn<SpendingBreakdownRow>> {
  return [
    {
      key: "label",
      header: entityLabel,
      className: "max-w-0",
      render: (row) => (
        <Link className="block truncate font-medium text-brand underline hover:no-underline dark:text-brand-emphasis" title={breakdownLabel(row)} to={withRoutePrefix(row.path, prefix)}>
          {breakdownLabel(row)}
        </Link>
      ),
      sort: "label",
      sortValue: (row) => breakdownLabel(row)
    },
    { key: "jobs", header: t("col_jobs"), align: "right", className: "tabular-nums text-gray-700 dark:text-gray-300", render: (row) => row.jobs_count, sort: "jobs_count", sortValue: (row) => row.jobs_count },
    { key: "total", header: t("col_total"), align: "right", className: "tabular-nums font-medium text-gray-900 dark:text-gray-100", render: (row) => formatSpendingCurrency(row.total_usd), sort: "total_usd", sortValue: (row) => row.total_usd },
    {
      key: columns === "users" ? "last_30_days" : "average_job",
      header: columns === "users" ? t("col_last_30") : t("col_avg_job"),
      align: "right",
      className: "tabular-nums text-gray-700 dark:text-gray-300",
      render: (row) => formatSpendingCurrency(columns === "users" ? row.last_30_days_usd || 0 : row.average_job_usd),
      sort: columns === "users" ? "last_30_days_usd" : "average_job_usd",
      sortValue: (row) => columns === "users" ? row.last_30_days_usd || 0 : row.average_job_usd
    }
  ]
}

function triggerColumns(t: ReturnType<typeof useT>["t"]): Array<AdminEventLogTableColumn<SpendingTriggerRow>> {
  return [
    { key: "trigger", header: t("col_trigger"), className: "font-medium text-gray-900 dark:text-gray-100", render: (row) => humanize(row.trigger_kind), sort: "label", sortValue: (row) => humanize(row.trigger_kind) },
    { key: "runs", header: t("col_runs"), align: "right", className: "tabular-nums text-gray-700 dark:text-gray-300", render: (row) => row.runs_count, sort: "runs_count", sortValue: (row) => row.runs_count },
    { key: "total", header: t("col_total"), align: "right", className: "tabular-nums font-medium text-gray-900 dark:text-gray-100", render: (row) => formatSpendingCurrency(row.total_usd), sort: "total_usd", sortValue: (row) => row.total_usd },
    { key: "average", header: t("col_avg_run"), align: "right", className: "tabular-nums text-gray-700 dark:text-gray-300", render: (row) => formatSpendingCurrency(row.average_usd), sort: "average_usd", sortValue: (row) => row.average_usd }
  ]
}

function topRunColumns({ prefix, t }: { prefix: string; t: ReturnType<typeof useT>["t"] }): Array<AdminEventLogTableColumn<SpendingPayload["top_runs"][number]>> {
  return [
    {
      key: "run",
      header: t("col_run"),
      render: (run) => (
        <>
          <div className="font-medium text-gray-900 dark:text-gray-100">{t("run_number", { id: run.id })}</div>
          <div className="text-xs text-gray-500 dark:text-gray-400">
            {humanize(run.trigger_kind)} / {run.agent_provider}
          </div>
        </>
      ),
      sort: "run_id",
      sortValue: (run) => run.id
    },
    {
      key: "job",
      header: t("col_job"),
      className: "max-w-0",
      render: (run) => (
        <>
          <Link className="block truncate text-brand underline hover:no-underline dark:text-brand-emphasis" title={run.job.title || `JOB-${run.job.id}`} to={withRoutePrefix(run.job.path, prefix)}>
            {run.job.title || `JOB-${run.job.id}`}
          </Link>
          {run.epic ? (
            <div className="truncate text-xs text-gray-500 dark:text-gray-400" title={`${run.epic.display_number} / ${run.epic.title}`}>
              {run.epic.display_number} / {run.epic.title}
            </div>
          ) : null}
        </>
      ),
      sort: "job",
      sortValue: (run) => run.job.title || run.job.id
    },
    {
      key: "repository",
      header: t("col_repository"),
      className: "max-w-0",
      render: (run) => (
        <Link className="block truncate font-mono text-xs text-brand underline hover:no-underline dark:text-brand-emphasis" title={run.repository.slug} to={withRoutePrefix(run.repository.path, prefix)}>
          {run.repository.slug}
        </Link>
      ),
      sort: "repository",
      sortValue: (run) => run.repository.slug
    },
    { key: "cost", header: t("col_cost"), align: "right", className: "tabular-nums font-medium text-gray-900 dark:text-gray-100", render: (run) => formatSpendingCurrency(run.cost_usd), sort: "cost_usd", sortValue: (run) => run.cost_usd }
  ]
}

function breakdownLabel(row: SpendingBreakdownRow) {
  return row.display_number ? `${row.display_number} / ${row.label}` : row.label
}

function humanize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}

export default SpendingInsightsRoute
