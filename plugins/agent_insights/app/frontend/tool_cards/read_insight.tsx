import i18n from "i18next"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState } from "@app/routes/chat/toolCardUi"
import { InsightDetailBody, InsightErrorCard, parseInsightDetail } from "../agentInsightToolCard"

function t(key: string) {
  return i18n.t(`agent_insights:${key}`)
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return t("tool_read_failed")
  const insight = parseInsightDetail(context)
  if (!insight) return null

  return `${insight.title} (${insight.state ?? t("tool_unknown")})`
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={context.resultBody.trim() || t("tool_read_error")} />
  const insight = parseInsightDetail(context)
  if (!insight && !context.resultBody.trim()) return <EmptyState>{t("tool_read_empty")}</EmptyState>
  if (!insight) return null

  return <InsightDetailBody insight={insight} />
}

const readInsightToolCard: ToolCardRenderer = {
  toolName: "read_insight",
  collapsedSummary,
  renderExpanded
}

export default readInsightToolCard

export const examples: ToolCardExample[] = [
  {
    id: "complete_insight",
    label: "Complete insight",
    parsedResult: {
      insight: {
        id: 41,
        title: "Prepare failures cluster",
        summary: "Several **prepare failures** point to [the same fix](https://example.test/fix).",
        category: "repeated_failure",
        severity: "high",
        confidence: 0.92,
        state: "retired",
        proposal_type: "remove_memory",
        evidence: [{ job_id: 200, run_id: 99, kind: "run_transcript", job_path: "/jobs/200", run_transcript_path: "/admin/runs/99/transcript" }],
        suggested_prompt: "Inspect **JOB-200** and RUN-99.",
        memory_suggestion: "Preserve the durable lesson.",
        target_memory_id: 17,
        stale_memory_text: "The old guidance is now **stale**.",
        stale_memory_evidence: "Superseded by RUN-99.",
        target_insight_id: 40,
        retired_reason: "Replaced by a more specific finding.",
        superseded_by_insight_id: 42,
        superseded_by_job_id: 201,
        repository: { id: 3, slug: "acme/widgets" },
        job: { id: 200, title: "Insight analysis", path: "/jobs/200" },
        source_workflow: { id: 12, path: "/jobs/200?tab=workflows#workflow-12" },
        source_run: { id: 99, path: "/admin/runs/99/transcript" },
        created_at: "2026-09-09T10:00:00Z",
        updated_at: "2026-09-09T11:00:00Z",
        retired_at: "2026-09-10T09:00:00Z"
      }
    }
  },
  { id: "empty", label: "Empty result", resultBody: "" },
  { id: "not_found", label: "Insight not found", resultBody: "Error: insight not found or not accessible: 41", resultError: true }
]
