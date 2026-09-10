import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { TagActionCard, tagAction, tagActionSummary } from "../utilityToolCards"

function renderExpanded(context: ToolCardContext) {
  const outcome = tagAction(context, "remove")
  if (!outcome) return null
  return <TagActionCard outcome={outcome} />
}

const removeJobTagToolCard: ToolCardRenderer = {
  toolName: "remove_job_tag",
  collapsedSummary: (context) => tagActionSummary(context, "remove"),
  renderExpanded
}

export default removeJobTagToolCard
