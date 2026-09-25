import { Fragment, type ReactNode, useMemo, useState } from "react"
import { FilterBar, type FilterChip, type FilterSchemaField, type FilterTree } from "./FilterBar"
import { encodeFilterTree, linkFromSearch } from "./filterBar/helpers"
import type { FilterLinkUpdates } from "./filterBar/types"
import { useT } from "../hooks/useT"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  visibleColumns,
  type DataTableColumnDef,
  type DataTableColumnPin
} from "./dataTable"
import { DataTable, Text, type DataTableSortDirection } from "./ui"
import { classes } from "./ui/classes"
import { Page, usePageGutterRestoreClassName } from "./ui/Page"

export function AdminEventPanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "warn" }) {
  const toneClass =
    tone === "error"
      ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300"
      : tone === "warn"
        ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
        : "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  return <div className={`rounded border p-4 text-sm ${toneClass}`}>{children}</div>
}

// Uses the responsive gutter primitive: the header keeps the page's normal
// mobile margin (restored here and, separately, by AdminEventFilterBar
// below), while children -- normally an AdminEventLogTable-backed section --
// run edge to edge.
export function AdminEventPageShell({
  actions,
  ariaLabel,
  children,
  description,
  eyebrow,
  title
}: {
  actions?: ReactNode
  ariaLabel: string
  children: ReactNode
  description?: ReactNode
  eyebrow: string
  title: string
}) {
  return (
    <Page.Root aria-label={ariaLabel} gutter="responsive" size="wide">
      <AdminEventShellHeader actions={actions} eyebrow={eyebrow} title={title} />
      {description ? <AdminEventShellDescription>{description}</AdminEventShellDescription> : null}
      {children}
    </Page.Root>
  )
}

// Split out so usePageGutterRestoreClassName reads the context Page.Root
// provides (a hook call from AdminEventPageShell's own body would run before
// the Provider is mounted). Kept hand-rolled rather than Page.Header so the
// existing border/responsive-alignment layout survives unchanged.
function AdminEventShellHeader({ actions, eyebrow, title }: { actions?: ReactNode; eyebrow: string; title: string }) {
  const restore = usePageGutterRestoreClassName("padding")
  return (
    <header className={classes("flex flex-col gap-4 border-b border-gray-200 pb-4 dark:border-gray-700 lg:flex-row lg:items-end lg:justify-between", restore)}>
      <div>
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{eyebrow}</p>
        <Page.Title className="mt-1">{title}</Page.Title>
      </div>
      {actions}
    </header>
  )
}

function AdminEventShellDescription({ children }: { children: ReactNode }) {
  const restore = usePageGutterRestoreClassName("padding")
  return (
    <Text className={classes("max-w-3xl", restore)} muted>
      {children}
    </Text>
  )
}

export type AdminDataTablePanelPagination = {
  ariaLabel?: string
  label: ReactNode
  nextLabel: string
  onNavigate: (params: URLSearchParams) => void
  pagination: {
    page: number
    has_next_page?: boolean
    has_previous_page?: boolean
    next_page?: number | null
    previous_page?: number | null
    total_pages?: number | null
  }
  previousLabel: string
  search: string
}

export type AdminDataTablePanelConfig = {
  footer?: ReactNode
  meta?: ReactNode
  pagination?: AdminDataTablePanelPagination
  summary?: ReactNode
}

export function AdminDataTablePanel({
  children,
  columnSelector,
  config
}: {
  children: ReactNode
  columnSelector?: ReactNode
  config?: AdminDataTablePanelConfig
}) {
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      {(config?.summary || config?.meta || config?.pagination || columnSelector) ? (
        <AdminDataTablePanelHeader columnSelector={columnSelector} config={config} />
      ) : null}
      {children}
      {config?.footer ? <div className="border-t border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">{config.footer}</div> : null}
      {config?.pagination ? <AdminDataTablePanelFooter pagination={config.pagination} /> : null}
    </section>
  )
}

function AdminDataTablePanelHeader({ columnSelector, config }: { columnSelector?: ReactNode; config?: AdminDataTablePanelConfig }) {
  return (
    <div className="flex flex-col gap-3 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        {config?.summary ? <div>{config.summary}</div> : null}
        {config?.meta ? <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{config.meta}</div> : null}
      </div>
      <div className="flex shrink-0 items-center gap-2 self-end sm:self-auto">
        {config?.pagination ? <AdminDataTablePanelPaginationControls pagination={config.pagination} /> : null}
        {columnSelector}
      </div>
    </div>
  )
}

function AdminDataTablePanelFooter({ pagination }: { pagination: AdminDataTablePanelPagination }) {
  if (!hasMultiplePages(pagination.pagination)) return null

  return (
    <nav aria-label={pagination.ariaLabel} className={adminDataTablePanelFooterClass()}>
      <span>{pagination.label}</span>
      <AdminDataTablePanelPaginationControls pagination={pagination} />
    </nav>
  )
}

function AdminDataTablePanelPaginationControls({ pagination }: { pagination: AdminDataTablePanelPagination }) {
  if (!hasMultiplePages(pagination.pagination)) return null

  function go(page: number | null | undefined) {
    if (!page) return
    const params = new URLSearchParams(pagination.search)
    params.set("page", String(page))
    pagination.onNavigate(params)
  }

  return (
    <div className="flex items-center gap-2">
      <button className={pageButtonClass()} disabled={!pagination.pagination.has_previous_page} onClick={() => go(pagination.pagination.previous_page)} type="button">
        {pagination.previousLabel}
      </button>
      <button className={pageButtonClass()} disabled={!pagination.pagination.has_next_page} onClick={() => go(pagination.pagination.next_page)} type="button">
        {pagination.nextLabel}
      </button>
    </div>
  )
}

function hasMultiplePages(pagination: AdminDataTablePanelPagination["pagination"]) {
  return (pagination.total_pages ?? 0) > 1 || Boolean(pagination.has_next_page || pagination.has_previous_page)
}

function adminDataTablePanelFooterClass() {
  return "flex items-center justify-between border-t border-border px-4 py-3 text-sm text-text-secondary"
}

export type AdminEventLogTableColumn<Row> = {
  align?: DataTableColumnDef<Row>["align"]
  className?: string
  // Required columns are always visible and excluded from the column picker
  // -- reserve this for a column that's the only way to reach something (an
  // expand toggle, the primary identity of the row) so hiding it wouldn't
  // just declutter, it'd make the row unusable.
  defaultVisible?: boolean
  header: ReactNode
  headerClassName?: string
  key: string
  // Used by the column picker menu; falls back to `header` when that's a
  // plain string, so most columns never need to set this explicitly.
  label?: string
  // Required columns are pinned to the declared end of the row instead of
  // taking part in the optional reorder -- defaults to "start" (see
  // DataTableColumnDef). A required column that isn't naturally the first
  // or last one declared MUST set this explicitly, or it silently jumps to
  // the front of the row regardless of where it was defined.
  pin?: DataTableColumnPin
  render: (row: Row, state: { expanded: boolean; toggleExpanded: () => void }) => ReactNode
  required?: boolean
  sort?: string
  sortValue?: (row: Row) => number | string | null | undefined
}

export type AdminEventLogTableDefaultSort = { column: string; direction?: "asc" | "desc" }

// Reads the current `sort`/`direction` query params, defaulting to the
// backend's declared ordering so the first render shows the same active
// indicator as an explicit sort URL.
function parseEventLogSort(search: string | undefined, defaultSort: AdminEventLogTableDefaultSort): { column: string; direction: "asc" | "desc" } {
  const params = new URLSearchParams(search || "")
  return { column: params.get("sort") || defaultSort.column, direction: params.get("direction") === "asc" ? "asc" : defaultSort.direction || "desc" }
}

export function AdminEventLogTable<Row>({
  columns,
  defaultSort = { column: "time", direction: "desc" },
  getRowKey,
  localSort = false,
  onNavigate,
  panel,
  renderExpanded,
  rows,
  search,
  storageKey,
  tableClassName = "table-fixed"
}: {
  columns: Array<AdminEventLogTableColumn<Row>>
  defaultSort?: AdminEventLogTableDefaultSort
  getRowKey: (row: Row) => string | number
  localSort?: boolean
  onNavigate?: (params: URLSearchParams) => void
  panel?: AdminDataTablePanelConfig
  renderExpanded?: (row: Row) => ReactNode
  rows: Row[]
  search?: string
  // Persistence key for this table's column visibility/order -- unique per
  // table/surface (e.g. "syrus.admin.backend_exceptions.visible_columns") so
  // different admin event tables don't clobber each other's preferences.
  storageKey: string
  tableClassName?: string
}) {
  const { t } = useT("admin")
  const [expandedKey, setExpandedKey] = useState<string | number | null>(null)
  const [localSortState, setLocalSortState] = useState<{ column: string; direction: "asc" | "desc" } | null>(null)

  // Maps the caller's simpler column shape onto the shared DataTableColumnDef
  // model: `render` needs per-row expand state, which DataTableColumnDef's
  // `renderCell(row)` doesn't carry, so it's closed over here from this
  // component's own expandedKey state instead.
  const dataTableColumns = useMemo<DataTableColumnDef<Row>[]>(
    () =>
      columns.map((column) => ({
        cellClassName: column.className,
        align: column.align,
        defaultVisible: column.defaultVisible,
        headClassName: column.headerClassName || column.className,
        key: column.key,
        label: column.label ?? (typeof column.header === "string" ? column.header : column.key),
        pin: column.pin,
        renderCell: (row: Row) => {
          const rowKey = getRowKey(row)
          const expanded = expandedKey === rowKey
          const toggleExpanded = () => setExpandedKey((current) => (current === rowKey ? null : rowKey))
          return column.render(row, { expanded, toggleExpanded })
        },
        renderHeader: () => column.header,
        required: column.required,
        sortKey: column.sort
      })),
    [columns, expandedKey, getRowKey]
  )

  const preferences = useLocalStorageColumnPreferences({ columns: dataTableColumns, storageKey })
  const activeSort = localSort && localSortState ? localSortState : parseEventLogSort(search, defaultSort)
  const sortDirection: DataTableSortDirection = activeSort.direction === "asc" ? "ascending" : "descending"
  const colSpan = visibleColumns({ columns: dataTableColumns, order: preferences.order }).length

  function sortTo(sortKey: string) {
    if (localSort) {
      const nextDirection = activeSort.column === sortKey && activeSort.direction === "asc" ? "desc" : "asc"
      setLocalSortState({ column: sortKey, direction: nextDirection })
      return
    }
    if (!onNavigate) return

    const nextDirection = activeSort.column === sortKey && activeSort.direction === "asc" ? "desc" : "asc"
    const next = new URLSearchParams(search || "")
    next.set("sort", sortKey)
    next.set("direction", nextDirection)
    next.delete("page")
    onNavigate(next)
  }

  const sortedRows = useMemo(() => {
    if (!localSort) return rows
    const column = columns.find((candidate) => candidate.sort === activeSort.column)
    if (!column?.sortValue) return rows
    const direction = activeSort.direction === "asc" ? 1 : -1
    return rows.slice().sort((left, right) => compareSortValues(column.sortValue!(left), column.sortValue!(right)) * direction)
  }, [activeSort.column, activeSort.direction, columns, localSort, rows])

  const columnMenu = (
    <DataTableColumnMenu
      columns={dataTableColumns}
      downLabel={t("event_log_table.column_down")}
      menuId={`${storageKey}-columns-menu`}
      moveDownLabel={(title) => t("event_log_table.column_move_down", { title })}
      moveUpLabel={(title) => t("event_log_table.column_move_up", { title })}
      onChange={preferences.onChange}
      order={preferences.order}
      triggerAriaLabel={t("event_log_table.columns")}
      upLabel={t("event_log_table.column_up")}
      visibleLabel={t("event_log_table.visible_columns")}
    />
  )

  const table = (
      <DataTable.Root className={tableClassName} wrapperClassName={panel ? "rounded-none border-0" : undefined}>
        <DataTable.Header>
          <DataTableColumnHeaderRow
            columns={dataTableColumns}
            onReorder={preferences.onChange}
            onSort={onNavigate || localSort ? sortTo : undefined}
            order={preferences.order}
            sortColumn={activeSort.column}
            sortDirection={sortDirection}
          />
        </DataTable.Header>
        <DataTable.Body>
          {sortedRows.map((row) => {
            const rowKey = getRowKey(row)
            const expanded = expandedKey === rowKey

            return (
              <Fragment key={rowKey}>
                <DataTable.Row>
                  <DataTableColumnCells columns={dataTableColumns} order={preferences.order} row={row} />
                </DataTable.Row>
                {expanded && renderExpanded ? (
                  <DataTable.Row groupHeader>
                    <DataTable.Cell className="bg-gray-50 px-4 py-4 dark:bg-gray-950/40" colSpan={colSpan}>
                      {renderExpanded(row)}
                    </DataTable.Cell>
                  </DataTable.Row>
                ) : null}
              </Fragment>
            )
          })}
        </DataTable.Body>
      </DataTable.Root>
  )

  if (panel) return <AdminDataTablePanel columnSelector={columnMenu} config={panel}>{table}</AdminDataTablePanel>

  return (
    <>
      <div className="flex justify-end pb-2">{columnMenu}</div>
      {table}
    </>
  )
}

function compareSortValues(left: number | string | null | undefined, right: number | string | null | undefined) {
  if (left == null && right == null) return 0
  if (left == null) return 1
  if (right == null) return -1
  if (typeof left === "number" && typeof right === "number") return left - right
  return String(left).localeCompare(String(right), undefined, { numeric: true, sensitivity: "base" })
}

export function inputClass() {
  return "w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:border-gray-500 focus:outline-none focus:ring-1 focus:ring-gray-500 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500"
}

export type AdminEventFilterField = {
  name: string
  label: string
  placeholder?: string
  defaultValue?: string
  inputMode?: "numeric"
  options?: Array<{ label: string; value: string }>
}

export type AdminEventFilterPayload = {
  filter?: Record<string, unknown> | null
  filter_schema?: FilterSchemaField[]
}

export function AdminEventFilterBar({
  buildLink,
  filter,
  filterSchema,
  fields,
  search
}: {
  buildLink?: (pathname: string, search: string, updates: FilterLinkUpdates) => string
  filter?: Record<string, unknown> | null
  filterSchema?: FilterSchemaField[]
  fields?: AdminEventFilterField[]
  onNavigate?: (params: URLSearchParams) => void
  search: string
  searchLabel: string
  clearLabel: string
}) {
  const fallbackFields = fields || []
  const schema = useMemo(() => filterSchema || adminEventFilterSchema(fallbackFields), [fallbackFields, filterSchema])
  const activeFilter = useMemo(() => filter || adminEventFilterTree(fallbackFields, search), [fallbackFields, filter, search])
  // Restores the mobile gutter AdminEventPageShell's Page.Root drops for its
  // children, so every consumer's filter bar stays margined like the header
  // without having to opt in itself.
  const gutterRestore = usePageGutterRestoreClassName("margin")

  return (
    <FilterBar
      buildLink={buildLink ?? preserveExplicitEmptyFilter}
      className={classes("space-y-2", gutterRestore)}
      filter={activeFilter}
      filterSchema={schema}
      legacyFilterKeys={fallbackFields.map((field) => field.name)}
      pathname=""
      search={search}
    />
  )
}

// Removing the last filter chip (or "Clear filters") would otherwise drop the
// `q` param entirely, making an explicitly-cleared filter set indistinguishable
// from a page that was never filtered. The backend re-applies its field
// defaults (since/revision_scope/per_page) whenever no explicit `q` is present,
// so an omitted `q` caused the just-removed chip to reappear immediately. Keep
// `q` present (encoding an empty filter tree) so the empty state sticks.
function preserveExplicitEmptyFilter(pathname: string, search: string, updates: FilterLinkUpdates) {
  const nextUpdates = "q" in updates && updates.q == null ? { ...updates, q: encodeFilterTree({ and: [] }) } : updates
  return linkFromSearch(pathname, search, nextUpdates)
}

function adminEventFilterSchema(fields: AdminEventFilterField[]): FilterSchemaField[] {
  return fields.map((field) => ({
    bucket: field.options ? "enum" : field.inputMode === "numeric" ? "number" : "text",
    expansions: field.placeholder ? { placeholder: field.placeholder } : undefined,
    field: field.name,
    label: field.label,
    operators: ["is"],
    values: field.options
  }))
}

function adminEventFilterTree(fields: AdminEventFilterField[], search: string): FilterTree {
  const params = new URLSearchParams(search)
  const chips = fields.flatMap((field): FilterChip[] => {
    const value = params.get(field.name) || field.defaultValue || ""
    return value ? [{ field: field.name, op: "is", value }] : []
  })
  return { and: chips }
}

export function pageButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-1.5 font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
}

export function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
}

export function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-400 dark:border-gray-800 dark:text-gray-600"
}

export function adminEventLinkClass() {
  return "text-brand underline hover:no-underline dark:text-brand-emphasis"
}

export function severityPillClass(severity: string) {
  if (severity === "alarm" || severity === "error") return "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-300"
  if (severity === "warn") return "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-300"
  return "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"
}

export function durationLabel(value: number | null) {
  if (value == null) return "-"
  if (value >= 60_000) return `${(value / 60_000).toFixed(1)}m`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}s`
  return `${Math.round(value)}ms`
}

export type AdminEventTimelineBucket = {
  start_at: string
  end_at: string
  count: number
}

export function formatEventDate(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

export function shortRevision(value: string | null | undefined) {
  if (!value) return "-"
  return value.length > 12 ? value.slice(0, 12) : value
}

export function DetailBlock({ title, value }: { title: string; value?: string | null }) {
  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-text-muted">{title}</h3>
      <pre className="mt-2 max-h-80 overflow-auto rounded border border-border bg-surface p-3 text-xs leading-5 text-text-primary">
        {value || "-"}
      </pre>
    </section>
  )
}

export function JsonBlock({ title, value }: { title: string; value: unknown }) {
  return <DetailBlock title={title} value={JSON.stringify(value, null, 2)} />
}
