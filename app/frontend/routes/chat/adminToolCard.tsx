import { Children, cloneElement, createContext, isValidElement, useContext } from "react"
import type { ReactNode } from "react"
import { DataTable } from "../../components/ui"
import { displayValue, InternalLink, StatePill } from "./toolCardUi"

// Shared presentation helpers for the core admin status/diagnostics/
// provider-circuit chat tool cards (the tool-card work): admin_overview,
// admin_queue_detail, admin_list_processes, admin_list_runs,
// admin_list_users, admin_version, read_worker_health,
// admin_read_operational_logs, admin_github_app_installation_diagnostic,
// and inspect_provider_circuit all render dense ops tables and
// red/yellow/green health state, so this module holds the pieces they
// share once instead of each card hand-rolling its own.
//
// Lives outside `tool_cards/` on purpose -- see mysqlToolCard.tsx /
// memoryToolCard.tsx for the established precedent: core's
// pluginToolCards.tsx glob treats every non-test .tsx file under
// `tool_cards/` as a card module and would warn about the missing default
// export. Deliberately does not import from "@app/pluginToolCards" (unlike
// the tool_cards/*.tsx files it supports) so that eager glob's import graph
// never routes back through this module -- own isRecord check instead of
// the shared isPlainObject.
function isRecord(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

export type HealthLevel = "ok" | "warning" | "critical" | "unknown"

const HEALTH_TONE: Record<HealthLevel, "success" | "warning" | "failure" | "neutral"> = {
  ok: "success",
  warning: "warning",
  critical: "failure",
  unknown: "neutral"
}

export function parseHealthLevel(value: unknown): HealthLevel {
  const level = displayValue(value)?.toLowerCase()
  return level === "ok" || level === "warning" || level === "critical" ? level : "unknown"
}

export function HealthPill({ level }: { level: HealthLevel }) {
  return <StatePill state={level} tone={HEALTH_TONE[level]} />
}

const BYTE_UNITS = ["B", "KB", "MB", "GB", "TB"]

// AdminOverview.tsx keeps its own page-local variant of this; this one is
// for the compact chat-card context and isn't worth sharing across the
// SPA/chat boundary for a one-line formatter.
export function formatBytesLarge(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return "—"

  let amount = value
  let unitIndex = 0
  while (amount >= 1024 && unitIndex < BYTE_UNITS.length - 1) {
    amount /= 1024
    unitIndex += 1
  }

  return `${amount.toFixed(unitIndex === 0 ? 0 : 1)} ${BYTE_UNITS[unitIndex]}`
}

export function formatPercent(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return "—"
  return `${value.toFixed(1)}%`
}

export type WorkerHealthCounts = { total: number; worst: HealthLevel; byLevel: Record<HealthLevel, number> }

const HEALTH_RANK: Record<HealthLevel, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 }

// Shared by compact cards that need an aggregate red/yellow/green rollup from
// Admin::WorkerHealthPayload#as_json without rendering the full per-host
// history read_worker_health shows.
export function parseWorkerHealthCounts(value: unknown): WorkerHealthCounts | null {
  if (!isRecord(value) || !Array.isArray(value.current)) return null

  const byLevel: Record<HealthLevel, number> = { ok: 0, warning: 0, critical: 0, unknown: 0 }
  let worst: HealthLevel = "ok"

  for (const worker of value.current) {
    if (!isRecord(worker)) continue
    const level = parseHealthLevel(isRecord(worker.health) ? worker.health.level : null)
    byLevel[level] += 1
    if (HEALTH_RANK[level] > HEALTH_RANK[worst]) worst = level
  }

  return { total: value.current.length, worst, byLevel }
}

export function JobRefLink({ jobId }: { jobId: number | string | null }) {
  if (jobId == null) return <>—</>
  return <InternalLink href={`/jobs/${jobId}`}>JOB-{jobId}</InternalLink>
}

type ResponsiveTableContextValue = {
  columns: string[]
  responsive: boolean
}

const ResponsiveTableContext = createContext<ResponsiveTableContextValue>({ columns: [], responsive: false })
const ResponsiveCellLabelContext = createContext<string | null>(null)

const RESPONSIVE_BODY_CLASSES = [
  "block divide-y-0 space-y-2 bg-transparent",
  "sm:table-row-group sm:divide-y sm:space-y-0 sm:bg-surface",
  "[&>tr]:block [&>tr]:h-auto [&>tr]:rounded-[var(--radius-panel)]",
  "[&>tr]:border [&>tr]:border-border [&>tr]:bg-surface [&>tr]:py-1",
  "sm:[&>tr]:table-row sm:[&>tr]:h-[var(--data-table-row-min-height)]",
  "sm:[&>tr]:rounded-none sm:[&>tr]:border-0 sm:[&>tr]:py-0"
].join(" ")

const RESPONSIVE_CELL_CLASSES = [
  "grid min-w-0 grid-cols-[minmax(5rem,0.4fr)_minmax(0,1fr)] items-start gap-3 px-3",
  "sm:table-cell sm:px-2",
  "[&_a]:inline-flex [&_a]:min-h-11 [&_a]:items-center sm:[&_a]:min-h-0"
].join(" ")

export function Table({ children, responsive = false }: { children: ReactNode; responsive?: boolean }) {
  const header = Children.toArray(children).find((child) => isValidElement<{ columns: string[] }>(child) && child.type === THead)
  const columns = isValidElement<{ columns: string[] }>(header) ? header.props.columns : []

  return (
    <ResponsiveTableContext.Provider value={{ columns, responsive }}>
      <DataTable.Root
        className={responsive ? "block text-xs sm:table" : "text-xs"}
        density="compact"
        wrapperClassName={responsive ? "mt-1 overflow-visible sm:overflow-x-auto" : "mt-1"}
      >
        {children}
      </DataTable.Root>
    </ResponsiveTableContext.Provider>
  )
}

export function THead({ columns }: { columns: string[] }) {
  const { responsive } = useContext(ResponsiveTableContext)
  return (
    <DataTable.Header className={responsive ? "hidden sm:table-header-group" : ""}>
      <DataTable.Row>
        {columns.map((column) => (
          <DataTable.HeadCell className="px-2 py-1 text-2xs" key={column}>
            {column}
          </DataTable.HeadCell>
        ))}
      </DataTable.Row>
    </DataTable.Header>
  )
}

export function TBody({ children }: { children: ReactNode }) {
  const { columns, responsive } = useContext(ResponsiveTableContext)
  if (!responsive) return <DataTable.Body>{children}</DataTable.Body>

  const labeledRows = Children.map(children, (row) => {
    if (!isValidElement<{ children?: ReactNode }>(row)) return row

    const cells = Children.toArray(row.props.children)
    if (cells.length !== columns.length) {
      throw new Error(`Responsive admin table row has ${cells.length} cells but ${columns.length} columns`)
    }
    if (cells.some((cell) => !isValidElement(cell) || cell.type !== Td)) {
      throw new Error("Responsive admin table rows must contain only Td cells")
    }

    return cloneElement(
      row,
      undefined,
      cells.map((cell, index) => (
        <ResponsiveCellLabelContext.Provider key={index} value={columns[index]}>
          {cell}
        </ResponsiveCellLabelContext.Provider>
      ))
    )
  })

  return <DataTable.Body className={RESPONSIVE_BODY_CLASSES}>{labeledRows}</DataTable.Body>
}

export function Td({
  children,
  maxWidth,
  mono = false,
  primary = false,
  title,
  wrap = false
}: {
  children: ReactNode
  maxWidth?: boolean
  mono?: boolean
  primary?: boolean
  title?: string
  wrap?: boolean
}) {
  const { responsive } = useContext(ResponsiveTableContext)
  const responsiveLabel = useContext(ResponsiveCellLabelContext)
  const widthClass = maxWidth
    ? wrap
      ? "max-w-[16rem] whitespace-normal break-words"
      : "max-w-[16rem] truncate"
    : wrap
      ? "whitespace-normal break-words"
      : "whitespace-nowrap"

  return (
    <DataTable.Cell
      className={`${widthClass} ${mono ? "font-mono" : ""} ${primary ? "font-semibold text-text-primary" : ""} ${responsive ? RESPONSIVE_CELL_CLASSES : "px-2"} py-1 text-xs`}
      data-label={responsiveLabel ?? undefined}
      title={title}
    >
      {responsiveLabel ? <span className="text-2xs font-medium uppercase tracking-wide text-text-muted sm:hidden">{responsiveLabel}</span> : null}
      {children}
    </DataTable.Cell>
  )
}
