import i18n from "i18next"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { InsightDetailBody, InsightErrorCard, insightFromSubmitInput, parseOutcome } from "../agentInsightToolCard"

function errorMessage(context: ToolCardContext) {
  return context.resultBody.trim() || i18n.t("agent_insights:tool_submit_error")
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return i18n.t("agent_insights:tool_submit_failed")
  const outcome = parseOutcome(context)
  if (!outcome) return context.input?.title ? i18n.t("agent_insights:tool_submit_pending") : null

  return outcome.id ? i18n.t("agent_insights:tool_submit_summary_with_id", { id: outcome.id }) : i18n.t("agent_insights:tool_submit_summary")
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={errorMessage(context)} />
  const outcome = parseOutcome(context)
  const insight = insightFromSubmitInput(context, outcome?.id ?? null)
  if (!insight) return null

  return <InsightDetailBody insight={insight} resultMessage={outcome?.message ?? i18n.t("agent_insights:tool_submit_pending")} />
}

const submitInsightToolCard: ToolCardRenderer = {
  toolName: "submit_insight",
  collapsedSummary,
  renderExpanded
}

export default submitInsightToolCard

export const examples: ToolCardExample[] = [
  {
    id: "saved_insight",
    label: "Saved insight with all fields",
    input: {
      title: "Repeated grader timeout",
      category: "repeated_failure",
      severity: "high",
      confidence: 0.91,
      proposal_type: "create_job",
      evidence: [{ job_id: 42, workflow_id: 18, run_id: 77, kind: "run_transcript" }],
      suggested_prompt: "Fix **JOB-42** using the evidence in https://example.test/run.",
      memory_suggestion: "Remember to verify `command_spans` before changing timeouts.",
      target_memory_id: 12
    },
    resultBody: "Suggestion #301 saved."
  },
  {
    id: "pending",
    label: "Pending submission",
    input: { title: "Pending insight", category: "configuration", severity: "medium", confidence: 0.7 }
  },
  { id: "empty", label: "Empty submission", resultBody: "" },
  { id: "error", label: "Failed submission", resultBody: "Unable to save insight.", resultError: true }
]
