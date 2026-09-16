import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { Button } from "@app/components/Button"
import { Input } from "@app/components/Input"
import { withRoutePrefix } from "@app/lib/routing"
import { fetchRepositoryTestDetail, fetchRepositoryTests, type RepositoryTestDetailPayload, type RepositoryTestDurationPoint, type RepositoryTestHistoryItem, type RepositoryTestHistoryPagination, type RepositoryTestIdentity, type RepositoryTestsPayload } from "../api/tests"
import { errorMessage } from "@app/lib/errorMessage"
import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom"
import { useEffect, useMemo, useState } from "react"
import { useT } from "@app/hooks/useT"
import type { TFunction } from "i18next"
import {
  DataTable,
  DataTableBody,
  DataTableCell,
  DataTableHead,
  DataTableHeader,
  FormField,
  FormLabel,
  Notice,
  PageHeading,
  Section,
  SectionHeading,
  TableSurface,
  Text
} from "@app/components/ui"
import { TonePill } from "@app/components/StatusPill"

export function RepositoryTestsRoute({ repositoryId, prefix, selectedTestId }: { repositoryId: string; prefix: string; selectedTestId: string | null }) {
  const { t } = useT("test_insights")
  const [query, setQuery] = useState("")
  const debouncedQuery = useDebouncedValue(query, 250)
  const [historyPage, setHistoryPage] = useState(1)
  const navigate = useNavigate()
  const tests = useQuery({
    queryKey: ["repositories", repositoryId, "tests", debouncedQuery],
    queryFn: () => fetchRepositoryTests(repositoryId, debouncedQuery),
    placeholderData: keepPreviousData
  })

  useEffect(() => {
    setHistoryPage(1)
  }, [selectedTestId])

  const testDetail = useQuery({
    queryKey: ["repositories", repositoryId, "tests", selectedTestId, historyPage],
    queryFn: () => fetchRepositoryTestDetail(repositoryId, selectedTestId!, historyPage),
    enabled: !!selectedTestId,
    placeholderData: keepPreviousData
  })

  const shell = testDetail.data || tests.data

  return (
    <RepositoryPageShell
      activeTab="test_insights.tests"
      heading={shell ? (
        <PageHeading mono>
          <a className="hover:underline" href={shell.repository.github_url} rel="noopener" target="_blank">{shell.repository.slug}</a>
        </PageHeading>
      ) : null}
      prefix={prefix}
      tabs={shell?.tabs ?? []}
    >
      {tests.isPending && !shell ? <Notice>{t("repo_loading_tests")}</Notice> : null}
      {tests.isError && !tests.data ? <Notice tone="error">{errorMessage(tests.error, t("repo_error_load_tests"))}</Notice> : null}
      {shell ? (
        <section className="space-y-4">
          <div className="flex flex-wrap items-end gap-3">
            <FormField className="min-w-[18rem] flex-1">
              <FormLabel htmlFor="test-search">{t("repo_search_tests")}</FormLabel>
              <Input
                id="test-search"
                className="mt-1"
                onChange={(event) => setQuery(event.target.value)}
                placeholder={t("repo_search_placeholder")}
                value={query}
              />
            </FormField>
            {selectedTestId ? (
              <Button
                onClick={() => navigate(withRoutePrefix(`/repositories/${repositoryId}/plugin/tests`, prefix))}
                variant="secondary"
              >
                {t("repo_back_to_tests")}
              </Button>
            ) : null}
          </div>

          {selectedTestId ? (
            <TestDetailPanel detail={testDetail.data} error={testDetail.error} isError={testDetail.isError} isPending={testDetail.isPending} onPageChange={setHistoryPage} prefix={prefix} t={t} />
          ) : (
            <TestList error={tests.error} isError={tests.isError} isFetching={tests.isFetching} payload={tests.data} prefix={prefix} query={debouncedQuery} t={t} />
          )}
        </section>
      ) : null}
    </RepositoryPageShell>
  )
}

function TestList({ error, isError, isFetching, payload, prefix, query, t }: { error: unknown; isError: boolean; isFetching: boolean; payload?: RepositoryTestsPayload; prefix: string; query: string; t: TFunction<"test_insights"> }) {
  if (!payload) return null
  if (payload.tests.length === 0) {
    return <Notice>{query ? t("repo_no_search_results") : t("repo_no_history")}</Notice>
  }

  return (
    <TableSurface className="overflow-hidden">
      <div className="flex items-center justify-between border-b border-border px-4 py-2 text-xs text-text-muted">
        <span>{query ? t("repo_search_results") : t("repo_interesting_tests")}</span>
        {isFetching ? <span>{t("repo_updating_results")}</span> : null}
        {isError ? <span className="text-danger">{errorMessage(error, t("repo_error_refresh_results"))}</span> : null}
      </div>
      <DataTable>
        <DataTableHead>
          <tr>
            <DataTableHeader>{t("repo_col_test")}</DataTableHeader>
            <DataTableHeader className="hidden md:table-cell">{t("repo_col_suite")}</DataTableHeader>
            <DataTableHeader>{t("repo_col_recent_failures")}</DataTableHeader>
            <DataTableHeader className="hidden sm:table-cell">{t("repo_col_duration")}</DataTableHeader>
            <DataTableHeader className="hidden sm:table-cell">{t("repo_col_last_seen")}</DataTableHeader>
          </tr>
        </DataTableHead>
        <DataTableBody>
          {payload.tests.map((test) => (
            <tr className="text-text-secondary" key={test.id}>
              <DataTableCell className="max-w-md">
                <Link className="font-medium text-brand-emphasis hover:underline" to={withRoutePrefix(`/repositories/${payload.repository.id}/plugin/tests?test_id=${test.id}`, prefix)}>
                  {test.name}
                </Link>
                {test.interesting_reasons.length > 0 ? (
                  <div className="mt-2 flex flex-wrap gap-1">
                    {test.interesting_reasons.map((reason) => <ReasonBadge key={reason} reason={reason} />)}
                  </div>
                ) : null}
                {test.file_path ? <Text className="mt-1 truncate" size="xs" tone="muted">{test.file_path}</Text> : null}
              </DataTableCell>
              <DataTableCell className="hidden max-w-xs truncate text-text-muted md:table-cell" title={test.suite_name}>{test.suite_name}</DataTableCell>
              <DataTableCell className="whitespace-nowrap">
                <TonePill tone={test.failed_count > 0 ? "red" : "gray"}>{test.failed_count}/{test.total_count}</TonePill>
              </DataTableCell>
              <DataTableCell className="hidden whitespace-nowrap text-text-muted sm:table-cell">{formatDuration(test.avg_duration_ms)}</DataTableCell>
              <DataTableCell className="hidden whitespace-nowrap text-text-muted sm:table-cell">{test.last_seen_at ? <RelativeTimestamp value={test.last_seen_at} /> : "—"}</DataTableCell>
            </tr>
          ))}
        </DataTableBody>
      </DataTable>
    </TableSurface>
  )
}

function ReasonBadge({ reason }: { reason: string }) {
  const classes = reason === "failing"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
    : reason === "flaky"
      ? "border-yellow-200 bg-yellow-50 text-yellow-800 dark:border-yellow-900 dark:bg-yellow-950 dark:text-yellow-300"
      : "border-info/30 bg-info/10 text-info"

  return <span className={`inline-flex rounded border px-1.5 py-0.5 text-2xs font-medium ${classes}`}>{reason}</span>
}

function TestDetailPanel({ detail, error, isError, isPending, onPageChange, prefix, t }: { detail?: RepositoryTestDetailPayload; error: unknown; isError: boolean; isPending: boolean; onPageChange: (page: number) => void; prefix: string; t: TFunction<"test_insights"> }) {
  if (isPending) return <Notice>{t("repo_loading_history")}</Notice>
  if (isError) return <Notice tone="error">{errorMessage(error, t("repo_error_load_history"))}</Notice>
  if (!detail) return null

  return (
    <div className="space-y-4">
      <Section>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <SectionHeading>{detail.test.name}</SectionHeading>
            <Text className="mt-1" tone="muted">{detail.test.suite_name}</Text>
            {detail.test.file_path ? <Text className="mt-1 font-mono" size="xs" tone="muted">{detail.test.file_path}</Text> : null}
          </div>
          <TonePill tone="gray">{detail.test.fingerprint.slice(0, 12)}</TonePill>
        </div>
        <DurationChart history={detail.history} points={detail.duration_points} prefix={prefix} t={t} />
      </Section>

      <TableSurface className="overflow-hidden">
        <DataTable>
          <DataTableHead>
            <tr>
              <DataTableHeader>{t("repo_col_time")}</DataTableHeader>
              <DataTableHeader>{t("repo_col_status")}</DataTableHeader>
              <DataTableHeader className="hidden sm:table-cell">{t("repo_col_duration")}</DataTableHeader>
              <DataTableHeader>{t("repo_col_run")}</DataTableHeader>
              <DataTableHeader className="hidden lg:table-cell">{t("repo_col_failure")}</DataTableHeader>
            </tr>
          </DataTableHead>
          <DataTableBody>
            {detail.history.map((item) => <HistoryRow item={item} key={item.id} prefix={prefix} />)}
          </DataTableBody>
        </DataTable>
        <HistoryPagination onPageChange={onPageChange} pagination={detail.pagination} t={t} />
      </TableSurface>
    </div>
  )
}

function HistoryPagination({ onPageChange, pagination, t }: { onPageChange: (page: number) => void; pagination: RepositoryTestHistoryPagination; t: TFunction<"test_insights"> }) {
  if (pagination.total_pages <= 1) return null

  const firstItem = pagination.total === 0 ? 0 : (pagination.page - 1) * pagination.per_page + 1
  const lastItem = Math.min(pagination.page * pagination.per_page, pagination.total)

  return (
    <div className="flex items-center justify-between border-t border-gray-200 px-4 py-2 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-400">
      <span>{t("repo_showing", { first: firstItem, last: lastItem, total: pagination.total })}</span>
      <div className="flex gap-2">
        {pagination.page > 1 ? (
          <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800" onClick={() => onPageChange(pagination.page - 1)} type="button">{t("repo_previous")}</button>
        ) : <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600">{t("repo_previous")}</span>}
        {pagination.page < pagination.total_pages ? (
          <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800" onClick={() => onPageChange(pagination.page + 1)} type="button">{t("repo_next")}</button>
        ) : <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600">{t("repo_next")}</span>}
      </div>
    </div>
  )
}

function HistoryRow({ item, prefix }: { item: RepositoryTestHistoryItem; prefix: string }) {
  return (
    <tr className="text-text-secondary">
      <DataTableCell className="whitespace-nowrap">{item.created_at ? <RelativeTimestamp value={item.created_at} /> : "—"}</DataTableCell>
      <DataTableCell><StatusBadge status={item.status} /></DataTableCell>
      <DataTableCell className="hidden whitespace-nowrap text-text-muted sm:table-cell">{formatDuration(item.duration_ms)}</DataTableCell>
      <DataTableCell>
        <Link className="font-medium text-brand-emphasis hover:underline" to={withRoutePrefix(item.run.path, prefix)}>{item.run.slug}</Link>
        <Text className="mt-1" size="xs" tone="muted">{item.job.slug} · {item.grader_name}</Text>
      </DataTableCell>
      <DataTableCell className="hidden max-w-md truncate text-text-muted lg:table-cell" title={item.failure_message || ""}>{item.failure_message || "—"}</DataTableCell>
    </tr>
  )
}

const CHART_WIDTH = 640
const CHART_HEIGHT = 170
const CHART_LEFT = 46
const CHART_RIGHT = 8
const CHART_TOP = 10
const CHART_BOTTOM = 10

const STATUS_STYLE: Record<string, { dot: string; text: string; label: string; emphasize: boolean }> = {
  passed: { dot: "fill-green-500 dark:fill-green-400", text: "text-green-700 dark:text-green-300", label: "Passed", emphasize: false },
  skipped: { dot: "fill-yellow-500 dark:fill-yellow-400", text: "text-yellow-700 dark:text-yellow-300", label: "Inconclusive", emphasize: false },
  failed: { dot: "fill-red-500 dark:fill-red-400", text: "text-red-700 dark:text-red-300", label: "Failed", emphasize: true },
  error: { dot: "fill-red-500 dark:fill-red-400", text: "text-red-700 dark:text-red-300", label: "Error", emphasize: true }
}

type ChartDot = { key: number; x: number; y: number; status: RepositoryTestDurationPoint["status"]; source: RepositoryTestDurationPoint }
type ActiveDot = { point: RepositoryTestDurationPoint; x: number; y: number }

function DurationChart({ history, points, prefix, t }: { history: RepositoryTestHistoryItem[]; points: RepositoryTestDurationPoint[]; prefix: string; t: TFunction<"test_insights"> }) {
  const navigate = useNavigate()
  const historyById = useMemo(() => new Map(history.map((item) => [item.id, item])), [history])
  const chart = useMemo(() => buildChart(points), [points])
  const [active, setActive] = useState<ActiveDot | null>(null)

  if (!chart) {
    return <div className="mt-4 rounded border border-gray-200 p-4 text-sm text-gray-500 dark:border-gray-700 dark:text-gray-400">{t("repo_no_duration_samples")}</div>
  }

  const latest = points.at(-1)

  function goToRun(historyItem: RepositoryTestHistoryItem | undefined) {
    if (historyItem) navigate(withRoutePrefix(historyItem.run.path, prefix))
  }

  return (
    <div className="mt-4">
      <div className="mb-2 flex items-center justify-between text-xs text-gray-500 dark:text-gray-400">
        <span>{t("repo_duration_over_time")}</span>
        {latest ? <span className="font-medium text-gray-700 dark:text-gray-300">{t("repo_latest_duration", { duration: formatDuration(latest.duration_ms) })}</span> : null}
      </div>
      <div className="relative">
        <svg className="h-44 w-full overflow-visible" onMouseLeave={() => setActive(null)} role="img" viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}>
          {chart.ticks.map((tick) => (
            <g key={tick.value}>
              <line className="stroke-gray-200 dark:stroke-gray-700" strokeWidth="1" x1={CHART_LEFT} x2={CHART_WIDTH - CHART_RIGHT} y1={tick.y} y2={tick.y} />
              <text className="fill-gray-400 text-2xs dark:fill-gray-500" textAnchor="end" x={CHART_LEFT - 6} y={tick.y + 3}>
                {formatDuration(tick.value)}
              </text>
            </g>
          ))}
          <polyline className="fill-none stroke-gray-300 dark:stroke-gray-600" points={chart.linePoints} strokeWidth="1.5" />
          {chart.dots.map((dot) => {
            const style = STATUS_STYLE[dot.status] ?? STATUS_STYLE.skipped
            const historyItem = historyById.get(dot.key)
            return (
              <g key={dot.key}>
                <circle
                  aria-label={t(`repo_status_${dot.status}`, { defaultValue: style.label }) + `, ${formatDuration(dot.source.duration_ms)}`}
                  className="cursor-pointer fill-transparent"
                  cx={dot.x}
                  cy={dot.y}
                  r={12}
                  role="button"
                  tabIndex={0}
                  onBlur={() => setActive(null)}
                  onClick={() => goToRun(historyItem)}
                  onFocus={() => setActive({ point: dot.source, x: dot.x, y: dot.y })}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault()
                      goToRun(historyItem)
                    }
                  }}
                  onMouseEnter={() => setActive({ point: dot.source, x: dot.x, y: dot.y })}
                />
                <circle className={`pointer-events-none stroke-white dark:stroke-gray-900 ${style.dot}`} cx={dot.x} cy={dot.y} r={style.emphasize ? 4.5 : 3} strokeWidth="1" />
              </g>
            )
          })}
        </svg>

        {active ? <DurationTooltip historyItem={historyById.get(active.point.test_case_id)} point={active.point} t={t} x={active.x} y={active.y} /> : null}
      </div>

      <div className="mt-2 flex flex-wrap gap-3 text-xs text-gray-500 dark:text-gray-400">
        <LegendKey className="fill-green-500 dark:fill-green-400" label={t("repo_status_passed")} />
        <LegendKey className="fill-yellow-500 dark:fill-yellow-400" label={t("repo_status_skipped")} />
        <LegendKey className="fill-red-500 dark:fill-red-400" label={t("repo_status_failed")} />
      </div>
    </div>
  )
}

function LegendKey({ className, label }: { className: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <svg className="h-2.5 w-2.5" viewBox="0 0 10 10">
        <circle className={className} cx="5" cy="5" r="4" />
      </svg>
      {label}
    </span>
  )
}

function DurationTooltip({ historyItem, point, t, x, y }: { historyItem?: RepositoryTestHistoryItem; point: RepositoryTestDurationPoint; t: TFunction<"test_insights">; x: number; y: number }) {
  const style = STATUS_STYLE[point.status] ?? STATUS_STYLE.skipped

  return (
    <div
      className="pointer-events-none absolute z-10 w-60 -translate-x-1/2 -translate-y-full rounded border border-gray-200 bg-white px-3 py-2 text-xs shadow-lg dark:border-gray-700 dark:bg-gray-900"
      data-testid="duration-tooltip"
      style={{ left: `${(x / CHART_WIDTH) * 100}%`, marginTop: -10, top: `${(y / CHART_HEIGHT) * 100}%` }}
    >
      <div className="flex items-center justify-between gap-2">
        <span className={`font-medium ${style.text}`}>{t(`repo_status_${point.status}`, { defaultValue: style.label })}</span>
        <span className="font-mono text-gray-700 dark:text-gray-300">{formatExactDuration(point.duration_ms)}</span>
      </div>
      <div className="mt-1 text-gray-500 dark:text-gray-400">{point.created_at ? new Date(point.created_at).toLocaleString() : t("repo_unknown_time")}</div>
      {historyItem ? (
        <div className="mt-1.5 border-t border-gray-100 pt-1.5 dark:border-gray-800">
          <div className="text-gray-500 dark:text-gray-400">{historyItem.job.slug} · {historyItem.grader_name}</div>
          {historyItem.failure_message ? (
            <div className="mt-1 truncate text-red-600 dark:text-red-300" title={historyItem.failure_message}>{historyItem.failure_message}</div>
          ) : null}
          <div className="mt-1 font-medium text-brand-emphasis">{t("repo_click_to_open", { slug: historyItem.run.slug })}</div>
        </div>
      ) : null}
    </div>
  )
}

function buildChart(points: RepositoryTestDurationPoint[]) {
  const usable = points.filter((point) => point.duration_ms != null)
  if (usable.length === 0) return null

  const durations = usable.map((point) => point.duration_ms)
  const { max, min, ticks: tickValues } = niceTicks(Math.min(...durations), Math.max(...durations), 4)
  const domain = max - min || 1
  const plotWidth = CHART_WIDTH - CHART_LEFT - CHART_RIGHT
  const plotHeight = CHART_HEIGHT - CHART_TOP - CHART_BOTTOM
  const xStep = usable.length > 1 ? plotWidth / (usable.length - 1) : 0

  function toY(value: number) {
    return CHART_TOP + (1 - (value - min) / domain) * plotHeight
  }

  const dots: ChartDot[] = usable.map((point, index) => ({
    key: point.test_case_id,
    x: usable.length > 1 ? CHART_LEFT + index * xStep : CHART_LEFT + plotWidth / 2,
    y: toY(point.duration_ms),
    status: point.status,
    source: point
  }))

  return {
    dots,
    linePoints: dots.map((dot) => `${dot.x},${dot.y}`).join(" "),
    ticks: tickValues.map((value) => ({ value, y: toY(value) }))
  }
}

function niceTicks(minValue: number, maxValue: number, count: number) {
  let min = minValue
  let max = maxValue
  if (min === max) {
    min = min === 0 ? 0 : min * 0.9
    max = max === 0 ? 1 : max * 1.1
  }
  const range = max - min
  const rawStep = range / (count - 1)
  const magnitude = 10 ** Math.floor(Math.log10(rawStep))
  const residual = rawStep / magnitude
  const niceResidual = residual >= 5 ? 10 : residual >= 2 ? 5 : residual >= 1 ? 2 : 1
  const step = niceResidual * magnitude
  const niceMin = Math.max(0, Math.floor(min / step) * step)
  const niceMax = Math.ceil(max / step) * step

  const ticks: number[] = []
  for (let value = niceMin; value <= niceMax + step / 2; value += step) {
    ticks.push(Math.round(value))
  }

  return { max: niceMax, min: niceMin, ticks }
}

function StatusBadge({ status }: { status: RepositoryTestHistoryItem["status"] }) {
  const classes = status === "passed"
    ? "border-green-200 bg-green-50 text-green-700 dark:border-green-900 dark:bg-green-950 dark:text-green-300"
    : status === "skipped"
      ? "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"
      : "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
  return <span className={`inline-flex rounded border px-2 py-0.5 text-xs font-medium ${classes}`}>{status}</span>
}

function formatDuration(value: number | null | undefined) {
  if (value == null) return "—"
  if (value < 1000) return `${value}ms`
  return `${(value / 1000).toFixed(2)}s`
}

function formatExactDuration(value: number | null | undefined) {
  if (value == null) return "—"
  return `${value.toLocaleString()}ms`
}

function useDebouncedValue<T>(value: T, delayMs: number) {
  const [debouncedValue, setDebouncedValue] = useState(value)

  useEffect(() => {
    const timeout = window.setTimeout(() => setDebouncedValue(value), delayMs)
    return () => window.clearTimeout(timeout)
  }, [delayMs, value])

  return debouncedValue
}

// Rendered by PluginRepoPageTabRoute, which passes no props: the repository
// comes from the URL.
export default function RepositoryTestsTab() {
  const params = useParams()
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""

  return (
    <RepositoryTestsRoute
      repositoryId={params.repositoryId || ""}
      prefix={prefix}
      selectedTestId={searchParams.get("test_id")}
    />
  )
}
