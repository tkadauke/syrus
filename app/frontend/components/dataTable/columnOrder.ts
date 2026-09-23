import type { DataTableColumnDef } from "./types"

function uniqueValue<T>(value: T, index: number, values: T[]) {
  return values.indexOf(value) === index
}

function defaultOptionalOrder<TRow>(columns: DataTableColumnDef<TRow>[]): string[] {
  return columns.filter((column) => !column.required && column.defaultVisible !== false).map((column) => column.key)
}

function columnsForKeys<TRow>(columns: DataTableColumnDef<TRow>[], keys: string[]): DataTableColumnDef<TRow>[] {
  return keys
    .map((key) => columns.find((column) => column.key === key))
    .filter((column): column is DataTableColumnDef<TRow> => column != null)
}

// The optional (non-required) columns currently visible, in the caller's
// preferred order. Unknown/removed keys are dropped and duplicates collapse
// to their first occurrence -- this is the exact shape a persistence
// adapter's `order` represents and the shape drag reordering operates on.
export function visibleOptionalColumnKeys<TRow>({ columns, order }: { columns: DataTableColumnDef<TRow>[]; order: string[] | null | undefined }): string[] {
  const optionalKeys = new Set(columns.filter((column) => !column.required).map((column) => column.key))
  const preferred = (order ?? defaultOptionalOrder(columns)).filter((key) => optionalKeys.has(key))
  return preferred.filter(uniqueValue)
}

// Every optional column: checked ones first in preference order, followed by
// unchecked ones in definition order. This is the shape the picker menu
// renders -- required columns never appear here at all.
export function menuColumns<TRow>({ columns, order }: { columns: DataTableColumnDef<TRow>[]; order: string[] | null | undefined }): DataTableColumnDef<TRow>[] {
  return menuColumnsForKeys(columns, visibleOptionalColumnKeys({ columns, order }))
}

// Same as `menuColumns`, but takes an already-resolved list of visible
// optional keys -- used to render the picker menu from an in-progress
// drag's live (uncommitted) order. Unlike `visibleColumnsForKeys` below, this
// appends the *hidden* optional columns too (in definition order) because the
// menu still needs to offer them as unchecked options.
export function menuColumnsForKeys<TRow>(columns: DataTableColumnDef<TRow>[], visibleOptionalKeys: string[]): DataTableColumnDef<TRow>[] {
  const optional = columns.filter((column) => !column.required)
  const visibleSet = new Set(visibleOptionalKeys)
  const orderedKeys = [ ...visibleOptionalKeys, ...optional.map((column) => column.key).filter((key) => !visibleSet.has(key)) ]
  return columnsForKeys(optional, orderedKeys)
}

// The full set of columns to render in the table: required columns pinned to
// their declared end (start unless `pin: "end"`), optional columns filtered
// to what's visible and ordered by preference in between. The header row and
// the body cells should both derive from this single function so dragging a
// header reorders the whole rendered column, not just its label.
export function visibleColumns<TRow>({ columns, order }: { columns: DataTableColumnDef<TRow>[]; order: string[] | null | undefined }): DataTableColumnDef<TRow>[] {
  return visibleColumnsForKeys(columns, visibleOptionalColumnKeys({ columns, order }))
}

// Same as `visibleColumns`, but takes an already-resolved list of visible
// optional keys instead of a persisted `order` -- used to render the table
// from an in-progress drag's live (uncommitted) order. Hidden optional
// columns are dropped entirely (unlike `menuColumnsForKeys`, which still
// needs to list them as unchecked options).
export function visibleColumnsForKeys<TRow>(columns: DataTableColumnDef<TRow>[], visibleOptionalKeys: string[]): DataTableColumnDef<TRow>[] {
  const startPinned = columns.filter((column) => column.required && column.pin !== "end")
  const endPinned = columns.filter((column) => column.required && column.pin === "end")
  const visibleOptional = columnsForKeys(columns, visibleOptionalKeys)

  return [ ...startPinned, ...visibleOptional, ...endPinned ]
}

export function visibleColumnKeys<TRow>(args: { columns: DataTableColumnDef<TRow>[]; order: string[] | null | undefined }): string[] {
  return visibleColumns(args).map((column) => column.key)
}

// Moves `fromKey` to `toKey`'s position within `order`. No-ops (returning the
// same array reference) when either key is missing or they're identical, so
// callers can skip an onChange when nothing actually moved.
export function reorderColumnKeys<TKey extends string>(order: TKey[], fromKey: TKey, toKey: TKey): TKey[] {
  if (fromKey === toKey) return order

  const fromIndex = order.indexOf(fromKey)
  const toIndex = order.indexOf(toKey)
  if (fromIndex < 0 || toIndex < 0) return order

  const next = [ ...order ]
  const [ moved ] = next.splice(fromIndex, 1)
  next.splice(toIndex, 0, moved)
  return next
}
