import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { memoryRows, MemoryListBody, memoryListSummary } from "../memoryToolCard"

// Plugin-owned tool card for list_memories (the tool-card work). Lives entirely
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

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "two_repository_memories",
    label: "Two repository-scoped memories",
    input: { kind: "feedback" },
    parsedResult: {
      memories: [
        {
          id: "133",
          kind: "feedback",
          scope: "repository",
          scope_id: "42",
          content: "Every new MCP tool registered on the chat surface needs an explicit rendering decision.",
          published: true,
          author: "agent",
          confidence: 0.9,
          created_at: "2026-09-10T14:22:00Z",
          updated_at: "2026-09-10T14:22:00Z",
          deleted_at: null
        },
        {
          id: "126",
          kind: "project_fact",
          scope: "repository",
          scope_id: "42",
          content: "When adding or changing Syrus ApplicationJob classes, explicitly set queue_as to a consumed queue.",
          published: false,
          author: "agent",
          confidence: null,
          created_at: "2026-08-30T09:10:00Z",
          updated_at: "2026-08-30T09:10:00Z",
          deleted_at: null
        }
      ]
    }
  },
  {
    id: "no_matching_memories",
    label: "No matching memories",
    description: "Empty result set -- the card renders MemoryListBody's own empty-state message.",
    input: { kind: "decision" },
    parsedResult: { memories: [] }
  }
]
