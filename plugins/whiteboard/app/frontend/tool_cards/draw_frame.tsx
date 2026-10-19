import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { makeElementCard, parseElementResult, t } from "../whiteboardToolCard"

export const examples: ToolCardExample[] = [
  {
    id: "named_frame",
    label: "Named frame with children",
    input: { type: "frame", x: 24, y: 40, width: 640, height: 360, name: "System overview", element_ids: ["service-a", "service-b"] },
    parsedResult: { id: "frame-overview", version: 7 },
    sourceType: "generic"
  },
  {
    id: "wrapped_result",
    label: "Wrapped MCP result",
    input: { type: "magicframe", x: 0, y: 0, width: 400, height: 300, name: "Plan" },
    parsedResult: { result: { id: "frame-plan", version: 3 } },
    sourceType: "generic"
  },
  {
    id: "element_limit",
    label: "Element limit exceeded",
    input: { type: "frame", x: 0, y: 0, width: 400, height: 300, name: "Plan" },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" },
    resultError: true,
    sourceType: "generic"
  },
  {
    id: "pending",
    label: "Pending result",
    input: { type: "frame", x: 0, y: 0, width: 400, height: 300 },
    resultBody: "",
    sourceType: "generic"
  }
]

const baseCard = makeElementCard("draw_frame", "tool_action_drew_frame")

function listValue(value: unknown): string | null {
  if (!Array.isArray(value) || value.length === 0) return null
  const values = value.flatMap((item) => {
    const direct = displayValue(item)
    if (direct) return [direct]
    if (isPlainObject(item)) {
      const id = displayValue(item.id)
      if (id) return [id]
    }
    return []
  })
  return values.length > 0 ? values.join(", ") : null
}

function FrameCard({ context }: { context: ToolCardContext }) {
  const result = parseElementResult(context.parsedResult)
  const input = isPlainObject(context.input) ? context.input : {}
  if (!result) return baseCard.renderExpanded(context)

  const name = displayValue(input.name)
  const type = displayValue(input.type)
  const bounds = [
    ["X", displayValue(input.x)],
    ["Y", displayValue(input.y)],
    [t("tool_field_width"), displayValue(input.width)],
    [t("tool_field_height"), displayValue(input.height)]
  ].filter((entry): entry is [string, string] => entry[1] != null)
  const elementIds = listValue(input.element_ids)
  const children = listValue(input.children)
  const rows: CompactActionRow[] = []

  if (name) rows.push({ label: t("tool_field_name"), value: <span className="break-words font-medium text-text-primary">{name}</span> })
  if (bounds.length > 0)
    rows.push({
      label: t("tool_details"),
      value: (
        <span className="flex min-w-0 flex-wrap gap-x-3 gap-y-1 font-mono">
          {bounds.map(([label, value]) => (
            <span className="whitespace-nowrap" key={label}>
              <span className="text-text-subtle">{label}:</span> {value}
            </span>
          ))}
        </span>
      )
    })
  if (elementIds || children)
    rows.push({
      label: t("tool_elements"),
      value: (
        <span className="flex min-w-0 flex-wrap gap-x-3 gap-y-1 font-mono">
          {elementIds ? <span className="break-all">{elementIds}</span> : null}
          {children ? <span className="break-all">{children}</span> : null}
        </span>
      )
    })

  return (
    <CompactActionCard
      action={t("tool_action_drew_frame")}
      badges={[type, result.version != null ? `v${result.version}` : null].filter((badge): badge is string => badge != null)}
      entity={<span className="min-w-0 break-all font-mono font-semibold text-text-primary">{result.id}</span>}
      rows={rows}
      tone="success"
    />
  )
}

const drawFrameToolCard: ToolCardRenderer = {
  ...baseCard,
  renderExpanded(context) {
    if (context.resultError) return baseCard.renderExpanded(context)
    return <FrameCard context={context} />
  }
}

export default drawFrameToolCard
