import { isPlainObject } from "@app/pluginToolCards"
import { DataTable } from "../../components/ui"
import { EmptyState, StatePill } from "./toolCardUi"

// Shared dense-table rendering for the list_jobs and search_jobs tool cards
// (the Tier 1 tool-card work) — both tools return arrays of similarly-shaped Job
// summaries, so the table markup and row parsing live here instead of being
// duplicated across the two `tool_cards/*.tsx` files. This file intentionally
// does NOT live under `tool_cards/` itself: pluginToolCards.tsx's directory
// glob treats every non-test .tsx file there as a card module and would warn
// about a missing default export.
export type JobRow = {
  key: string
  jobId: string
  title: string
  state: string
  repositorySlug: string | null
  prNumber: string | null
  priority: string | null
}

function displayValue(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "string" && value.trim()) return value.trim()
  return null
}

export function parseJobRow(value: unknown): JobRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null

  return {
    key: id,
    jobId: `JOB-${id}`,
    title: displayValue(value.issue_title) || `JOB-${id}`,
    state,
    repositorySlug: displayValue(value.repository_slug),
    prNumber: displayValue(value.pr_number),
    priority: displayValue(value.priority)
  }
}

export function JobsTable({ rows, emptyMessage }: { rows: JobRow[]; emptyMessage: string }) {
  if (rows.length === 0) {
    return <EmptyState>{emptyMessage}</EmptyState>
  }

  return (
    <DataTable.Root className="text-xs" density="compact" wrapperClassName="mt-1">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Job</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Title</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">State</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Repository</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">PR</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Priority</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {rows.map((row) => (
          <DataTable.Row key={row.key}>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 font-mono font-medium text-xs">{row.jobId}</DataTable.Cell>
            <DataTable.Cell className="max-w-[16rem] truncate px-2 py-1 text-xs" title={row.title}>{row.title}</DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 text-xs"><StatePill state={row.state} /></DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 text-xs">{row.repositorySlug || "—"}</DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 text-xs">{row.prNumber ? `#${row.prNumber}` : "—"}</DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 text-xs capitalize">{row.priority || "—"}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}
