import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { ListChatsCard, listChatsCollapsedSummary, parseListChats } from "../chatSearchToolCard"

function renderExpanded(context: ToolCardContext) {
  if (!parseListChats(context)) return null
  return <ListChatsCard context={context} />
}

const listChatsToolCard: ToolCardRenderer = {
  toolName: "list_chats",
  collapsedSummary: listChatsCollapsedSummary,
  renderExpanded
}

export default listChatsToolCard
