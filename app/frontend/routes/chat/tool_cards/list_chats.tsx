import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { ListChatsCard, listChatsCollapsedSummary, parseListChats } from "../chatSearchToolCard"

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ListChatsCard context={context} />
  if (!parseListChats(context)) return null
  return <ListChatsCard context={context} />
}

const listChatsToolCard: ToolCardRenderer = {
  toolName: "list_chats",
  collapsedSummary: listChatsCollapsedSummary,
  renderExpanded
}

export default listChatsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "filtered_chats_with_jobs",
    label: "Filtered chats with attached Jobs",
    input: { mode: "coding", has_attached_jobs: true },
    parsedResult: {
      chats: [
        {
          id: 42,
          title: "Landing queue notes",
          mode: "coding",
          repository_id: 7,
          repository: "acme/widgets",
          message_count: 9,
          updated_at: "2026-09-01T12:00:00Z",
          attached_jobs_count: 1,
          attached_jobs: [{ id: 101, slug: "repair-queue", title: "Repair the queue", state: "running", repository_id: 7, repository: "acme/widgets" }]
        }
      ],
      pagination: { page: 1, per_page: 20, total_count: 1, total_pages: 1, has_next_page: false }
    }
  },
  {
    id: "list_chats_error",
    label: "Error",
    resultBody: "Chat search service is unavailable.",
    resultError: true
  }
]
