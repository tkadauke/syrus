import { useState } from "react"
import { Button, type ButtonSize } from "./Button"
import { Checkbox } from "./Checkbox"
import { Surface } from "./ui"
import { errorMessage } from "../lib/errorMessage"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"

export type ColumnOption = { key: string; title: string }

// Normalization helpers for "toggle + reorder optional table columns"
// preference UIs. A caller's stored preference is a flat visible_columns
// array that may be missing, may include required columns, or may reference
// columns the caller no longer offers -- these helpers are the single place
// that reconciles that against the column definitions the caller currently
// has.
//
// Dashboard and Repositories have both moved to the generalized
// DataTableColumnDef-based primitive in ./dataTable (DataTableColumnMenu +
// columnOrder.ts's visibleColumnKeys/visibleOptionalColumnKeys), which adds
// header drag-and-drop reordering on top of this component's picker-only
// move-up/down. This component and its helpers stay only because the
// design_docs plugin (plugins/design_docs/app/frontend/components/
// DesignDocsSurface.tsx) still imports them directly; migrating Design Docs
// onto the shared primitive is a separate, not-yet-scheduled piece of work.
// Do not add new callers here -- build against ./dataTable instead.

function uniqueValue(value: string, index: number, values: string[]) {
  return values.indexOf(value) === index
}

const MOVE_BUTTON_CLASS = "rounded px-1 text-[length:var(--text-caption)] text-text-secondary hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"

export function visibleOptionalColumnKeys({ optionalColumns, visibleColumns }: {
  optionalColumns: ColumnOption[]
  visibleColumns: string[] | null | undefined
}): string[] {
  const optional = new Set(optionalColumns.map((column) => column.key))
  const preferred = (visibleColumns ?? optionalColumns.map((column) => column.key)).filter((key) => optional.has(key))
  return preferred.filter(uniqueValue)
}

export function orderedOptionalColumns({ optionalColumns, visibleColumns }: {
  optionalColumns: ColumnOption[]
  visibleColumns: string[] | null | undefined
}): ColumnOption[] {
  const visible = visibleOptionalColumnKeys({ optionalColumns, visibleColumns })
  const visibleSet = new Set(visible)
  const orderedKeys = [ ...visible, ...optionalColumns.map((column) => column.key).filter((key) => !visibleSet.has(key)) ]
  return orderedKeys
    .map((key) => optionalColumns.find((column) => column.key === key))
    .filter((column): column is ColumnOption => column != null)
}

export function visibleColumnKeys({ requiredColumns, optionalColumns, visibleColumns }: {
  requiredColumns: ColumnOption[]
  optionalColumns: ColumnOption[]
  visibleColumns: string[] | null | undefined
}): string[] {
  const allowed = new Set([ ...requiredColumns, ...optionalColumns ].map((column) => column.key))
  const required = requiredColumns.map((column) => column.key)
  const preferred = visibleColumns ?? optionalColumns.map((column) => column.key)
  const normalized = [ ...required, ...preferred ].filter((column, index, columns) => allowed.has(column) && columns.indexOf(column) === index)
  return normalized.length > 0 ? normalized : required
}

export function ColumnVisibilityMenu({
  className,
  error,
  errorFallback,
  menuId,
  moveDownLabel,
  moveUpLabel,
  onChange,
  optionalColumns,
  pending = false,
  triggerAriaLabel,
  triggerClassName = "h-9 w-9",
  triggerSize = "sm",
  visibleColumns,
  visibleLabel,
  downLabel,
  upLabel
}: {
  className?: string
  error?: unknown
  errorFallback?: string
  menuId: string
  moveDownLabel: (title: string) => string
  moveUpLabel: (title: string) => string
  onChange: (nextVisibleOptionalColumns: string[]) => void
  optionalColumns: ColumnOption[]
  pending?: boolean
  triggerAriaLabel: string
  triggerClassName?: string
  triggerSize?: ButtonSize
  visibleColumns: string[] | null | undefined
  visibleLabel: string
  downLabel: string
  upLabel: string
}) {
  const [open, setOpen] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const menuColumns = orderedOptionalColumns({ optionalColumns, visibleColumns })
  const visible = new Set(visibleOptionalColumnKeys({ optionalColumns, visibleColumns }))

  function updateColumn(column: string, checked: boolean) {
    const current = visibleOptionalColumnKeys({ optionalColumns, visibleColumns })
    const next = checked ? [ ...current, column ].filter(uniqueValue) : current.filter((value) => value !== column)
    onChange(next)
  }

  function moveColumn(column: string, direction: -1 | 1) {
    const current = visibleOptionalColumnKeys({ optionalColumns, visibleColumns })
    const index = current.indexOf(column)
    const target = index + direction
    if (index < 0 || target < 0 || target >= current.length) return

    const next = [ ...current ]
    const [moved] = next.splice(index, 1)
    next.splice(target, 0, moved)
    onChange(next)
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
            {menuColumns.map((column) => {
              const checked = visible.has(column.key)
              return (
                <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-2 text-[length:var(--text-body)] text-text-primary" key={column.key}>
                  <label className="flex min-w-0 items-center gap-2">
                    <Checkbox
                      checked={checked}
                      disabled={pending}
                      onChange={(event) => updateColumn(column.key, event.target.checked)}
                    />
                    <span className="truncate">{column.title}</span>
                  </label>
                  <button
                    aria-label={moveUpLabel(column.title)}
                    className={MOVE_BUTTON_CLASS}
                    disabled={!checked || pending}
                    onClick={() => moveColumn(column.key, -1)}
                    type="button"
                  >
                    {upLabel}
                  </button>
                  <button
                    aria-label={moveDownLabel(column.title)}
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
