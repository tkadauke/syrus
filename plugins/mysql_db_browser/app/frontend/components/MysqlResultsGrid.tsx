import { useT } from "@app/hooks/useT"

export type MysqlGridSort = { column: string; direction: "asc" | "desc" }

// Grid-first results table shared by the Content, Query, and Live tabs.
// Sortable headers follow JobsTable.tsx's SortableColumnHeader pattern (a
// button with an aria-sort th and an arrow indicator) rather than importing
// the Dashboard-specific component, since that one is wired to URL-driven
// DashboardSortState.
export function MysqlResultsGrid({
  columns,
  rows,
  sort,
  onSort
}: {
  columns: string[]
  rows: Array<Record<string, unknown>>
  sort?: MysqlGridSort | null
  onSort?: (column: string) => void
}) {
  const { t } = useT("mysql_db_browser")

  if (columns.length === 0) {
    return <p className="p-4 text-sm text-gray-500 dark:text-gray-400">{t("grid_no_columns")}</p>
  }

  return (
    <div className="max-h-[32rem] overflow-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-xs">
        <thead className="sticky top-0 bg-gray-50 dark:bg-gray-900 text-left uppercase text-gray-500 dark:text-gray-400">
          <tr>
            {columns.map((column) => (
              <th aria-sort={sort?.column === column ? (sort.direction === "asc" ? "ascending" : "descending") : undefined} className="whitespace-nowrap px-3 py-2 font-semibold" key={column}>
                <MysqlSortableHeader column={column} onSort={onSort} sort={sort ?? null} />
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
          {rows.length === 0 ? (
            <tr>
              <td className="px-3 py-6 text-center text-gray-500 dark:text-gray-400" colSpan={columns.length}>{t("grid_no_rows")}</td>
            </tr>
          ) : (
            rows.map((row, index) => (
              <tr key={index}>
                {columns.map((column) => {
                  const value = row[column]
                  const formatted = formatMysqlCellValue(value)
                  return (
                    <td className="max-w-xs truncate px-3 py-1.5 font-mono text-gray-700 dark:text-gray-300" key={column} title={formatted}>
                      {value === null || value === undefined ? <span className="italic text-gray-400 dark:text-gray-600">NULL</span> : formatted}
                    </td>
                  )
                })}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  )
}

function MysqlSortableHeader({ column, onSort, sort }: { column: string; onSort?: (column: string) => void; sort: MysqlGridSort | null }) {
  const { t } = useT("mysql_db_browser")
  if (!onSort) return <span>{column}</span>

  const active = sort?.column === column
  const nextDirection = active && sort?.direction === "asc" ? "desc" : "asc"

  return (
    <button
      aria-label={t("grid_sort_by", { column, direction: nextDirection })}
      className="inline-flex items-center gap-1 text-left font-semibold uppercase text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
      onClick={() => onSort(column)}
      type="button"
    >
      <span>{column}</span>
      {active ? <span aria-hidden="true" className="text-[10px] leading-none text-gray-700 dark:text-gray-300">{sort.direction === "asc" ? "↑" : "↓"}</span> : null}
    </button>
  )
}

export function formatMysqlCellValue(value: unknown): string {
  if (value === null || value === undefined) return "NULL"
  if (typeof value === "object") return JSON.stringify(value)
  return String(value)
}
