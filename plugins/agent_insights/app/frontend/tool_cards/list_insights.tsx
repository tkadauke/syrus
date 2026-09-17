import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { insightListSummary, insightRows, InsightListBody } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  return insightListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const rows = insightRows(context)
  if (!rows) return null

  return <InsightListBody rows={rows} />
}

const listInsightsToolCard: ToolCardRenderer = {
  toolName: "list_insights",
  collapsedSummary,
  renderExpanded
}

export default listInsightsToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "pending_and_accepted_insights",
    label: "One pending, one accepted insight",
    input: { state: "all" },
    parsedResult: {
      insights: [
        {
          id: "204",
          title: "LandingQueueProcessor re-fetches PR mergeability on every poll tick",
          summary: "Repeated GitHub API calls for PRs whose mergeability hasn't changed since the last poll.",
          category: "inefficiency",
          severity: "medium",
          confidence: 0.72,
          state: "pending",
          proposal_type: "create_job",
          evidence: [{ job_id: "71", run_id: "201", kind: "run_transcript" }],
          repository: { id: "42", slug: "tkadauke/syrus" },
          created_at: "2026-09-15T08:00:00Z"
        },
        {
          id: "198",
          title: "Grader retry loop repair prompt omits the failing grader's name",
          category: "repeated_failure",
          severity: "low",
          confidence: 0.55,
          state: "accepted",
          proposal_type: "informational",
          evidence: [],
          job: { id: "68" },
          created_at: "2026-09-10T11:30:00Z"
        }
      ]
    }
  },
  {
    id: "no_pending_insights",
    label: "No pending insights",
    description: "Empty result set -- exercises InsightListBody's own empty state.",
    input: { state: "pending" },
    parsedResult: { insights: [] }
  }
]
