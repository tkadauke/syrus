import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

const PREVIEW_POINT_LIMIT = 128
const PREVIEW_WIDTH = 160
const PREVIEW_HEIGHT = 64
const PREVIEW_PADDING = 6
type Point = [number, number]

function point(value: unknown): Point | null {
  if (
    Array.isArray(value) &&
    value.length >= 2 &&
    typeof value[0] === "number" &&
    Number.isFinite(value[0]) &&
    typeof value[1] === "number" &&
    Number.isFinite(value[1])
  )
    return [value[0], value[1]]
  if (isPlainObject(value) && typeof value.x === "number" && Number.isFinite(value.x) && typeof value.y === "number" && Number.isFinite(value.y))
    return [value.x, value.y]
  return null
}

function previewPoints(value: unknown): Point[] {
  if (!Array.isArray(value)) return []
  const valid = value.flatMap((candidate) => {
    const parsed = point(candidate)
    return parsed ? [parsed] : []
  })
  if (valid.length <= PREVIEW_POINT_LIMIT) return valid
  return Array.from({ length: PREVIEW_POINT_LIMIT }, (_, index) => valid[Math.round((index * (valid.length - 1)) / (PREVIEW_POINT_LIMIT - 1))])
}

function previewPath(points: Point[]): string {
  if (points.length === 0) return ""
  const xs = points.map(([x]) => x)
  const ys = points.map(([, y]) => y)
  const minX = Math.min(...xs)
  const maxX = Math.max(...xs)
  const minY = Math.min(...ys)
  const maxY = Math.max(...ys)
  const rangeX = maxX - minX
  const rangeY = maxY - minY
  const scale = Math.min((PREVIEW_WIDTH - PREVIEW_PADDING * 2) / Math.max(rangeX, 1), (PREVIEW_HEIGHT - PREVIEW_PADDING * 2) / Math.max(rangeY, 1))
  const offsetX = (PREVIEW_WIDTH - rangeX * scale) / 2
  const offsetY = (PREVIEW_HEIGHT - rangeY * scale) / 2
  return points
    .map(([x, y], index) => `${index === 0 ? "M" : "L"}${(offsetX + (x - minX) * scale).toFixed(1)} ${(offsetY + (y - minY) * scale).toFixed(1)}`)
    .join(" ")
}

function displayList(value: unknown): string | null {
  return Array.isArray(value) && value.length > 0 ? value.map(String).join(", ") : null
}

function FreeDrawPreview({ points, color, strokeWidth }: { points: Point[]; color: string | null; strokeWidth: string | null }) {
  const path = previewPath(points)
  if (!path) return null
  return (
    <svg
      aria-label="Freehand path preview"
      className="h-16 w-full max-w-64 rounded border border-border bg-surface-subtle"
      data-preview-point-count={points.length}
      role="img"
      viewBox={`0 0 ${PREVIEW_WIDTH} ${PREVIEW_HEIGHT}`}
    >
      <path
        d={path}
        fill="none"
        stroke={color ?? "currentColor"}
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={strokeWidth ?? "2"}
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  )
}

function FreedrawCard({ context }: { context: ToolCardContext }) {
  const action = t("tool_action_drew_freehand_path")
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
  const points = previewPoints(input.points)
  const pointCount = Array.isArray(input.points) ? input.points.length : 0
  const x = displayValue(input.x)
  const y = displayValue(input.y)
  const pressures = displayList(input.pressures)
  const simulatePressure = typeof input.simulate_pressure === "boolean" ? t(input.simulate_pressure ? "tool_yes" : "tool_no") : null
  const strokeWidth = displayValue(input.stroke_width)
  const color = displayValue(input.color)
  const rows: CompactActionRow[] = [
    {
      label: t("tool_details"),
      value: (
        <div className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
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
    },
    {
      label: t("tool_field_points"),
      value: (
        <div className="flex min-w-0 flex-col gap-2">
          <span>{t("tool_points_count", { count: pointCount })}</span>
          <FreeDrawPreview color={color} points={points} strokeWidth={strokeWidth} />
        </div>
      )
    }
  ]
  if (pressures || simulatePressure)
    rows.push({
      label: t("tool_field_pressures"),
      value: (
        <div className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
          {pressures ? <span className="break-all font-mono">{pressures}</span> : null}
          {simulatePressure ? (
            <span>
              {t("tool_field_simulate_pressure")}: <span>{simulatePressure}</span>
            </span>
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

export const examples: ToolCardExample[] = [
  {
    id: "pressure_stroke",
    label: "Pressure-sensitive stroke",
    input: {
      x: 20,
      y: 30,
      points: [
        [0, 0],
        [25, 18],
        [50, 4],
        [80, 30]
      ],
      pressures: [0.2, 0.7, 0.4, 0.9],
      simulate_pressure: false,
      stroke_width: 3,
      color: "#b6492e"
    },
    parsedResult: { id: "freedraw-demo", version: 2 },
    sourceType: "generic"
  },
  { id: "pending", label: "Pending result", input: { x: 0, y: 0, points: [] }, resultBody: "", sourceType: "generic" },
  {
    id: "element_limit",
    label: "Element limit exceeded",
    input: {
      x: 0,
      y: 0,
      points: [
        [0, 0],
        [10, 10]
      ]
    },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" },
    resultError: true,
    sourceType: "generic"
  }
]

const renderer: ToolCardRenderer = {
  toolName: "draw_freedraw",
  collapsedSummary(context) {
    const action = t("tool_action_drew_freehand_path")
    const failureSummary = elementFailureSummary(context, action)
    if (failureSummary) return failureSummary
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
  },
  renderExpanded(context) {
    return <FreedrawCard context={context} />
  }
}

export default renderer
