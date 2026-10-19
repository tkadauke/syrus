import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSearchChats, SearchChatsCard, searchChatsCollapsedSummary } from "../chatSearchToolCard"

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <SearchChatsCard context={context} />
  if (!parseSearchChats(context)) return null
  return <SearchChatsCard context={context} />
}

const searchChatsToolCard: ToolCardRenderer = {
  toolName: "search_chats",
  collapsedSummary: searchChatsCollapsedSummary,
  renderExpanded
}

export default searchChatsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "markdown_matches_with_context",
    label: "Markdown matches with linked context",
    input: { query: "deploy", limit: 10 },
    parsedResult: {
      results: [
        {
          chat_session_id: 42,
          message_id: 100,
          chat_title: "Deployment notes",
          mode: "coding",
          repository_id: 7,
          repository: "acme/widgets",
          role: "assistant",
          snippet: "Review **JOB-101** before the <b>deploy</b>. See https://example.test/runbook for details. ".repeat(8),
          created_at: "2026-09-01T12:00:00Z",
          attached_jobs_count: 1,
          attached_jobs: [{ id: 101, slug: "repair-queue", title: "Repair the queue", state: "running", repository_id: 8, repository: "acme/worker" }]
        }
      ]
    }
  },
  {
    id: "admin_deleted_match",
    label: "Admin-visible deleted match",
    input: { query: "retired" },
    parsedResult: {
      results: [
        {
          chat_session_id: 43,
          message_id: 102,
          chat_title: "Retired discussion",
          mode: "planning",
          role: "user",
          snippet: "A <b>retired</b> message.",
          created_at: "2026-09-01T12:00:00Z",
          chat_session_deleted_at: "2026-09-02T12:00:00Z",
          chat_session_deleted_by: { id: 1, name: "Admin" },
          deleted_at: "2026-09-02T11:00:00Z",
          deleted_by: { id: 1, name: "Admin" }
        }
      ]
    }
  }
]
