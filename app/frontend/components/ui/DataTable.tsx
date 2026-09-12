import { createContext, useContext } from "react"
import type { HTMLAttributes, TableHTMLAttributes, TdHTMLAttributes, ThHTMLAttributes } from "react"
import { classes } from "./classes"

export type DataTableDensity = "default" | "compact"
export type DataTableAlign = "left" | "center" | "right"
export type DataTableSortDirection = "ascending" | "descending" | "none"

export interface DataTableRootProps extends TableHTMLAttributes<HTMLTableElement> {
  density?: DataTableDensity
  wrapperClassName?: string
}

export interface DataTableRowProps extends HTMLAttributes<HTMLTableRowElement> {
  groupHeader?: boolean
  interactive?: boolean
}

export interface DataTableHeadCellProps extends ThHTMLAttributes<HTMLTableCellElement> {
  align?: DataTableAlign
  checkbox?: boolean
  onSort?: () => void
  sortDirection?: DataTableSortDirection
  sortable?: boolean
}

export interface DataTableCellProps extends TdHTMLAttributes<HTMLTableCellElement> {
  align?: DataTableAlign
  checkbox?: boolean
}

export interface DataTableEmptyProps extends TdHTMLAttributes<HTMLTableCellElement> {
  colSpan?: number
}

type DataTableContextValue = {
  density: DataTableDensity
}

const DataTableContext = createContext<DataTableContextValue>({ density: "default" })

const TABLE_DENSITY_CLASSES: Record<DataTableDensity, string> = {
  default: "[--data-table-cell-py:0.75rem] [--data-table-row-min-height:var(--table-row-height,3rem)]",
  compact: "[--data-table-cell-py:0.5rem] [--data-table-row-min-height:2.25rem]"
}

const ALIGN_CLASSES: Record<DataTableAlign, string> = {
  left: "text-left",
  center: "text-center",
  right: "text-right"
}

function Root({ children, className = "", density = "default", wrapperClassName = "", ...props }: DataTableRootProps) {
  return (
    <DataTableContext.Provider value={{ density }}>
      <div className={classes("w-full overflow-x-auto rounded-[var(--radius-panel)] border border-border bg-surface", wrapperClassName)} data-data-table-overflow-wrapper="true">
        <table className={classes("min-w-full divide-y divide-border text-sm text-text-primary", TABLE_DENSITY_CLASSES[density], className)} {...props}>
          {children}
        </table>
      </div>
    </DataTableContext.Provider>
  )
}

function Header({ className = "", ...props }: HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className={classes("bg-surface-subtle", className)} {...props} />
}

function Body({ className = "", ...props }: HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody className={classes("divide-y divide-border bg-surface", className)} {...props} />
}

function Row({ className = "", groupHeader = false, interactive = false, ...props }: DataTableRowProps) {
  return (
    <tr
      className={classes(
        "h-[var(--data-table-row-min-height)] transition-colors",
        groupHeader && "bg-surface-subtle",
        interactive && "cursor-pointer hover:bg-surface-raised focus-within:bg-surface-raised",
        className
      )}
      data-data-table-group-header={groupHeader ? "true" : undefined}
      data-data-table-interactive={interactive ? "true" : undefined}
      {...props}
    />
  )
}

function sortAffordance(sortDirection: DataTableSortDirection) {
  if (sortDirection === "ascending") return "^"
  if (sortDirection === "descending") return "v"
  return "-"
}

function HeadCell({
  align = "left",
  checkbox = false,
  children,
  className = "",
  onSort,
  scope = "col",
  sortDirection = "none",
  sortable = false,
  ...props
}: DataTableHeadCellProps) {
  const isSortable = sortable || Boolean(onSort)
  const sortableContent = (
    <span className={classes("inline-flex items-center gap-1.5", align === "right" && "justify-end", align === "center" && "justify-center")}>
      <span>{children}</span>
      {isSortable ? <span aria-hidden="true" className="text-text-subtle">{sortAffordance(sortDirection)}</span> : null}
    </span>
  )

  return (
    <th
      aria-sort={isSortable ? sortDirection : props["aria-sort"]}
      className={classes(
        "whitespace-nowrap px-4 py-[var(--data-table-cell-py)] text-xs font-medium uppercase tracking-wide text-text-muted",
        ALIGN_CLASSES[align],
        checkbox && "w-10 px-3",
        className
      )}
      scope={scope}
      {...props}
    >
      {onSort ? (
        <button className={classes("w-full text-xs font-medium uppercase tracking-wide text-text-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2", ALIGN_CLASSES[align])} onClick={onSort} type="button">
          {sortableContent}
        </button>
      ) : sortableContent}
    </th>
  )
}

function Cell({ align = "left", checkbox = false, className = "", ...props }: DataTableCellProps) {
  const { density } = useContext(DataTableContext)
  return (
    <td
      className={classes(
        "px-4 py-[var(--data-table-cell-py)] text-sm text-text-primary",
        density === "compact" && "text-xs",
        ALIGN_CLASSES[align],
        checkbox && "w-10 px-3",
        className
      )}
      {...props}
    />
  )
}

function Empty({ children, className = "", colSpan = 1, ...props }: DataTableEmptyProps) {
  return (
    <tr>
      <td className={classes("px-4 py-8 text-center text-sm text-text-muted", className)} colSpan={colSpan} {...props}>
        {children}
      </td>
    </tr>
  )
}

export const DataTable = {
  Root,
  Header,
  Body,
  Row,
  HeadCell,
  Cell,
  Empty
}
