import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

export const examples: ToolCardExample[] = [
  {
    id: "named_frame_with_children",
    label: "Named frame with contained elements",
    input: {
      type: "magicframe",
      name: "Release plan",
      x: 24,
      y: 48,
      width: 640,
      height: 360,
      element_ids: ["shape-alpha", "text-beta", "arrow-gamma"]
    },
    parsedResult: { id: "frame-demo", version: 5 },
    sourceType: "generic"
  },
  {
    id: "wrapped_result",
    label: "Wrapped result envelope",
    input: { type: "frame", label: "Architecture", x: 0, y: 0, width: 480, height: 320 },
    parsedResult: { result: { id: "frame-wrapped", version: 2 } },
    sourceType: "generic"
  },
  {
    id: "invalid_bounds",
    label: "Invalid frame bounds",
    input: { type: "frame", name: "Broken frame", x: 10, y: 20, width: -1, height: 100 },
    parsedResult: { message: "width must be greater than zero", retryable: false },
    resultError: true,
    sourceType: "generic"
  },
  {
    id: "pending",
    label: "Pending result",
    input: { type: "frame", name: "Pending frame", x: 10, y: 20, width: 300, height: 200 },
    resultBody: "",
    sourceType: "generic"
  }
]

function frameRows(input: Record<string, unknown>): CompactActionRow[] {
  const rows: CompactActionRow[] = []
  const name = displayValue(input.name) ?? displayValue(input.label)
  const bounds = ["x", "y", "width", "height"].flatMap((key) => {
    const value = displayValue(input[key])
    return value ? [{ key, value }] : []
  })
  const elementIds = Array.isArray(input.element_ids) ? input.element_ids.flatMap((id) => displayValue(id) ?? []) : []

  if (name) rows.push({ label: t("tool_field_name"), value: <span className="break-words">{name}</span> })
  if (bounds.length > 0)
    rows.push({
      label: t("tool_details"),
      value: (
        <span className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
          {bounds.map(({ key, value }) => (
            <span className="whitespace-nowrap font-mono" key={key}>
              <span className="text-text-subtle">{key}:</span> {value}
            </span>
          ))}
        </span>
      )
    })
  if (elementIds.length > 0)
    rows.push({
      label: t("tool_elements"),
      value: (
        <span className="flex min-w-0 flex-wrap gap-1">
          {elementIds.map((id) => (
            <span className="max-w-full break-all rounded bg-surface-muted px-1.5 py-0.5 font-mono" key={id}>
              {id}
            </span>
          ))}
        </span>
      )
    })

  return rows
}

const drawFrameToolCard: ToolCardRenderer = {
  toolName: "draw_frame",
  collapsedSummary(context) {
    const action = t("tool_action_drew_frame")
    const failureSummary = elementFailureSummary(context, action)
    if (failureSummary) return failureSummary
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
  },
  renderExpanded(context: ToolCardContext) {
    const action = t("tool_action_drew_frame")
    if (context.resultError) return <ElementFailureCard action={action} context={context} />
    const result = parseElementResult(context.parsedResult)
    if (!result)
      return (
        <CompactActionCard
          action={action}
          rows={[{ label: t("tool_status"), value: t(context.parsedResult == null ? "tool_pending" : "tool_missing_result") }]}
          tone="info"
        />
      )

    const input = isPlainObject(context.input) ? context.input : {}
    const type = displayValue(input.type)
    return (
      <CompactActionCard
        action={action}
        badges={[...(type ? [type] : []), ...(result.version != null ? [`v${result.version}`] : [])]}
        entity={<span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>}
        rows={frameRows(input)}
        tone="success"
      />
    )
  }
}

export default drawFrameToolCard
