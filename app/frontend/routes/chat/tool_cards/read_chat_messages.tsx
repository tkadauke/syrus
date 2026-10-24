import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseReadChatMessages, ReadChatMessagesCard, readChatMessagesCollapsedSummary } from "../chatSearchToolCard"

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ReadChatMessagesCard context={context} />
  if (!parseReadChatMessages(context)) return null
  return <ReadChatMessagesCard context={context} />
}

const readChatMessagesToolCard: ToolCardRenderer = {
  toolName: "read_chat_messages",
  collapsedSummary: readChatMessagesCollapsedSummary,
  renderExpanded
}

export default readChatMessagesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "markdown_media_and_deletion",
    label: "Markdown, media, and deletion metadata",
    input: { chat_session_id: 42, page: 1 },
    parsedResult: {
      chat_title: "Release investigation",
      page: 1,
      has_more: true,
      next_page: 2,
      chat_session_deleted_at: "2026-09-03T12:00:00Z",
      chat_session_deleted_by: { name: "Admin" },
      messages: [
        {
          id: 7,
          role: "user",
          content: {
            text: "## Findings\n\nSee JOB-42 and https://example.test.\n\n```ruby\nputs :ok\n```",
            attachments: [{ name: "diagram.png", mime_type: "image/png", data: "iVBORw0KGgo=" }]
          },
          created_at: "2026-09-01T12:00:00Z",
          deleted_at: "2026-09-02T12:00:00Z",
          deleted_by: { email: "admin@example.test" }
        }
      ]
    }
  },
  { id: "empty_page", label: "Empty page", input: { chat_session_id: 42 }, parsedResult: { chat_title: "Empty chat", page: 1, messages: [] } },
  {
    id: "not_authorized",
    label: "Not authorized",
    input: { chat_session_id: 99 },
    resultBody: "not_authorized: chat not found or inaccessible",
    resultError: true
  }
]
