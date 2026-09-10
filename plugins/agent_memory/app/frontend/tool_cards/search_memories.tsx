import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { memoryRows, MemoryListBody, memoryListSummary } from "../memoryToolCard"

// Plugin-owned tool card for search_memories (the tool-card work). Shares its list
// rendering with list_memories -- both tools return the same
// `{ memories: [memory_payload, ...] }` shape.
function collapsedSummary(context: ToolCardContext) {
  return memoryListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const rows = memoryRows(context)
  if (!rows) return null

  return <MemoryListBody emptyMessage="No memories match this search." rows={rows} />
}

const searchMemoriesToolCard: ToolCardRenderer = {
  toolName: "search_memories",
  collapsedSummary,
  renderExpanded
}

export default searchMemoriesToolCard
