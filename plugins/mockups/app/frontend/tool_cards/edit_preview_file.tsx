import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, Disclosure, displayValue, EntityReference, Row } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"
import { normalizedPreviewResult, parsePreviewFileOp, PreviewErrorCard, previewError, previewPanelText } from "../previewPanelToolCard"

function editErrorContext(context: ToolCardContext): ToolCardContext | null {
  if (context.resultError) return context
  const result = normalizedPreviewResult(context.parsedResult)
  if (!isPlainObject(result) || (!displayValue(result.error) && !displayValue(result.message))) return null
  return { ...context, resultError: true }
}

function collapsedSummary(context: ToolCardContext) {
  const failure = editErrorContext(context)
  if (failure) return previewPanelText("tool_failed_summary", { operation: previewPanelText("tool_edit_file"), error: previewError(failure) })
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  return op ? previewPanelText("tool_edited_summary", { path: op.path, id: op.panelId }) : null
}

function replacementDiff(path: string, oldString: string, newString: string) {
  const removed = (oldString ? oldString.split("\n") : [""]).map((line) => `-${line}`)
  const added = (newString ? newString.split("\n") : [""]).map((line) => `+${line}`)
  return [`--- ${path}`, `+++ ${path}`, "@@ replacement @@", ...removed, ...added].join("\n")
}

function renderExpanded(context: ToolCardContext) {
  const failure = editErrorContext(context)
  if (failure) return <PreviewErrorCard context={failure} title={previewPanelText("tool_edit_file")} />
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  if (!op) return null
  const oldString = typeof context.input?.old_string === "string" ? context.input.old_string : null
  const newString = typeof context.input?.new_string === "string" ? context.input.new_string : null
  const replaceAll = context.input?.replace_all === true

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge>{previewPanelText("tool_edited_file")}</Badge>
        <EntityReference kind="preview_panel" label={previewPanelText("tool_panel_number", { id: op.panelId })} slug={op.panelId} wrap="nowrap" />
      </div>
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        <Row label={previewPanelText("tool_path")} value={op.path} />
        {op.replacements != null ? <Row label={previewPanelText("tool_replacements")} value={String(op.replacements)} /> : null}
        <Row label={previewPanelText("tool_replace_all")} value={replaceAll ? previewPanelText("tool_yes") : previewPanelText("tool_no")} />
      </dl>
      {oldString != null && newString != null ? (
        <div className="min-w-0 overflow-hidden">
          <Disclosure label={previewPanelText("tool_changes")}>
            <div className="min-w-0 overflow-x-auto">
              <TextPreview
                lang="diff"
                maxLines={300}
                modalLabel={previewPanelText("tool_changes")}
                text={replacementDiff(op.path, oldString, newString)}
                wrap={false}
              />
            </div>
          </Disclosure>
        </div>
      ) : null}
    </CardShell>
  )
}

const editPreviewFileToolCard: ToolCardRenderer = {
  toolName: "edit_preview_file",
  collapsedSummary,
  renderExpanded
}

export default editPreviewFileToolCard

export const examples: ToolCardExample[] = [
  {
    id: "single_replacement",
    label: "Single replacement",
    input: { panel_id: "42", path: "index.html", old_string: "<h1>Draft</h1>", new_string: "<h1>Ready</h1>", replace_all: false },
    parsedResult: { panel_id: "42", path: "index.html", replacements: 1 }
  },
  {
    id: "replace_all",
    label: "Replace all matches",
    input: { panel_id: "42", path: "styles.css", old_string: "#fff", new_string: "var(--surface)", replace_all: true },
    parsedResult: { structured_content: { panel_id: "42", path: "styles.css", replacements: 4 } }
  },
  {
    id: "multiple_matches_error",
    label: "Multiple matches error",
    input: { panel_id: "42", path: "index.html", old_string: "button", new_string: "a", replace_all: false },
    parsedResult: { error: "old_string must appear exactly once; found 3 matches" }
  }
]
