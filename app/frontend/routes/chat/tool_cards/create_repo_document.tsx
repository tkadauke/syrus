import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseRepoDocumentAction, RepoDocumentActionCard, repoDocumentActionSummary } from "../repoDocumentToolCard"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "Create repository document",
  attempted: (context) => {
    const title = stringFromInput(context, ["title"])
    return title ? `Create ${title}` : "Create repository document"
  },
  retrySafety: "caution",
  recovery: "Correct the document fields, then retry the request."
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const result = parseRepoDocumentAction(context, "create")
  return result ? repoDocumentActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseRepoDocumentAction(context, "create")
  return result ? <RepoDocumentActionCard result={result} /> : null
}

const createRepoDocumentToolCard: ToolCardRenderer = {
  toolName: "create_repo_document",
  collapsedSummary,
  renderExpanded
}

export default createRepoDocumentToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_markdown_document",
    label: "Pending Markdown document",
    sourceType: "claude",
    input: { repository_id: 7, repository_slug: "tkadauke/syrus", title: "API Guide", body: "# API Guide\n\nSee JOB-42 and https://example.test/docs." },
    parsedResult: { pending_action_id: 501, state: "pending", message: "Create **API Guide** in `tkadauke/syrus`?" }
  },
  {
    id: "validation_error",
    label: "Validation error",
    sourceType: "codex",
    input: { repository_id: 7, title: "", body: "# Notes" },
    resultBody: "title is required",
    resultError: true
  }
]
