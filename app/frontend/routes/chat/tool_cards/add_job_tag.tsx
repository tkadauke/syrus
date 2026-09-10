import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseTagAction(context, "add")
  return result ? tagActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseTagAction(context, "add")
  return result ? <TagActionCard result={result} /> : null
}

const addJobTagToolCard: ToolCardRenderer = {
  toolName: "add_job_tag",
  collapsedSummary,
  renderExpanded
}

export default addJobTagToolCard
