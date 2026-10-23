import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "../toolFailureSummaryCard"
import { CardShell, displayValue, numberValue, Row } from "../toolCardUi"

const CONTENT_PREVIEW_CHARS = 960
const MARKDOWN_PATH = /(?:^|\/)(?:[^/]+\.(?:md|markdown|mdown|mkd)|README|CHANGELOG)(?:$|\?)/i
const failureConfig: ToolFailureConfig = {
  title: "Write file",
  attempted: (context) => displayValue(context.input?.path) || "Unknown path",
  retrySafety: "caution",
  recovery: "Check the Local Mode daemon connection and file permissions, then retry."
}

function successResult(context: ToolCardContext) {
  return isPlainObject(context.parsedResult) && context.parsedResult.success === true ? context.parsedResult : null
}

function errorContext(context: ToolCardContext): ToolCardContext | null {
  if (context.resultError) return context
  if (!isPlainObject(context.parsedResult)) return null
  const outcome = isPlainObject(context.parsedResult.outcome) ? context.parsedResult.outcome : null
  return displayValue(context.parsedResult.error) || displayValue(outcome?.error) ? { ...context, resultError: true } : null
}

function collapsedSummary(context: ToolCardContext) {
  const pending = parsePendingActionResult(context)
  if (pending) return pendingActionCollapsedSummary(pending)
  const failure = errorContext(context)
  if (failure) return toolFailureCollapsedSummary(failure, failureConfig)
  return successResult(context) ? "Wrote file" : null
}

function ContentPreview({ path, content }: { path: string | null; content: string | null }) {
  if (content == null) return null
  const title = path ? `Written content: ${path}` : "Written content"
  return (
    <div className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface p-2">
      <div className="mb-1 text-2xs font-semibold uppercase text-text-muted">Written content</div>
      {path && MARKDOWN_PATH.test(path) ? (
        <MarkdownPreview
          emptyLabel="The file is empty."
          linkifySlugs
          linkifyUrls
          maxChars={CONTENT_PREVIEW_CHARS}
          modalLabel={title}
          text={content}
          title={path}
        />
      ) : (
        <TextPreview emptyLabel="The file is empty." maxChars={CONTENT_PREVIEW_CHARS} text={content} title={title} />
      )}
    </div>
  )
}

function FileDetails({ context }: { context: ToolCardContext }) {
  const path = displayValue(context.input?.path) || displayValue(context.input?.file_path)
  const content = typeof context.input?.content === "string" ? context.input.content : null
  const result = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const bytes = numberValue(result.bytes_written) ?? numberValue(result.bytes) ?? (content == null ? null : new TextEncoder().encode(content).length)
  return (
    <CardShell>
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {path ? <Row label="Path" value={path} /> : null}
        {bytes != null ? <Row label="Bytes written" value={String(bytes)} /> : null}
      </dl>
      <ContentPreview content={content} path={path} />
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const failure = errorContext(context)
  if (failure) return <ToolFailureSummaryCard config={failureConfig} context={failure} />
  const pending = parsePendingActionResult(context)
  if (pending)
    return (
      <div className="min-w-0 space-y-2">
        <FileDetails context={context} />
        <PendingActionResultCard result={pending} />
      </div>
    )
  if (!successResult(context)) return null
  return <FileDetails context={context} />
}

const writeFileToolCard: ToolCardRenderer = { toolName: "write_file", collapsedSummary, renderExpanded }

export const examples: ToolCardExample[] = [
  {
    id: "pending_markdown_confirmation",
    label: "Pending Markdown write",
    input: { path: "docs/notes.md", content: "# Notes\n\nSee JOB-42 and https://example.com/details." },
    parsedResult: { pending_confirmation_id: 701, pending_action_id: 701, state: "pending", message: "Writing this file requires confirmation." }
  },
  {
    id: "local_daemon_error",
    label: "Local daemon unavailable",
    input: { path: "notes.txt", content: "hello" },
    resultBody: "Local daemon not connected",
    resultError: true
  }
]

export default writeFileToolCard
