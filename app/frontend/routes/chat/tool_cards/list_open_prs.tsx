import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState, StatePill } from "../toolCardUi"

// Core-owned tool card for list_open_prs (the Tier 1 tool-card work). Renders PR
// triage results as a dense table: title, number, refs, draft, and
// mergeability outcome.
type PrRow = {
  key: string
  number: string
  title: string
  headRef: string | null
  baseRef: string | null
  mergeable: boolean | null
  draft: boolean
}

function parseRow(value: unknown): PrRow | null {
  if (!isPlainObject(value)) return null
  const number = displayValue(value.number)
  if (!number) return null

  return {
    key: number,
    number,
    title: displayValue(value.title) || `PR #${number}`,
    headRef: displayValue(value.head_ref),
    baseRef: displayValue(value.base_ref),
    mergeable: typeof value.mergeable === "boolean" ? value.mergeable : null,
    draft: value.draft === true
  }
}

function prRows(context: ToolCardContext): PrRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.pull_requests)) return null

  return parsed.pull_requests.flatMap((pr) => {
    const row = parseRow(pr)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = prRows(context)
  if (!rows) return null
  return `${rows.length} pull request${rows.length === 1 ? "" : "s"}`
}

function MergeabilityBadge({ mergeable }: { mergeable: boolean | null }) {
  if (mergeable === null) return <StatePill state="checking" tone="neutral" />
  return mergeable ? <StatePill state="mergeable" tone="success" /> : <StatePill state="conflicts" tone="failure" />
}

function renderExpanded(context: ToolCardContext) {
  const rows = prRows(context)
  if (!rows) return null

  if (rows.length === 0) return <EmptyState>No pull requests found.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">
              PR
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Title
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Refs
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Draft
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Mergeability
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="whitespace-nowrap px-2 py-1 font-mono font-medium text-gray-900 dark:text-gray-100">#{row.number}</td>
              <td className="max-w-[16rem] truncate px-2 py-1 text-gray-800 dark:text-gray-200" title={row.title}>
                {row.title}
              </td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">
                {row.headRef || "?"} → {row.baseRef || "?"}
              </td>
              <td className="whitespace-nowrap px-2 py-1">{row.draft ? <Badge>draft</Badge> : "—"}</td>
              <td className="whitespace-nowrap px-2 py-1">
                <MergeabilityBadge mergeable={row.mergeable} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listOpenPrsToolCard: ToolCardRenderer = {
  toolName: "list_open_prs",
  collapsedSummary,
  renderExpanded
}

export default listOpenPrsToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "mixed_mergeability",
    label: "Mixed mergeability and draft state",
    parsedResult: {
      pull_requests: [
        { number: 41, title: "Add dark mode toggle to the settings page", head_ref: "syrus/issue-71", base_ref: "main", mergeable: true, draft: false },
        { number: 38, title: "WIP: rework pagination heuristics", head_ref: "syrus/issue-64", base_ref: "main", mergeable: null, draft: true },
        { number: 22, title: "Fix flaky sidebar collapse test", head_ref: "syrus/issue-58", base_ref: "main", mergeable: false, draft: false }
      ]
    }
  },
  {
    id: "no_open_prs",
    label: "No open pull requests",
    description: "Empty result set -- the card renders EmptyState instead of a bare table header.",
    parsedResult: { pull_requests: [] }
  }
]
