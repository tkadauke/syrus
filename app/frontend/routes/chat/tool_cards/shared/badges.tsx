import { linkifySlugs } from "../../../../lib/linkifySlugs"
import { StatusPill, TonePill, type PillTone } from "../../../../components/StatusPill"

// Small presentational pieces shared by the core Job/Epic tool cards
// (read_job, list_jobs, search_jobs, read_epic, list_epics — EPIC-291 /
// JOB-4220). Kept out of `tool_cards/*.tsx` itself so the directory-glob
// discovery in pluginToolCards.tsx (which requires every top-level file in
// that directory to default-export a ToolCardRenderer) doesn't try to treat
// this file as a card.

// Same priority -> tone mapping as the dashboard Jobs table's
// PRIORITY_TONE (JobsTable.tsx), reproduced locally rather than imported so
// a tool card stays a light, self-contained module instead of pulling in
// an entire dashboard route.
const PRIORITY_TONE: Record<string, PillTone> = {
  urgent: "red",
  high: "amber",
  medium: "gray",
  low: "blue"
}

export function PriorityPill({ priority }: { priority: string }) {
  return <TonePill tone={PRIORITY_TONE[priority] ?? "gray"}>{priority}</TonePill>
}

export function JobBadge({ id, title, state }: { id: number; title?: string | null; state?: string | null }) {
  return (
    <span className="inline-flex max-w-full items-center gap-1.5 rounded-full border border-gray-200 bg-white px-2 py-0.5 text-xs dark:border-gray-700 dark:bg-gray-950">
      <span className="font-mono font-medium text-gray-700 dark:text-gray-300">{linkifySlugs(`JOB-${id}`)}</span>
      {state ? <StatusPill state={state} /> : null}
      {title ? <span className="min-w-0 truncate text-gray-600 dark:text-gray-400" title={title}>{title}</span> : null}
    </span>
  )
}

export function EpicBadge({ id, title, state }: { id: number; title?: string | null; state?: string | null }) {
  return (
    <span className="inline-flex max-w-full items-center gap-1.5 rounded-full border border-gray-200 bg-white px-2 py-0.5 text-xs dark:border-gray-700 dark:bg-gray-950">
      <span className="font-mono font-medium text-gray-700 dark:text-gray-300">{linkifySlugs(`EPIC-${id}`)}</span>
      {state ? <StatusPill state={state} /> : null}
      {title ? <span className="min-w-0 truncate text-gray-600 dark:text-gray-400" title={title}>{title}</span> : null}
    </span>
  )
}

export function PendingDependencyBadge({ label }: { label: string }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-full border border-dashed border-gray-300 bg-gray-50 px-2 py-0.5 text-xs text-gray-500 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-400">
      {label}
    </span>
  )
}
