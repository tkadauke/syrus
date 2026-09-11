import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, Disclosure, displayValue, Row, truncateLines } from "../toolCardUi"

// Local Mode tool card for read_file (the tool-card work). Shows a line
// count and the path (when available from the tool call input) without
// dumping the full file content by default -- content lives behind a
// disclosure, capped to keep very large files from freezing the chat DOM.
const PREVIEW_LINE_LIMIT = 200

function parseContent(context: ToolCardContext): string | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.content !== "string") return null
  return parsed.content
}

function collapsedSummary(context: ToolCardContext) {
  const content = parseContent(context)
  if (content == null) return null
  const lineCount = content === "" ? 0 : content.split("\n").length
  return `Read file (${lineCount} line${lineCount === 1 ? "" : "s"})`
}

function renderExpanded(context: ToolCardContext) {
  const content = parseContent(context)
  if (content == null) return null

  const path = displayValue(context.input?.path)
  const lineCount = content === "" ? 0 : content.split("\n").length
  const { preview, truncated, totalLines } = truncateLines(content, PREVIEW_LINE_LIMIT)

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-2">
        {path ? <Row label="Path" value={path} /> : null}
        <Row label="Lines" value={String(lineCount)} />
      </dl>
      {content === "" ? (
        <div className="text-gray-500 dark:text-gray-400">Empty file.</div>
      ) : (
        <Disclosure label="File content">
          <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{preview}</pre>
          {truncated ? (
            <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">
              Showing first {PREVIEW_LINE_LIMIT} of {totalLines} lines.
            </div>
          ) : null}
        </Disclosure>
      )}
    </CardShell>
  )
}

const readFileToolCard: ToolCardRenderer = {
  toolName: "read_file",
  collapsedSummary,
  renderExpanded
}

export default readFileToolCard
