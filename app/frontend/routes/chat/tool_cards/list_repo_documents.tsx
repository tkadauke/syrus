import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { renderRepoDocumentList, repoDocumentListSummary } from "../repoDocumentToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "List repository documents",
  attempted: () => "List repository documents",
  retrySafety: "safe",
  recovery: "Check repository access and retry the request."
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  return repoDocumentListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  return renderRepoDocumentList(context)
}

const listRepoDocumentsToolCard: ToolCardRenderer = {
  toolName: "list_repo_documents",
  collapsedSummary,
  renderExpanded
}

export default listRepoDocumentsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "linked_documents",
    label: "Linked documents",
    sourceType: "codex",
    parsedResult: {
      documents: [
        {
          id: 12,
          ref: "repo-doc-12",
          title: "API Guide",
          kind: "file",
          status: "attached",
          repository_id: 7,
          repository: "tkadauke/syrus",
          content_type: "text/markdown",
          size_bytes: 2048
        },
        {
          id: 13,
          title: "Launch Notes",
          kind: "google_doc",
          repository_id: 7,
          repository_slug: "tkadauke/syrus",
          url: "https://docs.google.com/document/d/example/edit"
        }
      ]
    }
  },
  { id: "empty", label: "Empty repository", sourceType: "claude", parsedResult: [] },
  { id: "pending", label: "Pending result", sourceType: "generic" },
  { id: "error", label: "Repository access error", sourceType: "generic", resultBody: "Repository is unavailable", resultError: true }
]
