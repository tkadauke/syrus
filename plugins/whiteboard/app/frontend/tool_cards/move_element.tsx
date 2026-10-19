import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue, numberValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementFailureSummary, t } from "../whiteboardToolCard"

type Point = { x: number; y: number }
type MoveResult = {
  id: string
  targetId: string | null
  destination: Point | null
  previous: Point | null
  delta: Point | null
  version: number | null
}

function point(value: Record<string, unknown>, xKey: string, yKey: string): Point | null {
  const x = numberValue(value[xKey])
  const y = numberValue(value[yKey])
  return x == null || y == null ? null : { x, y }
}

function parseMoveResult(context: ToolCardContext): MoveResult | null {
  const input = isPlainObject(context.input) ? context.input : {}
  const envelope = isPlainObject(context.parsedResult) ? context.parsedResult : null
  const result = envelope && isPlainObject(envelope.result) ? envelope.result : envelope
  if (!result) return null

  const id = displayValue(result.from_id) || displayValue(result.id) || displayValue(input.from_id) || displayValue(input.id)
  if (!id) return null

  const destination = point(result, "x", "y") || point(input, "x", "y")
  const previous = point(result, "previous_x", "previous_y")
  const explicitDelta = point(result, "delta_x", "delta_y")
  const delta = explicitDelta || (destination && previous ? { x: destination.x - previous.x, y: destination.y - previous.y } : null)

  return {
    id,
    targetId: displayValue(result.to_id) || displayValue(input.to_id),
    destination,
    previous,
    delta,
    version: numberValue(result.version)
  }
}

function coordinates(value: Point) {
  return `(${value.x}, ${value.y})`
}

function summary(result: MoveResult) {
  const destination = result.targetId
    ? `${t("tool_field_to")} ${result.targetId}`
    : result.destination
      ? `${t("tool_field_to")} ${coordinates(result.destination)}`
      : null
  return [t("tool_action_moved_element"), result.id, destination, result.version == null ? null : `v${result.version}`].filter(Boolean).join(" · ")
}

function MoveElementCard({ result }: { result: MoveResult }) {
  const rows: CompactActionRow[] = []
  if (result.targetId) rows.push({ label: t("tool_field_to"), value: <span className="break-all font-mono">{result.targetId}</span> })
  else if (result.destination) rows.push({ label: "X / Y", value: <span className="font-mono">{coordinates(result.destination)}</span> })
  if (result.previous) rows.push({ label: t("tool_field_from"), value: <span className="font-mono">{coordinates(result.previous)}</span> })
  if (result.delta) rows.push({ label: "ΔX / ΔY", value: <span className="font-mono">{coordinates(result.delta)}</span> })

  return (
    <CompactActionCard
      action={t("tool_action_moved_element")}
      badges={result.version == null ? [] : [`v${result.version}`]}
      entity={<span className="min-w-0 break-all font-mono font-semibold text-text-primary">{result.id}</span>}
      rows={rows}
      tone="success"
    />
  )
}

const moveElementToolCard: ToolCardRenderer = {
  toolName: "move_element",
  collapsedSummary(context) {
    const action = t("tool_action_moved_element")
    const failure = elementFailureSummary(context, action)
    if (failure) return failure
    const result = parseMoveResult(context)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return summary(result)
  },
  renderExpanded(context) {
    const action = t("tool_action_moved_element")
    if (context.resultError) return <ElementFailureCard action={action} context={context} />
    const result = parseMoveResult(context)
    if (!result)
      return (
        <CompactActionCard
          action={action}
          rows={[{ label: t("tool_status"), value: t(context.parsedResult == null ? "tool_pending" : "tool_missing_result") }]}
          tone="info"
        />
      )
    return <MoveElementCard result={result} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "move_by_coordinates",
    label: "Move by coordinates",
    input: { id: "shape-1", x: 240, y: 120 },
    parsedResult: { id: "shape-1", x: 240, y: 120, previous_x: 100, previous_y: 80, version: 3 },
    sourceType: "generic"
  },
  {
    id: "move_to_element",
    label: "Move to element",
    parsedResult: { result: { from_id: "shape-1", to_id: "frame-2", version: 4 } },
    sourceType: "generic"
  },
  {
    id: "unknown_element",
    label: "Unknown element",
    input: { id: "missing", x: 10, y: 20 },
    parsedResult: { message: "Unknown element: missing", retryable: false },
    resultError: true,
    sourceType: "generic"
  }
]

export default moveElementToolCard
