import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ElementActionCard, ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

const ACTION_KEY = "tool_action_deleted_element"

function resultRecord(value: unknown): Record<string, unknown> {
  if (!isPlainObject(value)) return {}
  return isPlainObject(value.result) ? value.result : value
}

function elementContext(context: ToolCardContext) {
  const input = isPlainObject(context.input) ? context.input : {}
  const result = resultRecord(context.parsedResult)
  const element = isPlainObject(result.element) ? result.element : {}
  const type = displayValue(result.type) ?? displayValue(element.type) ?? displayValue(input.type)
  const label = displayValue(result.label) ?? displayValue(element.label) ?? displayValue(input.label)

  return { ...input, ...(type ? { type } : {}), ...(label ? { label } : {}) }
}

function collapsedSummary(context: ToolCardContext) {
  const action = t(ACTION_KEY)
  const failure = elementFailureSummary(context, action)
  if (failure) return failure

  const result = parseElementResult(context.parsedResult)
  if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
  return elementActionSummary(action, result, elementContext(context))
}

function renderExpanded(context: ToolCardContext) {
  const action = t(ACTION_KEY)
  if (elementFailureSummary(context, action)) return <ElementFailureCard action={action} context={context} />

  const result = parseElementResult(context.parsedResult)
  if (!result)
    return (
      <CompactActionCard
        action={action}
        rows={[{ label: t("tool_status"), value: t(context.parsedResult == null ? "tool_pending" : "tool_missing_result") }]}
        tone="info"
      />
    )
  return <ElementActionCard action={action} input={elementContext(context)} result={result} />
}

const deleteElementToolCard: ToolCardRenderer = { toolName: "delete_element", collapsedSummary, renderExpanded }

export const examples: ToolCardExample[] = [
  {
    id: "deleted_labeled_shape",
    label: "Deleted labeled shape",
    input: { id: "shape-demo" },
    parsedResult: { id: "shape-demo", type: "diamond", label: "Decision", version: 8 },
    sourceType: "generic"
  },
  {
    id: "element_not_found",
    label: "Element not found",
    input: { id: "missing-element" },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementNotFound", message: "Element not found: missing-element", retryable: false },
    resultError: true,
    sourceType: "generic"
  },
  {
    id: "wrapped_result",
    label: "Wrapped result",
    input: { id: "text-demo" },
    parsedResult: { result: { id: "text-demo", type: "text", label: "Release notes", version: 9 } },
    sourceType: "generic"
  },
  { id: "pending", label: "Pending result", input: { id: "pending-element" }, resultBody: "", sourceType: "generic" }
]

export default deleteElementToolCard
