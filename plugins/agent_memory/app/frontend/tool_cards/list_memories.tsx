import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { memoryRows, MemoryListBody, memoryListSummary } from "../memoryToolCard"

// Plugin-owned tool card for list_memories (EPIC-293). Lives entirely
// inside the agent_memory plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
function collapsedSummary(context: ToolCardContext) {
  return memoryListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const rows = memoryRows(context)
  if (!rows) return null

  return <MemoryListBody emptyMessage="No memories match this scope." rows={rows} />
}

const listMemoriesToolCard: ToolCardRenderer = {
  toolName: "list_memories",
  collapsedSummary,
  renderExpanded
}

export default listMemoriesToolCard
