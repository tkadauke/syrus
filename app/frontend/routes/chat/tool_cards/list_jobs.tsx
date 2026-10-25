import i18n from "@app/i18n"
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
  return i18n.t("chat:tool_card_list_jobs_summary", { count: rows.length })
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
        {i18n.t("chat:tool_card_list_jobs_filters", { count: rows.length, limit, state })}
        {label ? i18n.t("chat:tool_card_list_jobs_label_filter", { label }) : ""}
      </div>
      <JobsTable emptyMessage={i18n.t("chat:tool_card_list_jobs_empty")} rows={rows} />
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
    label: i18n.t("chat:tool_card_list_jobs_example_open"),
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
    label: i18n.t("chat:tool_card_example_error"),
    input: { state: "open" },
    resultBody: "Error: repository access unavailable",
    resultError: true
  },
  {
    id: "no_matching_jobs",
    label: i18n.t("chat:tool_card_list_jobs_example_empty"),
    description: i18n.t("chat:tool_card_list_jobs_example_empty_description"),
    input: { state: "open", user: "nobody" },
    parsedResult: { jobs: [] }
  },
  {
    id: "malformed_missing_jobs_key",
    label: i18n.t("chat:tool_card_list_jobs_example_malformed"),
    description: i18n.t("chat:tool_card_list_jobs_example_malformed_description"),
    input: { state: "open" },
    parsedResult: { error: "unexpected upstream response" }
  }
]
