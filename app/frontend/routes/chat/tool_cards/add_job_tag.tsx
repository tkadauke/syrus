import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { TagActionCard, tagAction, tagActionSummary } from "../utilityToolCards"

function renderExpanded(context: ToolCardContext) {
  const outcome = tagAction(context, "add")
  if (!outcome) return null
  return <TagActionCard outcome={outcome} />
}

const addJobTagToolCard: ToolCardRenderer = {
  toolName: "add_job_tag",
  collapsedSummary: (context) => tagActionSummary(context, "add"),
  renderExpanded
}

export default addJobTagToolCard
