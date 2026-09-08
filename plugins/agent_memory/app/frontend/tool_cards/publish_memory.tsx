import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MemoryDetailBody, parseMemoryDetail } from "../memoryToolCard"

// Plugin-owned tool card for publish_memory (EPIC-293).
function collapsedSummary(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return `Published memory #${memory.id}`
}

function renderExpanded(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return <MemoryDetailBody memory={memory} />
}

const publishMemoryToolCard: ToolCardRenderer = {
  toolName: "publish_memory",
  collapsedSummary,
  renderExpanded
}

export default publishMemoryToolCard
