import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseRepoDocumentAction, RepoDocumentActionCard, repoDocumentActionSummary } from "../repoDocumentToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseRepoDocumentAction(context, "create")
  return result ? repoDocumentActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseRepoDocumentAction(context, "create")
  return result ? <RepoDocumentActionCard result={result} /> : null
}

const createRepoDocumentToolCard: ToolCardRenderer = {
  toolName: "create_repo_document",
  collapsedSummary,
  renderExpanded
}

export default createRepoDocumentToolCard
