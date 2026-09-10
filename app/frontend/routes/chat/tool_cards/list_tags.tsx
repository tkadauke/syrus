import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { renderTagList, tagListSummary } from "../issueTagArtifactToolCard"

const listTagsToolCard: ToolCardRenderer = {
  toolName: "list_tags",
  collapsedSummary: (context: ToolCardContext) => tagListSummary(context),
  renderExpanded: (context: ToolCardContext) => renderTagList(context)
}

export default listTagsToolCard
