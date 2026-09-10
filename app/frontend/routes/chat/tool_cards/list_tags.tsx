import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { TagListCard, tagListSummary, tagRows } from "../utilityToolCards"

function renderExpanded(context: ToolCardContext) {
  const rows = tagRows(context)
  if (!rows) return null
  return <TagListCard rows={rows} />
}

const listTagsToolCard: ToolCardRenderer = {
  toolName: "list_tags",
  collapsedSummary: tagListSummary,
  renderExpanded
}

export default listTagsToolCard
