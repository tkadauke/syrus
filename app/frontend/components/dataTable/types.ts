import type { ReactNode } from "react"
import type { DataTableAlign } from "../ui/DataTable"

export type DataTableColumnPin = "start" | "end"

// The shared column model every configurable DataTable surface (Dashboard,
// Repositories, admin event tables, ...) can describe itself with, so the
// visibility/reorder menu, the table header row, and the table body cells
// all read from one definition instead of three hand-synced lists.
export interface DataTableColumnDef<TRow> {
  key: string
  label: string
  // Required columns are always visible and never appear in the picker menu
  // or accept drag reordering -- e.g. a selection checkbox or a row-actions
  // column. `pin` controls which end of the rendered row they anchor to;
  // omitted defaults to "start" (matches the existing Dashboard convention
  // of rendering required columns before the optional ones).
  required?: boolean
  pin?: DataTableColumnPin
  // Only consulted for optional columns with no stored preference yet.
  // Defaults to visible.
  defaultVisible?: boolean
  align?: DataTableAlign
  // Present only on columns a caller can sort by; absent renders a
  // non-interactive header even when adjacent columns are sortable.
  sortKey?: string
  // Applied to both the head cell and the body cells so a column can hide
  // itself responsively (e.g. "hidden lg:table-cell") without the header
  // and its cells drifting out of sync.
  responsiveClassName?: string
  headClassName?: string
  cellClassName?: string
  renderCell: (row: TRow) => ReactNode
  // Defaults to `label` when omitted.
  renderHeader?: () => ReactNode
}

// The shape every persistence adapter (server preferences, localStorage,
// an in-memory harness) produces -- the picker menu and header row only
// ever talk to this interface, never to a specific storage mechanism.
export interface DataTableColumnPreferences {
  order: string[] | null | undefined
  onChange: (nextOrder: string[]) => void
  pending?: boolean
  error?: unknown
}
