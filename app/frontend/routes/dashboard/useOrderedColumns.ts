import { useMemo } from "react"
import { useDragReorder } from "../../components/dataTable"

// Shared drag-reorder wiring for the Jobs/Epics/Workflows dashboard tables:
// required columns (dynamic for jobs, static for epics/workflows) stay
// pinned first in their given order; only the optional tail is draggable,
// and the live (possibly mid-drag) order is what both the header row and
// every row variant render from, so dragging a header moves the whole
// column everywhere at once rather than just its label.
export function useOrderedColumns({
  columns,
  onReorderColumns,
  reorderPending,
  requiredColumns
}: {
  columns: string[]
  onReorderColumns?: (nextOrder: string[]) => void
  reorderPending?: boolean
  requiredColumns: string[]
}) {
  const requiredColumnSet = useMemo(() => new Set(requiredColumns), [requiredColumns])
  const optionalColumnsInOrder = useMemo(() => columns.filter((column) => !requiredColumnSet.has(column)), [columns, requiredColumnSet])
  const { dragOverKey, dragProps, order: liveOptionalOrder } = useDragReorder({
    disabled: !onReorderColumns || Boolean(reorderPending),
    keys: optionalColumnsInOrder,
    onReorder: (nextOrder) => onReorderColumns?.(nextOrder)
  })
  const orderedColumns = useMemo(() => [
    ...requiredColumns.filter((column) => columns.includes(column)),
    ...liveOptionalOrder
  ], [columns, liveOptionalOrder, requiredColumns])

  function draggable(column: string) {
    return !requiredColumnSet.has(column) && Boolean(onReorderColumns) && !reorderPending
  }

  return { dragOverKey, dragProps, draggable, orderedColumns }
}
