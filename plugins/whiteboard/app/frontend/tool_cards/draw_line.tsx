import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

type Point = [string, string]

function parsePoints(value: unknown): Point[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((point) => {
    if (!Array.isArray(point) && !isPlainObject(point)) return []
    const x = displayValue(Array.isArray(point) ? point[0] : point.x)
    const y = displayValue(Array.isArray(point) ? point[1] : point.y)
    return x && y ? [[x, y] as Point] : []
  })
}

function PointList({ points }: { points: Point[] }) {
  if (points.length === 0) return null
  const endpoint = (point: Point) => `(${point[0]}, ${point[1]})`
  return (
    <details className="min-w-0 max-w-full">
      <summary className="cursor-pointer break-words font-mono">
        <span>{t("tool_points_count", { count: points.length })}</span> ·{" "}
        <span>
          {endpoint(points[0])}
          {points.length > 1 ? ` → ${endpoint(points[points.length - 1])}` : ""}
        </span>
      </summary>
      <ol className="mt-1 grid min-w-0 gap-1 font-mono sm:grid-cols-2">
        {points.map((point, index) => (
          <li className="break-all" key={`${index}-${point[0]}-${point[1]}`}>
            {index + 1}. {endpoint(point)}
          </li>
        ))}
      </ol>
    </details>
  )
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

  const input = isPlainObject(context.input) ? context.input : {}
  const points = parsePoints(input.points)
  const color = displayValue(input.color)
  const fields: Array<[string, string | null]> = [
    [t("tool_field_type"), displayValue(input.type)],
    ["X", displayValue(input.x)],
    ["Y", displayValue(input.y)],
    [t("tool_field_width"), displayValue(input.width)],
    [t("tool_field_height"), displayValue(input.height)],
    [t("tool_field_stroke_width"), displayValue(input.stroke_width)],
    [t("tool_field_start_arrowhead"), displayValue(input.start_arrowhead)],
    [t("tool_field_end_arrowhead"), displayValue(input.end_arrowhead)]
  ]
  const rows: CompactActionRow[] = []
  if (points.length > 0) rows.push({ label: t("tool_field_points"), value: <PointList points={points} /> })
  const details = fields.filter((field): field is [string, string] => field[1] != null)
  if (color || details.length > 0)
    rows.push({
      label: t("tool_details"),
      value: (
        <>
          {details.map(([label, value]) => (
            <span className="inline-flex min-w-0 items-center gap-1" key={label}>
              <span className="text-text-subtle">{label}:</span>
              <span className="break-all font-mono">{value}</span>
            </span>
          ))}
          {color ? (
            <span className="inline-flex min-w-0 items-center gap-1">
              <span className="text-text-subtle">{t("tool_field_color")}:</span>
              <span aria-label={color} className="h-3 w-3 shrink-0 rounded-full border border-border" style={{ backgroundColor: color }} />
              <span className="break-all font-mono">{color}</span>
            </span>
          ) : null}
        </>
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

const drawLineToolCard: ToolCardRenderer = {
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
    return <LineCard context={context} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "styled_polyline",
    label: "Styled polyline",
    input: {
      x: 12,
      y: 24,
      points: [
        [0, 0],
        [80, 30],
        [140, 10]
      ],
      stroke_width: 3,
      color: "#dc2626",
      start_arrowhead: "dot",
      end_arrowhead: "arrow"
    },
    parsedResult: { result: { id: "line-demo", version: 4 } },
    sourceType: "generic"
  },
  {
    id: "pending",
    label: "Pending result",
    input: {
      points: [
        [0, 0],
        [40, 40]
      ]
    },
    resultBody: "",
    sourceType: "generic"
  },
  {
    id: "element_limit",
    label: "Element limit exceeded",
    input: {
      points: [
        [0, 0],
        [40, 40]
      ]
    },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" },
    resultError: true,
    sourceType: "generic"
  }
]

export default drawLineToolCard
