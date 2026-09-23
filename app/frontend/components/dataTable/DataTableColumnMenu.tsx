import { useState } from "react"
import { Button, type ButtonSize } from "../Button"
import { Checkbox } from "../Checkbox"
import { Surface } from "../ui"
import { errorMessage } from "../../lib/errorMessage"
import { useDismissiblePopup } from "../../lib/useDismissiblePopup"
import { menuColumnsForKeys, reorderColumnKeys, visibleOptionalColumnKeys } from "./columnOrder"
import type { DataTableColumnDef } from "./types"
import { useDragReorder } from "./useDragReorder"

const MOVE_BUTTON_CLASS = "rounded px-1 text-[length:var(--text-caption)] text-text-secondary hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"

// The reusable column picker: checkbox visibility toggles plus reordering,
// generalized from ColumnVisibilityMenu to the shared DataTableColumnDef
// model (sort metadata, responsive classes, required/pinned columns) so new
// DataTable surfaces don't need a bespoke picker. Required columns never
// appear here -- they're always visible (see columnOrder#visibleColumns).
//
// Reordering has two independent affordances over the same `order` state:
// dragging a row (mouse-only, native HTML5 drag-and-drop), and the move
// up/down buttons (keyboard- and screen-reader-accessible). The buttons are
// the real accessibility guarantee; dragging is a convenience layered on
// top, never a replacement.
export function DataTableColumnMenu<TRow>({
  className,
  columns,
  downLabel,
  error,
  errorFallback,
  menuId,
  moveDownLabel,
  moveUpLabel,
  onChange,
  order,
  pending = false,
  triggerAriaLabel,
  triggerClassName = "h-9 w-9",
  triggerSize = "sm",
  upLabel,
  visibleLabel
}: {
  className?: string
  columns: DataTableColumnDef<TRow>[]
  downLabel: string
  error?: unknown
  errorFallback?: string
  menuId: string
  moveDownLabel: (label: string) => string
  moveUpLabel: (label: string) => string
  onChange: (nextOrder: string[]) => void
  order: string[] | null | undefined
  pending?: boolean
  triggerAriaLabel: string
  triggerClassName?: string
  triggerSize?: ButtonSize
  upLabel: string
  visibleLabel: string
}) {
  const [ open, setOpen ] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))

  const { dragProps, order: liveVisibleKeys } = useDragReorder({
    disabled: pending,
    keys: visibleOptionalColumnKeys({ columns, order }),
    onReorder: onChange
  })
  const rows = menuColumnsForKeys(columns, liveVisibleKeys)
  const visible = new Set(liveVisibleKeys)

  function toggleColumn(key: string, checked: boolean) {
    const current = visibleOptionalColumnKeys({ columns, order })
    const next = checked ? [ ...current, key ].filter((value, index, values) => values.indexOf(value) === index) : current.filter((value) => value !== key)
    onChange(next)
  }

  function moveColumn(key: string, direction: -1 | 1) {
    const current = visibleOptionalColumnKeys({ columns, order })
    const index = current.indexOf(key)
    const target = index + direction
    if (index < 0 || target < 0 || target >= current.length) return

    onChange(reorderColumnKeys(current, key, current[target]))
  }

  return (
    <div className={`relative ${className ?? ""}`.trim()} ref={menuRef}>
      <Button
        aria-controls={menuId}
        aria-expanded={open}
        aria-haspopup="menu"
        aria-label={triggerAriaLabel}
        className={triggerClassName}
        onClick={() => setOpen((value) => !value)}
        size={triggerSize}
        variant="secondary"
      >
        <ColumnsIcon />
      </Button>
      {open ? (
        <Surface className="absolute right-0 z-20 mt-2 w-72 shadow-lg" id={menuId} padding="sm" role="menu">
          <fieldset className="space-y-2">
            <legend className="text-[length:var(--text-caption)] font-semibold uppercase text-text-muted">{visibleLabel}</legend>
            {rows.map((column) => {
              const checked = visible.has(column.key)
              return (
                <div
                  className="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] items-center gap-2 text-[length:var(--text-body)] text-text-primary"
                  key={column.key}
                  {...(checked ? dragProps(column.key) : {})}
                >
                  {checked ? <GripIcon /> : <span aria-hidden="true" className="w-4" />}
                  <label className="flex min-w-0 items-center gap-2">
                    <Checkbox
                      checked={checked}
                      disabled={pending}
                      onChange={(event) => toggleColumn(column.key, event.target.checked)}
                    />
                    <span className="truncate">{column.label}</span>
                  </label>
                  <button
                    aria-label={moveUpLabel(column.label)}
                    className={MOVE_BUTTON_CLASS}
                    disabled={!checked || pending}
                    onClick={() => moveColumn(column.key, -1)}
                    type="button"
                  >
                    {upLabel}
                  </button>
                  <button
                    aria-label={moveDownLabel(column.label)}
                    className={MOVE_BUTTON_CLASS}
                    disabled={!checked || pending}
                    onClick={() => moveColumn(column.key, 1)}
                    type="button"
                  >
                    {downLabel}
                  </button>
                </div>
              )
            })}
          </fieldset>
          {error ? <p className="mt-2 text-[length:var(--text-caption)] text-danger-text" role="alert">{errorMessage(error, errorFallback ?? "")}</p> : null}
        </Surface>
      ) : null}
    </div>
  )
}

function ColumnsIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path d="M7 4v16M17 4v16M5 5h14M5 12h14M5 19h14" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
  )
}

function GripIcon() {
  return (
    <svg aria-hidden="true" className="size-4 shrink-0 cursor-grab text-text-subtle active:cursor-grabbing" fill="none" viewBox="0 0 16 16">
      <circle cx="6" cy="4" fill="currentColor" r="1" />
      <circle cx="10" cy="4" fill="currentColor" r="1" />
      <circle cx="6" cy="8" fill="currentColor" r="1" />
      <circle cx="10" cy="8" fill="currentColor" r="1" />
      <circle cx="6" cy="12" fill="currentColor" r="1" />
      <circle cx="10" cy="12" fill="currentColor" r="1" />
    </svg>
  )
}
