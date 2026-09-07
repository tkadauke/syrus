import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, Disclosure, displayValue, Row, truncateLines } from "../toolCardUi"

// Local Mode tool card for write_file (EPIC-293 / JOB-4225). The tool
// result itself only confirms success; path and content come from the
// tool call's own input, which is only available in the expanded render
// path (see ToolCardContext.input), not the collapsed-summary dispatch.
const PREVIEW_LINE_LIMIT = 200

function parseSuccess(context: ToolCardContext): boolean {
  const parsed = context.parsedResult
  return isPlainObject(parsed) && parsed.success === true
}

function collapsedSummary(context: ToolCardContext) {
  if (!parseSuccess(context)) return null
  return "Wrote file"
}

function renderExpanded(context: ToolCardContext) {
  if (!parseSuccess(context)) return null

  const path = displayValue(context.input?.path)
  const content = typeof context.input?.content === "string" ? context.input.content : null
  const lineCount = content == null ? null : content === "" ? 0 : content.split("\n").length

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-2">
        {path ? <Row label="Path" value={path} /> : null}
        {lineCount != null ? <Row label="Lines written" value={String(lineCount)} /> : null}
      </dl>
      {content ? (
        <Disclosure label="Written content">
          {(() => {
            const { preview, truncated, totalLines } = truncateLines(content, PREVIEW_LINE_LIMIT)
            return (
              <>
                <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{preview}</pre>
                {truncated ? <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">Showing first {PREVIEW_LINE_LIMIT} of {totalLines} lines.</div> : null}
              </>
            )
          })()}
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

const writeFileToolCard: ToolCardRenderer = {
  toolName: "write_file",
  collapsedSummary,
  renderExpanded
}

export default writeFileToolCard
