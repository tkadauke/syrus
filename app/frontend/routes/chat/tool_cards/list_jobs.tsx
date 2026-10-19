import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState } from "../toolCardUi"
import { JobsTable, jobResult, parseJobRow, resultErrorMessage, type JobRow } from "../jobsTableCard"

// Core-owned tool card for list_jobs (the Tier 1 tool-card work). Renders results
// as a dense table optimized for scanning.
function jobRows(context: ToolCardContext): JobRow[] | null {
  const parsed = jobResult(context, "jobs")
  if (!parsed) return null

  return parsed.items.flatMap((job) => {
    const row = parseJobRow(job)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = jobRows(context)
  if (!rows) return null
  return `${rows.length} Job${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const error = resultErrorMessage(context)
  if (error) return <EmptyState>{error}</EmptyState>
  const rows = jobRows(context)
  if (!rows) return null
  const state = typeof context.input?.state === "string" ? context.input.state : "open"
  const label = typeof context.input?.label === "string" ? context.input.label : null
  const limit = typeof context.input?.limit === "number" ? context.input.limit : 20
  return (
    <div>
      <div className="mb-1 text-xs text-text-muted">
        Showing {rows.length}, limit {limit} · State: {state}
        {label ? ` · Label: ${label}` : ""}
      </div>
      <JobsTable emptyMessage="No Jobs found." rows={rows} />
    </div>
  )
}

const listJobsToolCard: ToolCardRenderer = {
  toolName: "list_jobs",
  collapsedSummary,
  renderExpanded
}

export default listJobsToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "two_open_jobs",
    label: "Two open Jobs",
    input: { state: "open" },
    parsedResult: {
      jobs: [
        {
          id: 101,
          repository_slug: "acme/widgets",
          kind: "issue",
          issue_number: 18,
          branch_name: "syrus/fix-flake",
          issue_title: "Fix flaky test",
          state: "running",
          agent_provider: "codex",
          priority: "high",
          created_at: "2026-10-18T10:00:00Z",
          updated_at: "2026-10-19T10:00:00Z"
        },
        { id: 102, repository_slug: "acme/widgets", kind: "direct", issue_title: "Add dark mode toggle", state: "approved", pr_number: 21, priority: "medium" }
      ]
    }
  },
  {
    id: "tool_error",
    label: "Tool error",
    input: { state: "open" },
    resultBody: "Error: repository access unavailable",
    resultError: true
  },
  {
    id: "no_matching_jobs",
    label: "No matching Jobs",
    description: "Empty result set -- the card renders its own empty-state row instead of a bare table header.",
    input: { state: "open", user: "nobody" },
    parsedResult: { jobs: [] }
  },
  {
    id: "malformed_missing_jobs_key",
    label: "Malformed: missing jobs key",
    description: "Unexpected payload shape (no `jobs` array) -- renderExpanded/collapsedSummary both return null so the generic fallback body renders instead.",
    input: { state: "open" },
    parsedResult: { error: "unexpected upstream response" }
  }
]
