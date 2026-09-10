import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseTagAction(context, "create")
  return result ? tagActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseTagAction(context, "create")
  return result ? <TagActionCard result={result} /> : null
}

const createTagToolCard: ToolCardRenderer = {
  toolName: "create_tag",
  collapsedSummary,
  renderExpanded
}

export default createTagToolCard
