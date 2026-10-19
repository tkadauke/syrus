import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
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

function pointLabel(point: Point) {
  return `(${point[0]}, ${point[1]})`
}

function field(label: string, value: unknown) {
  const displayed = displayValue(value)
  return displayed ? (
    <span className="inline-flex min-w-0 items-center gap-1">
      <span className="text-text-subtle">{label}:</span>
      <span className="break-all font-mono">{displayed}</span>
    </span>
  ) : null
}

function LineCard({ context }: { context: ToolCardContext }) {
  const action = t("tool_action_drew_line")
  const result = parseElementResult(context.parsedResult)
  if (!result) {
    return (
      <CompactActionCard
        action={action}
        rows={[{ label: t("tool_status"), value: t(context.parsedResult == null ? "tool_pending" : "tool_missing_result") }]}
        tone="info"
      />
    )
  }

  const input = isPlainObject(context.input) ? context.input : {}
  const points = pointsFrom(input)
  const pointCount = t("tool_points_count", { count: points.length })
  const endpoints = points.length > 0 ? `${pointLabel(points[0])} → ${pointLabel(points[points.length - 1])}` : null
  const color = displayValue(input.color)
  const rows: CompactActionRow[] = [
    {
      label: t("tool_details"),
      value: (
        <div className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
          {field(t("tool_field_type"), input.type)}
          {field("X", input.x)}
          {field("Y", input.y)}
          {field(t("tool_field_width"), input.width)}
          {field(t("tool_field_height"), input.height)}
        </div>
      )
    },
    {
      label: t("tool_field_points"),
      value: (
        <span className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
          <span>{pointCount}</span>
          {endpoints ? <span className="break-all font-mono">{endpoints}</span> : null}
        </span>
      )
    },
    {
      label: t("tool_field_color"),
      value: color ? (
        <span className="inline-flex min-w-0 items-center gap-1">
          <span aria-label={color} className="h-3 w-3 shrink-0 rounded-full border border-border" style={{ backgroundColor: color }} />
          <span className="break-all font-mono">{color}</span>
        </span>
      ) : null
    },
    {
      label: t("tool_field_stroke_width"),
      value: (
        <div className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
          {field(t("tool_field_stroke_width"), input.stroke_width)}
          {field(t("tool_field_start_arrowhead"), input.start_arrowhead)}
          {field(t("tool_field_end_arrowhead"), input.end_arrowhead)}
        </div>
      )
    }
  ]

  return (
    <div className="min-w-0 space-y-2">
      <CompactActionCard
        action={action}
        badges={result.version != null ? [`v${result.version}`] : []}
        entity={<span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>}
        rows={rows}
        tone="success"
      />
      {points.length > 0 ? (
        <Disclosure label={`${t("tool_field_points")} · ${pointCount}`}>
          <ol className="grid min-w-0 gap-1 sm:grid-cols-2">
            {points.map((point, index) => (
              <li className="min-w-0 break-all font-mono text-xs" key={`${index}-${point[0]}-${point[1]}`}>
                {index + 1}. {pointLabel(point)}
              </li>
            ))}
          </ol>
        </Disclosure>
      ) : null}
    </div>
  )
}

const drawLineCard: ToolCardRenderer = {
  toolName: "draw_line",
  collapsedSummary(context) {
    const action = t("tool_action_drew_line")
    const failure = elementFailureSummary(context, action)
    if (failure) return failure
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
  },
  renderExpanded(context) {
    const action = t("tool_action_drew_line")
    if (context.resultError) return <ElementFailureCard action={action} context={context} />
    return <LineCard context={context} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "styled_polyline",
    label: "Styled polyline",
    input: {
      type: "line",
      x: 24,
      y: 36,
      width: 180,
      height: 90,
      points: [
        [0, 0],
        [90, 90],
        [180, 0]
      ],
      color: "#e11d48",
      stroke_width: 3,
      start_arrowhead: "dot",
      end_arrowhead: "arrow"
    },
    parsedResult: { result: { id: "line-demo", version: 4 } },
    sourceType: "generic"
  },
  { id: "pending", label: "Pending result", input: { x: 0, y: 0, points: [] }, resultBody: "", sourceType: "generic" },
  {
    id: "failed",
    label: "Failed line",
    input: {
      x: 0,
      y: 0,
      points: [
        [0, 0],
        [100, 100]
      ]
    },
    parsedResult: { message: "Could not draw line", retryable: false },
    resultError: true,
    sourceType: "generic"
  }
]

export default drawLineCard
