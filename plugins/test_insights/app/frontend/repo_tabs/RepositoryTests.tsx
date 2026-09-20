import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { Button } from "@app/components/Button"
import { Checkbox } from "@app/components/Checkbox"
import { ColumnsIcon } from "@app/components/ColumnsIcon"
import { FilterBar, filterTreeFromPayload, topFilterChildren } from "@app/components/FilterBar"
import { withRoutePrefix } from "@app/lib/routing"
import { fetchRepositoryTestDetail, fetchRepositoryTests, type RepositoryTestDetailPayload, type RepositoryTestDurationPoint, type RepositoryTestHistoryItem, type RepositoryTestHistoryPagination, type RepositoryTestIdentity, type RepositoryTestsPayload } from "../api/tests"
import { errorMessage } from "@app/lib/errorMessage"
import { useDismissiblePopup } from "@app/lib/useDismissiblePopup"
import { FloatingPortal, flip, offset, shift, useFloating, useMergeRefs } from "@floating-ui/react"
import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom"
import { useEffect, useMemo, useRef, useState, type DragEvent, type ReactNode } from "react"
import { useT } from "@app/hooks/useT"
import type { TFunction } from "i18next"
import {
  DataTable,
  Notice,
  PageHeading,
  Section,
  SectionHeading,
  Text
} from "@app/components/ui"
import { TonePill } from "@app/components/StatusPill"

export function RepositoryTestsRoute({ repositoryId, prefix, selectedTestId }: { repositoryId: string; prefix: string; selectedTestId: string | null }) {
  const { t } = useT("test_insights")
  const location = useLocation()
  const listSearch = useMemo(() => searchWithoutTestId(location.search), [location.search])
  const [historyPage, setHistoryPage] = useState(1)
  const navigate = useNavigate()
  const tests = useQuery({
    queryKey: ["repositories", repositoryId, "tests", listSearch],
    queryFn: () => fetchRepositoryTests(repositoryId, listSearch),
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
      {tests.isError && !tests.data ? <Notice tone="danger">{errorMessage(tests.error, t("repo_error_load_tests"))}</Notice> : null}
      {shell ? (
        <section className="space-y-4">
          {selectedTestId ? (
            <div className="flex flex-wrap items-end gap-3">
              <Button
                onClick={() => navigate(withRoutePrefix(`/repositories/${repositoryId}/plugin/tests`, prefix))}
                variant="secondary"
              >
                {t("repo_back_to_tests")}
              </Button>
            </div>
          ) : (
            <FilterBar
              filter={tests.data?.filter ?? null}
              filterSchema={tests.data?.filter_schema ?? []}
              pathname={location.pathname}
              search={listSearch}
            />
          )}

          {selectedTestId ? (
            <TestDetailPanel detail={testDetail.data} error={testDetail.error} isError={testDetail.isError} isPending={testDetail.isPending} onPageChange={setHistoryPage} prefix={prefix} t={t} />
          ) : (
            <TestList error={tests.error} filterActive={hasActiveFilter(tests.data?.filter)} isError={tests.isError} isFetching={tests.isFetching} payload={tests.data} prefix={prefix} t={t} />
          )}
        </section>
      ) : null}
    </RepositoryPageShell>
  )
}

function searchWithoutTestId(search: string) {
  const params = new URLSearchParams(search)
  params.delete("test_id")
  const query = params.toString()
  return query ? `?${query}` : ""
}

function hasActiveFilter(filter: RepositoryTestsPayload["filter"]) {
  return topFilterChildren(filterTreeFromPayload(filter)).length > 0
}

type ColumnKey = "test" | "suite" | "recent_failures" | "duration" | "last_seen"
type CellContext = { payload: RepositoryTestsPayload; prefix: string; t: TFunction<"test_insights"> }
type ColumnDef = {
  headClassName?: string
  cellClassName?: string
  cellTitle?: (test: RepositoryTestIdentity) => string | undefined
  labelKey: string
  renderCell: (test: RepositoryTestIdentity, ctx: CellContext) => ReactNode
  sortValue: (test: RepositoryTestIdentity) => string | number | null
}

const REQUIRED_COLUMN: ColumnKey = "test"
const CUSTOMIZABLE_COLUMNS: ColumnKey[] = ["suite", "recent_failures", "duration", "last_seen"]
const COLUMNS_STORAGE_KEY = "syrus.test_insights.repository_tests_columns"

const COLUMN_DEFS: Record<ColumnKey, ColumnDef> = {
  test: {
    cellClassName: "max-w-md",
    labelKey: "repo_col_test",
    sortValue: (test) => test.name,
    renderCell: (test, { payload, prefix, t }) => (
      <>
        <Link className="font-medium text-brand-emphasis hover:underline" to={withRoutePrefix(`/repositories/${payload.repository.id}/plugin/tests?test_id=${test.id}`, prefix)}>
          {test.name}
        </Link>
        {test.interesting_reasons.length > 0 ? (
          <div className="mt-2 flex flex-wrap gap-1">
            {test.interesting_reasons.map((reason) => <ReasonBadge key={reason} label={t(`reason_${reason}`, { defaultValue: reason })} reason={reason} />)}
          </div>
        ) : null}
        {test.file_path ? <Text className="mt-1 truncate" variant="caption" tone="muted">{test.file_path}</Text> : null}
      </>
    )
  },
  suite: {
    cellClassName: "hidden max-w-xs truncate text-text-muted md:table-cell",
    cellTitle: (test) => test.suite_name,
    headClassName: "hidden md:table-cell",
    labelKey: "repo_col_suite",
    sortValue: (test) => test.suite_name,
    renderCell: (test) => test.suite_name
  },
  recent_failures: {
    cellClassName: "whitespace-nowrap",
    labelKey: "repo_col_recent_failures",
    sortValue: (test) => test.failed_count,
    renderCell: (test) => <TonePill tone={test.failed_count > 0 ? "red" : "gray"}>{test.failed_count}/{test.total_count}</TonePill>
  },
  duration: {
    cellClassName: "hidden whitespace-nowrap text-text-muted sm:table-cell",
    headClassName: "hidden sm:table-cell",
    labelKey: "repo_col_duration",
    sortValue: (test) => test.avg_duration_ms,
    renderCell: (test) => formatDuration(test.avg_duration_ms)
  },
  last_seen: {
    cellClassName: "hidden whitespace-nowrap text-text-muted sm:table-cell",
    headClassName: "hidden sm:table-cell",
    labelKey: "repo_col_last_seen",
    sortValue: (test) => test.last_seen_at ? new Date(test.last_seen_at).getTime() : null,
    renderCell: (test) => test.last_seen_at ? <RelativeTimestamp value={test.last_seen_at} /> : "—"
  }
}

type ColumnsState = { hidden: ColumnKey[]; order: ColumnKey[] }

function defaultColumnsState(): ColumnsState {
  return { hidden: [], order: [...CUSTOMIZABLE_COLUMNS] }
}

function sanitizeColumnsState(parsed: unknown): ColumnsState {
  if (!parsed || typeof parsed !== "object") return defaultColumnsState()

  const raw = parsed as { hidden?: unknown; order?: unknown }
  const isColumnKey = (key: unknown): key is ColumnKey => CUSTOMIZABLE_COLUMNS.includes(key as ColumnKey)
  const storedOrder = Array.isArray(raw.order) ? raw.order.filter(isColumnKey) : []
  const missing = CUSTOMIZABLE_COLUMNS.filter((key) => !storedOrder.includes(key))
  const hidden = Array.isArray(raw.hidden) ? raw.hidden.filter(isColumnKey) : []

  return { hidden, order: [...storedOrder, ...missing] }
}

function readColumnsState(): ColumnsState {
  try {
    const raw = window.localStorage.getItem(COLUMNS_STORAGE_KEY)
    return raw ? sanitizeColumnsState(JSON.parse(raw)) : defaultColumnsState()
  } catch {
    return defaultColumnsState()
  }
}

function writeColumnsState(state: ColumnsState) {
  try {
    window.localStorage.setItem(COLUMNS_STORAGE_KEY, JSON.stringify(state))
  } catch {
    // localStorage can be unavailable in private or restricted browser contexts.
  }
}

type SortState = { column: ColumnKey; direction: "ascending" | "descending" } | null

function compareSortValues(a: string | number | null, b: string | number | null, direction: 1 | -1) {
  if (a == null && b == null) return 0
  if (a == null) return 1
  if (b == null) return -1
  if (typeof a === "string" && typeof b === "string") return a.localeCompare(b) * direction
  return ((a as number) - (b as number)) * direction
}

function TestList({ error, filterActive, isError, isFetching, payload, prefix, t }: { error: unknown; filterActive: boolean; isError: boolean; isFetching: boolean; payload?: RepositoryTestsPayload; prefix: string; t: TFunction<"test_insights"> }) {
  const [columns, setColumns] = useState<ColumnsState>(() => readColumnsState())
  const [sort, setSort] = useState<SortState>(null)

  useEffect(() => {
    writeColumnsState(columns)
  }, [columns])

  const tests = payload?.tests ?? []
  const visibleTests = useMemo(() => {
    if (!sort) return tests

    const direction = sort.direction === "ascending" ? 1 : -1
    const sortValue = COLUMN_DEFS[sort.column].sortValue
    return [...tests].sort((a, b) => compareSortValues(sortValue(a), sortValue(b), direction))
  }, [sort, tests])

  if (!payload) return null

  function toggleSort(column: ColumnKey) {
    setSort((current) => {
      if (!current || current.column !== column) return { column, direction: "ascending" }
      if (current.direction === "ascending") return { column, direction: "descending" }
      return null
    })
  }

  if (payload.tests.length === 0) {
    return <Notice>{filterActive ? t("repo_no_search_results") : t("repo_no_history")}</Notice>
  }

  const visibleColumns: ColumnKey[] = [REQUIRED_COLUMN, ...columns.order.filter((key) => !columns.hidden.includes(key))]

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-end gap-3">
        {isFetching ? <span className="text-xs text-text-muted">{t("repo_updating_results")}</span> : null}
        {isError ? <span className="text-xs text-danger">{errorMessage(error, t("repo_error_refresh_results"))}</span> : null}
        <ColumnsMenu columns={columns} onChange={setColumns} t={t} />
      </div>

      <DataTable.Root>
        <DataTable.Header>
          <DataTable.Row>
            {visibleColumns.map((key) => (
              <DataTable.HeadCell
                className={COLUMN_DEFS[key].headClassName}
                key={key}
                onSort={() => toggleSort(key)}
                sortDirection={sort?.column === key ? sort.direction : "none"}
              >
                {t(COLUMN_DEFS[key].labelKey)}
              </DataTable.HeadCell>
            ))}
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {visibleTests.map((test) => (
            <DataTable.Row key={test.id}>
              {visibleColumns.map((key) => (
                <DataTable.Cell className={COLUMN_DEFS[key].cellClassName} key={key} title={COLUMN_DEFS[key].cellTitle?.(test)}>
                  {COLUMN_DEFS[key].renderCell(test, { payload, prefix, t })}
                </DataTable.Cell>
              ))}
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
    </div>
  )
}

function ColumnsMenu({ columns, onChange, t }: { columns: ColumnsState; onChange: (next: ColumnsState) => void; t: TFunction<"test_insights"> }) {
  const [open, setOpen] = useState(false)
  const dragIndexRef = useRef<number | null>(null)
  const [draggingKey, setDraggingKey] = useState<ColumnKey | null>(null)
  // flip/shift keep the menu within the viewport instead of a fixed
  // `absolute right-0`, which renders mostly off-screen when the trigger
  // button sits near the left edge of a narrow viewport (the flex-wrap
  // filter bar can push it there on mobile).
  const { floatingStyles, refs: floatingRefs } = useFloating({
    middleware: [offset(4), flip(), shift({ padding: 8 })],
    placement: "bottom-end"
  })
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false), [floatingRefs.floating])
  const referenceRef = useMergeRefs([menuRef, floatingRefs.setReference])

  function toggleVisible(key: ColumnKey) {
    const hidden = columns.hidden.includes(key) ? columns.hidden.filter((hiddenKey) => hiddenKey !== key) : [...columns.hidden, key]
    onChange({ ...columns, hidden })
  }

  // Reuses the native HTML5 DnD pattern AppChromeV2 uses for sidebar nav
  // reordering rather than adding a drag-and-drop dependency.
  function startDrag(index: number, event: DragEvent<HTMLDivElement>) {
    dragIndexRef.current = index
    setDraggingKey(columns.order[index] ?? null)
    event.dataTransfer.effectAllowed = "move"
  }

  function dragOver(index: number, event: DragEvent<HTMLDivElement>) {
    const sourceIndex = dragIndexRef.current
    if (sourceIndex == null) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    if (sourceIndex === index) return

    const nextOrder = [...columns.order]
    const [moved] = nextOrder.splice(sourceIndex, 1)
    nextOrder.splice(index, 0, moved)
    dragIndexRef.current = index
    onChange({ ...columns, order: nextOrder })
  }

  function endDrag() {
    dragIndexRef.current = null
    setDraggingKey(null)
  }

  return (
    <div ref={referenceRef}>
      <Button aria-expanded={open} aria-haspopup="true" aria-label={t("repo_columns_button")} className="h-[var(--control-height-md)] w-[var(--control-height-md)]" onClick={() => setOpen((value) => !value)} size="icon" variant="secondary">
        <ColumnsIcon />
      </Button>
      {open ? (
        <FloatingPortal>
          <div className="z-50 w-64 rounded border border-border bg-surface p-2 shadow-lg" ref={floatingRefs.setFloating} role="menu" style={floatingStyles}>
            <div className="flex items-center justify-between px-1.5 pb-1.5">
              <span className="text-xs font-semibold uppercase text-text-muted">{t("repo_columns_heading")}</span>
              <button className="text-xs font-medium text-brand-emphasis hover:underline" onClick={() => onChange(defaultColumnsState())} type="button">
                {t("repo_columns_reset")}
              </button>
            </div>
            <div className="flex items-center gap-2 px-1.5 py-1 text-sm text-text-muted">
              <Checkbox checked disabled label={t(COLUMN_DEFS[REQUIRED_COLUMN].labelKey)} />
            </div>
            {columns.order.map((key, index) => (
              <div
                className={`cursor-grab rounded px-1.5 py-1 text-sm text-text-primary active:cursor-grabbing ${draggingKey === key ? "opacity-50" : ""}`}
                draggable
                key={key}
                onDragEnd={endDrag}
                onDragOver={(event) => dragOver(index, event)}
                onDragStart={(event) => startDrag(index, event)}
                onDrop={(event) => event.preventDefault()}
              >
                <Checkbox checked={!columns.hidden.includes(key)} label={t(COLUMN_DEFS[key].labelKey)} onChange={() => toggleVisible(key)} />
              </div>
            ))}
          </div>
        </FloatingPortal>
      ) : null}
    </div>
  )
}

function ReasonBadge({ label, reason }: { label?: string; reason: string }) {
  const classes = reason === "failing"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
    : reason === "flaky"
      ? "border-yellow-200 bg-yellow-50 text-yellow-800 dark:border-yellow-900 dark:bg-yellow-950 dark:text-yellow-300"
      : "border-info/30 bg-info/10 text-info"

  return <span className={`inline-flex rounded border px-1.5 py-0.5 text-2xs font-medium ${classes}`}>{label ?? reason}</span>
}

function TestDetailPanel({ detail, error, isError, isPending, onPageChange, prefix, t }: { detail?: RepositoryTestDetailPayload; error: unknown; isError: boolean; isPending: boolean; onPageChange: (page: number) => void; prefix: string; t: TFunction<"test_insights"> }) {
  if (isPending) return <Notice>{t("repo_loading_history")}</Notice>
  if (isError) return <Notice tone="danger">{errorMessage(error, t("repo_error_load_history"))}</Notice>
  if (!detail) return null

  return (
    <div className="space-y-4">
      <Section.Root>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <SectionHeading>{detail.test.name}</SectionHeading>
            <Text className="mt-1" tone="muted">{detail.test.suite_name}</Text>
            {detail.test.file_path ? <Text className="mt-1 font-mono" variant="caption" tone="muted">{detail.test.file_path}</Text> : null}
          </div>
          <TonePill tone="gray">{detail.test.fingerprint.slice(0, 12)}</TonePill>
        </div>
        <DurationChart history={detail.history} points={detail.duration_points} prefix={prefix} t={t} />
      </Section.Root>

      <div className="space-y-2">
        <DataTable.Root>
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("repo_col_time")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("repo_col_status")}</DataTable.HeadCell>
              <DataTable.HeadCell className="hidden sm:table-cell">{t("repo_col_duration")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("repo_col_run")}</DataTable.HeadCell>
              <DataTable.HeadCell className="hidden lg:table-cell">{t("repo_col_failure")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {detail.history.map((item) => <HistoryRow item={item} key={item.id} prefix={prefix} />)}
          </DataTable.Body>
        </DataTable.Root>
        <HistoryPagination onPageChange={onPageChange} pagination={detail.pagination} t={t} />
      </div>
    </div>
  )
}

function HistoryPagination({ onPageChange, pagination, t }: { onPageChange: (page: number) => void; pagination: RepositoryTestHistoryPagination; t: TFunction<"test_insights"> }) {
  if (pagination.total_pages <= 1) return null

  const firstItem = pagination.total === 0 ? 0 : (pagination.page - 1) * pagination.per_page + 1
  const lastItem = Math.min(pagination.page * pagination.per_page, pagination.total)

  return (
    <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
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
    <DataTable.Row>
      <DataTable.Cell className="whitespace-nowrap">{item.created_at ? <RelativeTimestamp value={item.created_at} /> : "—"}</DataTable.Cell>
      <DataTable.Cell><StatusBadge status={item.status} /></DataTable.Cell>
      <DataTable.Cell className="hidden whitespace-nowrap text-text-muted sm:table-cell">{formatDuration(item.duration_ms)}</DataTable.Cell>
      <DataTable.Cell>
        <Link className="font-medium text-brand-emphasis hover:underline" to={withRoutePrefix(item.run.path, prefix)}>{item.run.slug}</Link>
        <Text className="mt-1" variant="caption" tone="muted">{item.job.slug} · {item.grader_name}</Text>
      </DataTable.Cell>
      <DataTable.Cell className="hidden max-w-md truncate text-text-muted lg:table-cell" title={item.failure_message || ""}>{item.failure_message || "—"}</DataTable.Cell>
    </DataTable.Row>
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
