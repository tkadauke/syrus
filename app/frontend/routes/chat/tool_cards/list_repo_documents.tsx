import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { renderRepoDocumentList, repoDocumentListSummary } from "../repoDocumentToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "List repository documents",
  attempted: () => "List documents available to this chat",
  retrySafety: "safe",
  recovery: "Retry the request. If it still fails, check repository access and document availability."
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
    id: "documents_across_repositories",
    label: "Documents across repositories",
    sourceType: "codex",
    parsedResult: [
      {
        id: 12,
        kind: "file",
        title: "API Guide with a title that wraps on narrow screens",
        status: "attached",
        repository_id: 7,
        repository: "tkadauke/syrus",
        content_type: "text/markdown",
        size_bytes: 2048
      },
      {
        id: 13,
        kind: "google_doc",
        title: "Launch Notes",
        status: "pending",
        repository_id: 8,
        repository: "acme/very-long-repository-name",
        url: "https://docs.google.com/document/d/a-very-long-document-identifier/edit"
      }
    ]
  },
  {
    id: "no_documents",
    label: "No documents",
    parsedResult: { documents: [] }
  },
  {
    id: "list_error",
    label: "List error",
    resultBody: "Repository documents are temporarily unavailable",
    resultError: true
  }
]
