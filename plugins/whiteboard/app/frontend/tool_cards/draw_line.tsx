import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { Disclosure, displayValue, numberValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

type Point = [number, number]

function pointsFrom(input: Record<string, unknown>): Point[] {
  if (!Array.isArray(input.points)) return []
  return input.points.flatMap((point) => {
    const x = numberValue(Array.isArray(point) ? point[0] : isPlainObject(point) ? point.x : null)
    const y = numberValue(Array.isArray(point) ? point[1] : isPlainObject(point) ? point.y : null)
    return x != null && y != null ? [[x, y] as Point] : []
  })
}

function formattedPoint([x, y]: Point) {
  return `(${x}, ${y})`
}

function LineCard({ context }: { context: ToolCardContext }) {
  const action = t("tool_action_drew_line")
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

  const input = isPlainObject(context.input) ? (redactToolCardValue(context.input) as Record<string, unknown>) : {}
  const type = displayValue(input.type)
  const x = displayValue(input.x)
  const y = displayValue(input.y)
  const points = pointsFrom(input)
  const pointCount = t("tool_points_count", { count: points.length })
  const strokeWidth = displayValue(input.stroke_width)
  const color = displayValue(input.color)
  const startArrowhead = displayValue(input.start_arrowhead)
  const endArrowhead = displayValue(input.end_arrowhead)
  const rows: CompactActionRow[] = []

  if (type || x || y)
    rows.push({
      label: t("tool_details"),
      value: (
        <div className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
          {type ? (
            <span>
              {t("tool_field_type")}: <span className="font-mono">{type}</span>
            </span>
          ) : null}
          {x ? (
            <span>
              X: <span className="font-mono">{x}</span>
            </span>
          ) : null}
          {y ? (
            <span>
              Y: <span className="font-mono">{y}</span>
            </span>
          ) : null}
        </div>
      )
    })

  rows.push({
    label: t("tool_field_points"),
    value: (
      <div className="flex min-w-0 flex-col gap-1">
        <span>{pointCount}</span>
        {points.length > 0 ? (
          <span className="break-words font-mono">{`${formattedPoint(points[0])} → ${formattedPoint(points[points.length - 1])}`}</span>
        ) : null}
        {points.length > 0 ? (
          <Disclosure label={`${t("tool_field_points")} · ${pointCount}`}>
            <ol className="space-y-1 font-mono text-xs">
              {points.map((point, index) => (
                <li className="break-words" key={`${index}-${point[0]}-${point[1]}`}>{`${index + 1}. ${formattedPoint(point)}`}</li>
              ))}
            </ol>
          </Disclosure>
        ) : null}
      </div>
    )
  })

  if (strokeWidth || color)
    rows.push({
      label: t("tool_field_stroke_width"),
      value: (
        <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
          {strokeWidth ? <span className="font-mono">{strokeWidth}</span> : null}
          {color ? (
            <span className="inline-flex min-w-0 items-center gap-1">
              <span className="text-text-subtle">{t("tool_field_color")}:</span>
              <span aria-label={color} className="h-3 w-3 shrink-0 rounded-full border border-border" style={{ backgroundColor: color }} />
              <span className="break-all font-mono">{color}</span>
            </span>
          ) : null}
        </div>
      )
    })

  if (startArrowhead || endArrowhead)
    rows.push({
      label: t("tool_field_start_arrowhead"),
      value: (
        <div className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
          {startArrowhead ? (
            <span>
              {t("tool_field_start_arrowhead")}: <span className="font-mono">{startArrowhead}</span>
            </span>
          ) : null}
          {endArrowhead ? (
            <span>
              {t("tool_field_end_arrowhead")}: <span className="font-mono">{endArrowhead}</span>
            </span>
          ) : null}
        </div>
      )
    })

  return (
    <CompactActionCard
      action={action}
      badges={result.version != null ? [`v${result.version}`] : []}
      entity={<span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>}
      rows={rows}
      tone="success"
    />
  )
}

const renderer: ToolCardRenderer = {
  toolName: "draw_line",
  collapsedSummary(context) {
    const action = t("tool_action_drew_line")
    const failureSummary = elementFailureSummary(context, action)
    if (failureSummary) return failureSummary
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
  },
  renderExpanded(context) {
    return <LineCard context={context} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "styled_line",
    label: "Styled line",
    input: {
      x: 20,
      y: 30,
      points: [
        [0, 0],
        [40, 20],
        [80, 5]
      ],
      stroke_width: 3,
      color: "#b6492e",
      start_arrowhead: "dot",
      end_arrowhead: "arrow"
    },
    parsedResult: { id: "line-demo", version: 2 },
    sourceType: "generic"
  },
  { id: "pending", label: "Pending result", input: { x: 0, y: 0, points: [] }, resultBody: "", sourceType: "generic" },
  {
    id: "element_limit",
    label: "Element limit exceeded",
    input: { x: 0, y: 0, points: [] },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" },
    resultError: true,
    sourceType: "generic"
  }
]

export default renderer
