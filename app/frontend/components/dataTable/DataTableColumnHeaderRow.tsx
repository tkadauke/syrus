import type { ComponentProps } from "react"
import { classes } from "../ui/classes"
import { DataTable, type DataTableSortDirection } from "../ui/DataTable"
import { visibleColumns, visibleColumnsForKeys, visibleOptionalColumnKeys } from "./columnOrder"
import type { DataTableColumnDef } from "./types"
import { useDragReorder } from "./useDragReorder"

// Renders a full <DataTable.Row> of <DataTable.HeadCell>s from the shared
// column model, with drag-and-drop reordering wired onto the whole header
// cell (not just its label) -- since DataTableColumnCells below derives the
// body from the same `visibleColumnsForKeys` ordering, dragging a header
// reorders the whole rendered column. Required/pinned columns are never
// draggable, matching DataTableColumnMenu excluding them from the picker.
//
// Sortable-header click behavior (DataTable.HeadCell's own onSort button) is
// untouched: dragging only attaches drag handlers to the <th>, so a plain
// click still reaches the sort button, and a drag gesture never calls
// onSort. The move up/down buttons in DataTableColumnMenu remain the
// keyboard-accessible way to reorder; dragging a header has no keyboard
// equivalent by design.
export function DataTableColumnHeaderRow<TRow>({
  columns,
  onReorder,
  onSort,
  order,
  reorderDisabled = false,
  rowProps,
  sortColumn,
  sortDirection = "none"
}: {
  columns: DataTableColumnDef<TRow>[]
  onReorder?: (nextOrder: string[]) => void
  onSort?: (sortKey: string) => void
  order: string[] | null | undefined
  reorderDisabled?: boolean
  rowProps?: ComponentProps<typeof DataTable.Row>
  sortColumn?: string | null
  sortDirection?: DataTableSortDirection
}) {
  const { dragOverKey, dragProps, order: liveVisibleKeys } = useDragReorder({
    disabled: reorderDisabled || !onReorder,
    keys: visibleOptionalColumnKeys({ columns, order }),
    onReorder: (nextOrder) => onReorder?.(nextOrder)
  })
  const visible = visibleColumnsForKeys(columns, liveVisibleKeys)

  return (
    <DataTable.Row {...rowProps}>
      {visible.map((column) => {
        const draggable = !column.required && !reorderDisabled && Boolean(onReorder)
        return (
          <DataTable.HeadCell
            align={column.align}
            className={classes(column.responsiveClassName, column.headClassName, dragOverKey === column.key && "outline outline-2 -outline-offset-2 outline-brand")}
            key={column.key}
            onSort={column.sortKey && onSort ? () => onSort(column.sortKey!) : undefined}
            sortDirection={column.sortKey && sortColumn === column.sortKey ? sortDirection : "none"}
            sortable={Boolean(column.sortKey)}
            {...(draggable ? dragProps(column.key) : {})}
          >
            {column.renderHeader ? column.renderHeader() : column.label}
          </DataTable.HeadCell>
        )
      })}
    </DataTable.Row>
  )
}

// Renders the body cells for one row, using the same column ordering
// DataTableColumnHeaderRow renders headers with -- pass the same `columns`
// and `order` to both so the header and body cells never drift apart.
export function DataTableColumnCells<TRow>({
  columns,
  order,
  row
}: {
  columns: DataTableColumnDef<TRow>[]
  order: string[] | null | undefined
  row: TRow
}) {
  const visible = visibleColumns({ columns, order })

  return (
    <>
      {visible.map((column) => (
        <DataTable.Cell align={column.align} className={classes(column.responsiveClassName, column.cellClassName)} key={column.key}>
          {column.renderCell(row)}
        </DataTable.Cell>
      ))}
    </>
  )
}
