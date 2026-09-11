import type { ReactNode } from "react"
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

// Shared across admin_overview and admin_version, which both echo a
// `worker_health.current` array (Admin::WorkerHealthPayload#as_json) but
// only need the aggregate red/yellow/green rollup, not the full per-host
// history read_worker_health renders.
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

export function Table({ children }: { children: ReactNode }) {
  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">{children}</table>
    </div>
  )
}

export function THead({ columns }: { columns: string[] }) {
  return (
    <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
      <tr>
        {columns.map((column) => (
          <th className="px-2 py-1 font-semibold" key={column} scope="col">
            {column}
          </th>
        ))}
      </tr>
    </thead>
  )
}

export function TBody({ children }: { children: ReactNode }) {
  return <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">{children}</tbody>
}

export function Td({ children, mono = false, title, maxWidth }: { children: ReactNode; mono?: boolean; title?: string; maxWidth?: boolean }) {
  return (
    <td
      className={`px-2 py-1 text-gray-700 dark:text-gray-300 ${maxWidth ? "max-w-[16rem] truncate" : "whitespace-nowrap"} ${mono ? "font-mono" : ""}`}
      title={title}
    >
      {children}
    </td>
  )
}
