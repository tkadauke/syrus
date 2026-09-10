import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { TagActionCard, tagAction, tagActionSummary } from "../utilityToolCards"

function renderExpanded(context: ToolCardContext) {
  const outcome = tagAction(context, "create")
  if (!outcome) return null
  return <TagActionCard outcome={outcome} />
}

const createTagToolCard: ToolCardRenderer = {
  toolName: "create_tag",
  collapsedSummary: (context) => tagActionSummary(context, "create"),
  renderExpanded
}

export default createTagToolCard
