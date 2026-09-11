import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseTagAction(context, "remove")
  return result ? tagActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseTagAction(context, "remove")
  return result ? <TagActionCard result={result} /> : null
}

const removeJobTagToolCard: ToolCardRenderer = {
  toolName: "remove_job_tag",
  collapsedSummary,
  renderExpanded
}

export default removeJobTagToolCard
