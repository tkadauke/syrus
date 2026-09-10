import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseReadChatMessages, ReadChatMessagesCard, readChatMessagesCollapsedSummary } from "../chatSearchToolCard"

function renderExpanded(context: ToolCardContext) {
  if (!parseReadChatMessages(context)) return null
  return <ReadChatMessagesCard context={context} />
}

const readChatMessagesToolCard: ToolCardRenderer = {
  toolName: "read_chat_messages",
  collapsedSummary: readChatMessagesCollapsedSummary,
  renderExpanded
}

export default readChatMessagesToolCard
