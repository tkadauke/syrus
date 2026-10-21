import type { ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { decisionSummary, InsightDecisionOutcomeCard } from "../insightDecisionToolCard"

const card: ToolCardRenderer = {
  toolName: "dismiss_insight",
  collapsedSummary: (context) => decisionSummary(context, "dismiss"),
  renderExpanded: (context) => <InsightDecisionOutcomeCard action="dismiss" context={context} />
}
export default card

export const examples: ToolCardExample[] = [
  {
    id: "single_dismissed",
    label: "Single insight dismissed",
    input: { insight_id: 41, reason: "Duplicate of **INSIGHT-39**. See https://example.test/evidence." },
    parsedResult: { message: "Dismissed insight #41.", insight_ids: [41], states: { 41: "dismissed" } }
  },
  {
    id: "bulk_pending",
    label: "Bulk dismissal pending",
    input: { insight_ids: [41, 42], reason: "Both findings are stale." },
    parsedResult: {
      pending_action_id: 701,
      state: "pending",
      message: "Dismiss insights #41, #42?",
      insight_ids: [41, 42],
      intended_transition: "dismiss_insights"
    }
  },
  {
    id: "dismiss_error",
    label: "Dismissal error",
    input: { insight_id: 41, reason: "No longer relevant." },
    parsedResult: { error: "Insight #41 is no longer pending." },
    resultError: true
  }
]
