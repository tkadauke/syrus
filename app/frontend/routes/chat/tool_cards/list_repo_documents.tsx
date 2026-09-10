import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { renderRepoDocumentList, repoDocumentListSummary } from "../repoDocumentToolCard"

function collapsedSummary(context: ToolCardContext) {
  return repoDocumentListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  return renderRepoDocumentList(context)
}

const listRepoDocumentsToolCard: ToolCardRenderer = {
  toolName: "list_repo_documents",
  collapsedSummary,
  renderExpanded
}

export default listRepoDocumentsToolCard
