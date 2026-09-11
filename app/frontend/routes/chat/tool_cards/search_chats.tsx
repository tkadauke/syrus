import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSearchChats, SearchChatsCard, searchChatsCollapsedSummary } from "../chatSearchToolCard"

function renderExpanded(context: ToolCardContext) {
  if (!parseSearchChats(context)) return null
  return <SearchChatsCard context={context} />
}

const searchChatsToolCard: ToolCardRenderer = {
  toolName: "search_chats",
  collapsedSummary: searchChatsCollapsedSummary,
  renderExpanded
}

export default searchChatsToolCard
