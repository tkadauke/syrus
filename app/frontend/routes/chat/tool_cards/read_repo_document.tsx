import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { renderRepoDocumentRead, repoDocumentReadSummary } from "../repoDocumentToolCard"

function collapsedSummary(context: ToolCardContext) {
  return repoDocumentReadSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  return renderRepoDocumentRead(context)
}

const readRepoDocumentToolCard: ToolCardRenderer = {
  toolName: "read_repo_document",
  collapsedSummary,
  renderExpanded
}

export default readRepoDocumentToolCard
