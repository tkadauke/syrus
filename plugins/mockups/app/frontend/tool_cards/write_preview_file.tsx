import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview, TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, EntityReference, InternalLink, Row } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"
import { normalizedPreviewResult, parsePreviewFileOp, PreviewErrorCard, previewError, previewPanelText } from "../previewPanelToolCard"

const CONTENT_PREVIEW_CHARS = 960
const MARKDOWN_PATH = /(?:^|\/)(?:[^/]+\.(?:md|markdown|mdown|mkd)|README|CHANGELOG)$/i

function errorContext(context: ToolCardContext): ToolCardContext | null {
  if (context.resultError) return context
  const result = normalizedPreviewResult(context.parsedResult)
  if (!isPlainObject(result) || (!displayValue(result.error) && !displayValue(result.message))) return null
  return { ...context, resultError: true }
}

// Plugin-owned tool card for write_preview_file (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const failure = errorContext(context)
  if (failure) return previewPanelText("tool_failed_summary", { operation: previewPanelText("tool_write_file"), error: previewError(failure) })
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  return op ? previewPanelText("tool_wrote_summary", { path: op.path, id: op.panelId }) : null
}

function renderExpanded(context: ToolCardContext) {
  const failure = errorContext(context)
  if (failure) return <PreviewErrorCard context={failure} title={previewPanelText("tool_write_preview_file")} />
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  if (!op) return null
  const previewTitle = previewPanelText("tool_written_content_path", { path: op.path })
  const panelHref =
    context.chatSessionId == null
      ? null
      : `/chats/${encodeURIComponent(String(context.chatSessionId))}?workspace=${encodeURIComponent(`preview:${op.panelId}`)}`

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge>{previewPanelText("tool_wrote_file")}</Badge>
        <EntityReference
          href={panelHref}
          kind="preview_panel"
          label={previewPanelText("tool_panel_number", { id: op.panelId })}
          slug={op.panelId}
          wrap="nowrap"
        />
      </div>
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        <Row label={previewPanelText("tool_path")} value={op.path} />
        {op.size != null ? <Row label={previewPanelText("tool_size")} value={previewPanelText("tool_bytes", { count: op.size })} /> : null}
        {op.lines != null ? <Row label={previewPanelText("tool_lines")} value={String(op.lines)} /> : null}
      </dl>
      {op.mockupSlug ? <InternalLink href={`/mockups/${op.mockupSlug}`}>{previewPanelText("tool_open_mockup")}</InternalLink> : null}
      {op.content != null ? (
        <Disclosure label={previewPanelText("tool_written_content")}>
          {MARKDOWN_PATH.test(op.path) ? (
            <MarkdownPreview
              emptyState={<EmptyState>{previewPanelText("tool_empty_file")}</EmptyState>}
              linkifySlugs
              linkifyUrls
              maxChars={CONTENT_PREVIEW_CHARS}
              modalLabel={previewTitle}
              text={op.content}
              title={op.path}
            />
          ) : op.content.trim() ? (
            <TextPreview maxChars={CONTENT_PREVIEW_CHARS} modalLabel={previewTitle} text={op.content} title={op.path} />
          ) : (
            <EmptyState>{previewPanelText("tool_empty_file")}</EmptyState>
          )}
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

const writePreviewFileToolCard: ToolCardRenderer = {
  toolName: "write_preview_file",
  collapsedSummary,
  renderExpanded
}

export default writePreviewFileToolCard

export const examples: ToolCardExample[] = [
  {
    id: "markdown_file",
    label: "Markdown file",
    chatSessionId: 8,
    input: { panel_id: "42", path: "notes.md", content: `# Notes\n\nSee JOB-42 and https://example.test/details.\n\n${"More prose. ".repeat(100)}` },
    parsedResult: { panel_id: "42", path: "notes.md", mockup_slug: "MOCKUP-42" }
  },
  {
    id: "codex_envelope",
    label: "Code file in structured envelope",
    input: { panel_id: "42", path: "src/app.js", content: "console.log('ready')\n" },
    sourceType: "codex",
    parsedResult: { structured_content: { panel_id: "42", path: "src/app.js" } }
  },
  {
    id: "claude_envelope",
    label: "Empty file in text envelope",
    input: { panel_id: "42", path: "empty.txt", content: "" },
    sourceType: "claude",
    parsedResult: { content: [{ type: "text", text: JSON.stringify({ panel_id: "42", path: "empty.txt" }) }] }
  },
  {
    id: "panel_not_found",
    label: "Panel not found",
    input: { panel_id: "404", path: "index.html", content: "<h1>404</h1>" },
    parsedResult: { error: "Preview panel 404 was not found" },
    resultError: true
  },
  {
    id: "path_required",
    label: "Path required",
    input: { panel_id: "42", path: "", content: "hello" },
    resultBody: "Error: path is required",
    resultError: true
  }
]
