import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseRepoDocumentAction, RepoDocumentActionCard, repoDocumentActionSummary } from "../repoDocumentToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseRepoDocumentAction(context, "delete")
  return result ? repoDocumentActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseRepoDocumentAction(context, "delete")
  return result ? <RepoDocumentActionCard result={result} /> : null
}

const deleteRepoDocumentToolCard: ToolCardRenderer = {
  toolName: "delete_repo_document",
  collapsedSummary,
  renderExpanded
}

export default deleteRepoDocumentToolCard
