import { useMemo, useState, type ReactNode } from "react"
import { formatCurrency } from "../../lib/format"
import { formatDuration } from "../jobDetail/formatting"

// Shared presentation primitives for the Workflow/Run/PR/diff/ops tool cards
// (the Tier 1 tool-card work). Lives outside `tool_cards/` on purpose: the
// pluginToolCards.tsx directory glob treats every non-test .tsx file under
// `tool_cards/` as a card module and would warn about a missing default
// export (see jobsTableCard.tsx for the established precedent).
export function displayValue(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "string" && value.trim()) return value.trim()
  return null
}

export function numberValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value)
  return null
}

export function decimalCost(value: unknown): string | null {
  const amount = numberValue(value)
  if (amount == null) return null
  return formatCurrency(amount)
}

export function durationLabel(startedAt: unknown, finishedAt: unknown): string | null {
  const started = displayValue(startedAt)
  const finished = displayValue(finishedAt)
  if (!started || !finished) return null
  const label = formatDuration(started, finished)
  return label === "-" ? null : label
}

type Tone = "success" | "failure" | "warning" | "info" | "neutral"

const TONE_CLASSES: Record<Tone, string> = {
  success: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-200",
  failure: "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-200",
  warning: "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200",
  info: "bg-info/10 text-info",
  neutral: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"
}

export function stateTone(state: string | null | undefined): Tone {
  const normalized = (state || "").toLowerCase()
  if (["succeeded", "success", "approved", "merged", "current", "repaired", "confirmed", "fired"].includes(normalized)) return "success"
  if (["failed", "failure", "error", "alarm", "cancelled", "canceled", "no_effective_ci_repair", "rejected", "withdrawn"].includes(normalized)) return "failure"
  if (["blocked", "paused", "auto_paused", "stale", "operator_action_required", "auto_repairable", "waiting"].includes(normalized)) return "warning"
  if (["running", "queued", "pending", "landing", "proposed", "confirming", "scheduled"].includes(normalized)) return "info"
  return "neutral"
}

export function StatePill({ state, tone }: { state: string; tone?: Tone }) {
  const resolvedTone = tone ?? stateTone(state)
  return (
    <span className={`rounded-full px-2 py-0.5 text-2xs font-semibold uppercase ${TONE_CLASSES[resolvedTone]}`}>
      {state.replace(/_/g, " ")}
    </span>
  )
}

export function Badge({ children }: { children: ReactNode }) {
  return <span className="rounded-full bg-gray-100 px-2 py-0.5 text-2xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{children}</span>
}

export function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="truncate font-mono text-gray-700 dark:text-gray-300" title={value}>{value}</dd>
    </div>
  )
}

export function SectionLabel({ children }: { children: ReactNode }) {
  return <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{children}</div>
}

export function CardShell({ children }: { children: ReactNode }) {
  return <div className="mt-1 space-y-2 rounded border border-gray-200 bg-gray-50 p-3 text-xs dark:border-gray-700 dark:bg-gray-900">{children}</div>
}

export function EmptyState({ children }: { children: ReactNode }) {
  return (
    <div className="mt-1 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
      {children}
    </div>
  )
}

export function InternalLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a className="font-mono font-medium text-brand hover:underline dark:text-brand-emphasis" href={href}>
      {children}
    </a>
  )
}

// Collapsed-by-default detail section for content a card should not dump
// into the main body by default (file contents, command output, long
// lists) — the raw JSON "Raw details" disclosure always covers the full
// payload regardless, so this is purely a friendlier, still-opt-in view.
export function Disclosure({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">{label}</summary>
      <div className="mt-1 text-gray-700 dark:text-gray-300">{children}</div>
    </details>
  )
}

export type LinePreview = { preview: string; truncated: boolean; totalLines: number }

export function truncateLines(text: string, maxLines: number): LinePreview {
  const lines = text.split("\n")
  if (lines.length <= maxLines) return { preview: text, truncated: false, totalLines: lines.length }
  return { preview: lines.slice(0, maxLines).join("\n"), truncated: true, totalLines: lines.length }
}

function includesQuery(text: string, query: string) {
  return text.toLowerCase().includes(query.trim().toLowerCase())
}

function SearchInput({ value, onChange, placeholder }: { value: string; onChange: (value: string) => void; placeholder: string }) {
  return (
    <input
      aria-label={placeholder}
      className="w-full rounded border border-gray-200 bg-white px-2 py-1 text-xs text-gray-800 shadow-sm outline-none focus:border-brand focus:ring-1 focus:ring-brand dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
      onChange={(event) => onChange(event.currentTarget.value)}
      placeholder={placeholder}
      type="search"
      value={value}
    />
  )
}

export function LargeResultList<T>({
  emptyLabel = "No results.",
  filteredEmptyLabel = "No results match the filter.",
  filterPlaceholder,
  initialLimit = 10,
  itemText,
  items,
  label,
  renderItem
}: {
  emptyLabel?: string
  filteredEmptyLabel?: string
  filterPlaceholder?: string
  initialLimit?: number
  itemText: (item: T) => string
  items: T[]
  label: string
  renderItem: (item: T, index: number) => ReactNode
}) {
  const [query, setQuery] = useState("")
  const [expanded, setExpanded] = useState(false)
  const normalizedLimit = Math.max(1, initialLimit)
  const filterable = items.length > normalizedLimit
  const filteredItems = useMemo(
    () => query.trim() ? items.filter((item) => includesQuery(itemText(item), query)) : items,
    [itemText, items, query]
  )
  const visibleItems = expanded ? filteredItems : filteredItems.slice(0, normalizedLimit)
  const hiddenCount = filteredItems.length - visibleItems.length

  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <SectionLabel>{label}</SectionLabel>
        <span className="text-2xs text-gray-500 dark:text-gray-400">
          Showing {visibleItems.length} of {filteredItems.length}{filteredItems.length !== items.length ? ` matching ${items.length}` : ""}.
        </span>
      </div>
      {filterable ? <SearchInput placeholder={filterPlaceholder ?? `Filter ${label.toLowerCase()}`} value={query} onChange={setQuery} /> : null}
      {items.length === 0 ? (
        <EmptyState>{emptyLabel}</EmptyState>
      ) : filteredItems.length === 0 ? (
        <EmptyState>{filteredEmptyLabel}</EmptyState>
      ) : (
        <>
          {visibleItems.map((item, index) => renderItem(item, index))}
          {hiddenCount > 0 || expanded ? (
            <button
              className="text-2xs font-medium text-brand hover:underline dark:text-brand-emphasis"
              onClick={() => setExpanded((current) => !current)}
              type="button"
            >
              {expanded ? "Show fewer" : `Show ${hiddenCount} more`}
            </button>
          ) : null}
        </>
      )}
    </div>
  )
}

export function LargeResultTable<T>({
  columns,
  emptyLabel = "No rows returned.",
  filterPlaceholder,
  initialLimit = 25,
  rowKey,
  rowText,
  rows,
  renderCell
}: {
  columns: string[]
  emptyLabel?: string
  filterPlaceholder?: string
  initialLimit?: number
  rowKey?: (row: T, index: number) => string
  rowText: (row: T) => string
  rows: T[]
  renderCell: (row: T, column: string) => ReactNode
}) {
  const [query, setQuery] = useState("")
  const [expanded, setExpanded] = useState(false)
  const normalizedLimit = Math.max(1, initialLimit)
  const filteredRows = useMemo(
    () => query.trim() ? rows.filter((row) => includesQuery(rowText(row), query)) : rows,
    [rowText, rows, query]
  )
  const visibleRows = expanded ? filteredRows : filteredRows.slice(0, normalizedLimit)
  const hiddenCount = filteredRows.length - visibleRows.length

  if (rows.length === 0) return <EmptyState>{emptyLabel}</EmptyState>

  return (
    <div className="space-y-2">
      {rows.length > normalizedLimit ? <SearchInput placeholder={filterPlaceholder ?? "Filter rows"} value={query} onChange={setQuery} /> : null}
      {filteredRows.length === 0 ? (
        <EmptyState>No rows match the filter.</EmptyState>
      ) : (
        <>
          <div className="overflow-auto rounded border border-gray-200 dark:border-gray-800">
            <table className="w-full text-left text-xs">
              <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
                <tr>
                  {columns.map((column) => (
                    <th className="whitespace-nowrap px-2 py-1 font-semibold" key={column} scope="col">{column}</th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
                {visibleRows.map((row, index) => (
                  <tr key={rowKey ? rowKey(row, index) : index}>
                    {columns.map((column) => (
                      <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-700 dark:text-gray-300" key={column}>{renderCell(row, column)}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="flex flex-wrap items-center gap-2 text-2xs text-gray-500 dark:text-gray-400">
            <span>Showing {visibleRows.length} of {filteredRows.length}{filteredRows.length !== rows.length ? ` matching ${rows.length}` : ""} rows.</span>
            {hiddenCount > 0 || expanded ? (
              <button
                className="font-medium text-brand hover:underline dark:text-brand-emphasis"
                onClick={() => setExpanded((current) => !current)}
                type="button"
              >
                {expanded ? "Show fewer" : `Show ${hiddenCount} more`}
              </button>
            ) : null}
          </div>
        </>
      )}
    </div>
  )
}

export function FilterableLinePreview({
  emptyLabel = "No lines returned.",
  initialLimit = 40,
  label,
  lines
}: {
  emptyLabel?: string
  initialLimit?: number
  label: string
  lines: string[]
}) {
  const [query, setQuery] = useState("")
  const [expanded, setExpanded] = useState(false)
  const normalizedLimit = Math.max(1, initialLimit)
  const filteredLines = useMemo(
    () => query.trim() ? lines.filter((line) => includesQuery(line, query)) : lines,
    [lines, query]
  )
  const visibleLines = expanded ? filteredLines : filteredLines.slice(0, normalizedLimit)
  const hiddenCount = filteredLines.length - visibleLines.length

  return (
    <Disclosure label={label}>
      <div className="space-y-2">
        {lines.length > normalizedLimit ? <SearchInput placeholder={`Filter ${label.toLowerCase()}`} value={query} onChange={setQuery} /> : null}
        {lines.length === 0 ? (
          <EmptyState>{emptyLabel}</EmptyState>
        ) : filteredLines.length === 0 ? (
          <EmptyState>No lines match the filter.</EmptyState>
        ) : (
          <>
            <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{visibleLines.join("\n")}</pre>
            <div className="flex flex-wrap items-center gap-2 text-2xs text-gray-500 dark:text-gray-400">
              <span>Showing {visibleLines.length} of {filteredLines.length}{filteredLines.length !== lines.length ? ` matching ${lines.length}` : ""} lines.</span>
              {hiddenCount > 0 || expanded ? (
                <button
                  className="font-medium text-brand hover:underline dark:text-brand-emphasis"
                  onClick={() => setExpanded((current) => !current)}
                  type="button"
                >
                  {expanded ? "Show fewer" : `Show ${hiddenCount} more`}
                </button>
              ) : null}
            </div>
          </>
        )}
      </div>
    </Disclosure>
  )
}

export function JsonDisclosure({ label, value, maxLines = 80 }: { label: string; value: unknown; maxLines?: number }) {
  let json = ""
  try {
    json = JSON.stringify(value, null, 2)
  } catch {
    json = String(value)
  }
  const lines = json.split("\n")
  return <FilterableLinePreview label={label} lines={lines} initialLimit={maxLines} emptyLabel="No details returned." />
}
