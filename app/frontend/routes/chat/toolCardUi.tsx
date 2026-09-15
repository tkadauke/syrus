import { useMemo, useState, type ReactNode } from "react"
import { CodeSurface, Input, Pill, Surface, Text, ToolCard } from "../../components/ui"
import type { SemanticTone } from "../../components/ui"
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

const TONE_TO_SEMANTIC_TONE: Record<Tone, SemanticTone> = {
  success: "success",
  failure: "danger",
  warning: "warning",
  info: "info",
  neutral: "neutral"
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
  return <Pill className="text-2xs font-semibold uppercase" tone={TONE_TO_SEMANTIC_TONE[resolvedTone]}>{state.replace(/_/g, " ")}</Pill>
}

export function Badge({ children }: { children: ReactNode }) {
  return <Pill className="text-2xs" tone="neutral">{children}</Pill>
}

export function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <Text as="div" variant="label" tone="muted">{label}</Text>
      <Text as="div" className="truncate font-mono text-xs" title={value}>{value}</Text>
    </div>
  )
}

export function SectionLabel({ children }: { children: ReactNode }) {
  return <Text as="div" variant="label" tone="muted">{children}</Text>
}

export function CardShell({ children }: { children: ReactNode }) {
  return <ToolCard.Root className="mt-1 space-y-2">{children}</ToolCard.Root>
}

export function EmptyState({ children }: { children: ReactNode }) {
  return (
    <Surface className="mt-1" padding="sm" variant="inset">
      <Text as="div" variant="caption" tone="muted">{children}</Text>
    </Surface>
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
    <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">{label}</summary>
      <div className="mt-1 text-text-primary">{children}</div>
    </details>
  )
}

export type LinePreview = { preview: string; truncated: boolean; totalLines: number }

export function truncateLines(text: string, maxLines: number): LinePreview {
  const lines = text.split("\n")
  if (lines.length <= maxLines) return { preview: text, truncated: false, totalLines: lines.length }
  return { preview: lines.slice(0, maxLines).join("\n"), truncated: true, totalLines: lines.length }
}

export function LargeTextPreview({ emptyLabel = "No text returned.", label, maxLines = 40, text }: { emptyLabel?: string; label: string; maxLines?: number; text: string | null }) {
  return (
    <Disclosure label={label}>
      <PreviewTextBlock emptyLabel={emptyLabel} maxLines={maxLines} text={text} />
    </Disclosure>
  )
}

export function PreviewTextBlock({ emptyLabel = "No text returned.", maxLines = 40, text }: { emptyLabel?: string; maxLines?: number; text: string | null }) {
  if (!text?.trim()) return <EmptyState>{emptyLabel}</EmptyState>

  const { preview, truncated, totalLines } = truncateLines(text, maxLines)

  return (
    <>
      <CodeSurface code={preview} maxHeightClassName="max-h-72" />
      {truncated ? <Text as="div" className="mt-1" variant="caption" tone="muted">Showing first {maxLines} of {totalLines} lines.</Text> : null}
    </>
  )
}

export function FilterableList<T,>({ children, emptyLabel = "No matching rows.", itemText, items, placeholder = "Filter results" }: { children: (items: T[]) => ReactNode; emptyLabel?: string; itemText: (item: T) => string; items: T[]; placeholder?: string }) {
  const [query, setQuery] = useState("")
  const normalizedQuery = query.trim().toLowerCase()
  const visibleItems = useMemo(() => {
    if (!normalizedQuery) return items
    return items.filter((item) => itemText(item).toLowerCase().includes(normalizedQuery))
  }, [itemText, items, normalizedQuery])

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          aria-label={placeholder}
          className="min-w-0 flex-1 px-2 py-1 text-xs dark:bg-gray-950"
          fullWidth={false}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={placeholder}
          type="search"
          value={query}
        />
        <Text as="span" variant="caption" tone="muted">{visibleItems.length} of {items.length}</Text>
      </div>
      {visibleItems.length > 0 ? children(visibleItems) : <EmptyState>{emptyLabel}</EmptyState>}
    </div>
  )
}
