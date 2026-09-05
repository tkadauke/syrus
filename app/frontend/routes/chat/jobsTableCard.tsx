import { isPlainObject } from "@app/pluginToolCards"

// Shared dense-table rendering for the list_jobs and search_jobs tool cards
// (EPIC-291 / JOB-4220) — both tools return arrays of similarly-shaped Job
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
    return (
      <div className="mt-1 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
        {emptyMessage}
      </div>
    )
  }

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Job</th>
            <th className="px-2 py-1 font-semibold" scope="col">Title</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Repository</th>
            <th className="px-2 py-1 font-semibold" scope="col">PR</th>
            <th className="px-2 py-1 font-semibold" scope="col">Priority</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="whitespace-nowrap px-2 py-1 font-mono font-medium text-gray-900 dark:text-gray-100">{row.jobId}</td>
              <td className="max-w-[16rem] truncate px-2 py-1 text-gray-800 dark:text-gray-200" title={row.title}>{row.title}</td>
              <td className="whitespace-nowrap px-2 py-1 capitalize text-gray-600 dark:text-gray-300">{row.state.replace(/_/g, " ")}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.repositorySlug || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.prNumber ? `#${row.prNumber}` : "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 capitalize text-gray-600 dark:text-gray-300">{row.priority || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
