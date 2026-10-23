import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { renderRepoDocumentRead, repoDocumentReadSummary } from "../repoDocumentToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "Read repository document",
  attempted: (context) => `Read document ${String(context.input?.id ?? "")}`.trim(),
  retrySafety: "safe",
  recovery: "Check that the document is still attached to this chat, then retry the read."
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  return repoDocumentReadSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  return renderRepoDocumentRead(context)
}

const readRepoDocumentToolCard: ToolCardRenderer = {
  toolName: "read_repo_document",
  renderWhilePending: true,
  collapsedSummary,
  renderExpanded,
  renderPending: renderExpanded
}

export default readRepoDocumentToolCard

export const examples: ToolCardExample[] = [
  {
    id: "markdown",
    label: "Markdown document",
    input: { id: 12, title: "API Guide", content_type: "text/markdown", size_bytes: 2048 },
    resultBody: "# API Guide\n\nSee **JOB-42** and https://example.test/docs. " + "More detail. ".repeat(120)
  },
  {
    id: "image",
    label: "Image document",
    input: { id: 13, title: "Architecture sketch", content_type: "image/png", size_bytes: 8192 },
    parsedResult: { content: [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }] }
  },
  {
    id: "truncated",
    label: "Server-truncated document",
    input: { id: 14, title: "Long notes", content_type: "text/plain" },
    resultBody: "Long notes\n\n[Document truncated after 65536 bytes; omitted 2048 bytes.]"
  },
  { id: "blank", label: "Blank document", input: { id: 15, title: "Blank notes", content_type: "text/plain" }, resultBody: "" },
  { id: "pending", label: "Pending read", input: { id: 16, title: "Loading notes" }, resultSettled: false },
  { id: "error", label: "Read error", input: { id: 17 }, resultBody: "document not found in this chat session's attachments", resultError: true }
]
