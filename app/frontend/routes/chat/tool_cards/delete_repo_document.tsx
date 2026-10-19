import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseRepoDocumentAction, RepoDocumentActionCard, repoDocumentActionSummary } from "../repoDocumentToolCard"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "Delete repository document",
  attempted: (context) => {
    const documentId = stringFromInput(context, ["document_id", "id"])
    return documentId ? `Delete document ${documentId}` : "Delete repository document"
  },
  retrySafety: "caution",
  recovery: "Check that the document still exists and that its ID is correct before retrying."
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const result = parseRepoDocumentAction(context, "delete")
  return result ? repoDocumentActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseRepoDocumentAction(context, "delete")
  return result ? <RepoDocumentActionCard result={result} /> : null
}

const deleteRepoDocumentToolCard: ToolCardRenderer = {
  toolName: "delete_repo_document",
  collapsedSummary,
  renderExpanded
}

export default deleteRepoDocumentToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_document",
    label: "Pending document deletion",
    sourceType: "claude",
    input: { document_id: 99 },
    parsedResult: {
      pending_action_id: 502,
      state: "pending",
      message: 'Delete document "Old notes"?',
      reason: "Remove the obsolete **draft**."
    }
  },
  {
    id: "document_not_found",
    label: "Document not found",
    sourceType: "codex",
    input: { document_id: 99 },
    parsedResult: { error: "Document not found" },
    resultError: true
  }
]
