import type { ReactNode } from "react"
import { formatCurrency } from "../../lib/format"
import { formatDuration } from "../jobDetail/formatting"

// Shared presentation primitives for the Workflow/Run/PR/diff/ops tool cards
// (EPIC-291 / JOB-4221). Lives outside `tool_cards/` on purpose: the
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
