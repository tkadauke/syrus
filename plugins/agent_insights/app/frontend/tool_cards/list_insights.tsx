import i18n from "i18next"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue } from "@app/routes/chat/toolCardUi"
import { insightRows, InsightErrorCard, InsightListBody } from "../agentInsightToolCard"

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_insights:${key}`, options)
}

function filters(context: ToolCardContext) {
  const input = context.input ?? {}
  return [
    displayValue(input.state) ? t("tool_filter_state", { value: displayValue(input.state) }) : null,
    displayValue(input.repository_id) ? t("tool_filter_repository", { value: displayValue(input.repository_id) }) : null,
    displayValue(input.limit) ? t("tool_filter_limit", { value: displayValue(input.limit) }) : null,
    displayValue(input.page) ? t("tool_filter_page", { value: displayValue(input.page) }) : null
  ].filter((value): value is string => Boolean(value))
}

function errorMessage(context: ToolCardContext) {
  if (typeof context.resultBody === "string" && context.resultBody.trim()) return context.resultBody.trim()
  return t("tool_list_error")
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return t("tool_list_failed")
  const rows = insightRows(context)
  return rows ? t(rows.length === 1 ? "insight_count" : "insight_count_plural", { count: rows.length }) : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={errorMessage(context)} />
  const rows = insightRows(context)
  if (!rows) return null
  const appliedFilters = filters(context)

  return (
    <CardShell>
      {appliedFilters.length ? (
        <div aria-label={t("tool_filters")} className="flex min-w-0 flex-wrap gap-1">
          {appliedFilters.map((filter) => (
            <Badge key={filter}>{filter}</Badge>
          ))}
        </div>
      ) : null}
      {rows.length === 0 && appliedFilters.length ? (
        <div className="text-xs text-text-muted">{t("tool_empty_filters", { filters: appliedFilters.join(", ") })}</div>
      ) : null}
      <InsightListBody rows={rows} />
    </CardShell>
  )
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
    id: "codex_content_envelope",
    label: "Codex content envelope",
    sourceType: "codex" as const,
    input: { repository_id: 42, state: "accepted", limit: 10, page: 2 },
    parsedResult: {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            insights: [
              {
                id: "301",
                title: "Markdown summary",
                summary: "See **JOB-42** and https://example.test/details",
                state: "accepted",
                repository: { id: "42", slug: "tkadauke/syrus" }
              }
            ]
          })
        }
      ]
    }
  },
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
    description: "Empty result set with an applied filter.",
    input: { state: "pending" },
    parsedResult: { insights: [] }
  },
  { id: "error", label: "Failed insight lookup", resultBody: "Repository is not accessible.", resultError: true }
]
