import { useMemo } from "react"
import { useT } from "@app/hooks/useT"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  visibleColumns,
  type DataTableColumnDef
} from "@app/components/dataTable"
import { DataTable, type DataTableSortDirection } from "@app/components/ui"

export type MysqlGridSort = { column: string; direction: "asc" | "desc" }

// Grid-first results table shared by the Content, Query Builder, Query, and
// Live tabs. It only owns presentation preferences (visibility + order);
// filtering, sorting, limits, and SQL safety still flow through the existing
// query endpoints.
export function MysqlResultsGrid({
  columns,
  rows,
  sort,
  onSort,
  storageKey
}: {
  columns: string[]
  rows: Array<Record<string, unknown>>
  sort?: MysqlGridSort | null
  onSort?: (column: string) => void
  storageKey: string
}) {
  const { t } = useT("mysql_db_browser")
  const { t: adminT } = useT("admin")

  const dataTableColumns = useMemo<DataTableColumnDef<Record<string, unknown>>[]>(
    () =>
      columns.map((column) => ({
        key: column,
        label: column,
        sortKey: column,
        cellClassName: "max-w-xs truncate font-mono text-gray-700 dark:text-gray-300",
        renderCell: (row) => {
          const value = row[column]
          const formatted = formatMysqlCellValue(value)
          return value === null || value === undefined ? (
            <span className="italic text-gray-400 dark:text-gray-600">NULL</span>
          ) : (
            <span title={formatted}>{formatted}</span>
          )
        }
      })),
    [columns]
  )
  const preferences = useLocalStorageColumnPreferences({ columns: dataTableColumns, storageKey })
  const sortDirection: DataTableSortDirection = sort?.direction === "asc" ? "ascending" : sort?.direction === "desc" ? "descending" : "none"
  const colSpan = Math.max(1, visibleColumns({ columns: dataTableColumns, order: preferences.order }).length)

  if (columns.length === 0) {
    return <p className="p-4 text-sm text-gray-500 dark:text-gray-400">{t("grid_no_columns")}</p>
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-2">
      <div className="flex shrink-0 justify-end">
        <DataTableColumnMenu
          columns={dataTableColumns}
          downLabel={adminT("event_log_table.column_down")}
          menuId={`${storageKey}-columns-menu`}
          moveDownLabel={(title) => adminT("event_log_table.column_move_down", { title })}
          moveUpLabel={(title) => adminT("event_log_table.column_move_up", { title })}
          onChange={preferences.onChange}
          order={preferences.order}
          triggerAriaLabel={adminT("event_log_table.columns")}
          upLabel={adminT("event_log_table.column_up")}
          visibleLabel={adminT("event_log_table.visible_columns")}
        />
      </div>
      <DataTable.Root className="table-fixed text-xs" density="compact" wrapperClassName="min-h-0 flex-1 overflow-auto rounded-none border-0">
        <DataTable.Header className="sticky top-0 z-10">
          <DataTableColumnHeaderRow
            columns={dataTableColumns}
            onReorder={preferences.onChange}
            onSort={onSort}
            order={preferences.order}
            sortColumn={sort?.column}
            sortDirection={sortDirection}
          />
        </DataTable.Header>
        <DataTable.Body>
          {rows.length === 0 ? (
            <DataTable.Empty colSpan={colSpan}>{t("grid_no_rows")}</DataTable.Empty>
          ) : (
            rows.map((row, index) => (
              <DataTable.Row key={index}>
                <DataTableColumnCells columns={dataTableColumns} order={preferences.order} row={row} />
              </DataTable.Row>
            ))
          )}
        </DataTable.Body>
      </DataTable.Root>
    </div>
  )
}

export function formatMysqlCellValue(value: unknown): string {
  if (value === null || value === undefined) return "NULL"
  if (typeof value === "object") return JSON.stringify(value)
  return String(value)
}
