import type { ToolCardRenderer } from "@app/pluginToolCards"
import { decisionSummary, InsightDecisionOutcomeCard } from "../insightDecisionToolCard"

const card: ToolCardRenderer = {
  toolName: "accept_insight",
  collapsedSummary: (context) => decisionSummary(context, "accept"),
  renderExpanded: (context) => <InsightDecisionOutcomeCard action="accept" context={context} />
}
export default card
