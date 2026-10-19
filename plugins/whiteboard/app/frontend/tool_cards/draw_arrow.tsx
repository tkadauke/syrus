import { CopyableSlug } from "@app/components/CopyableSlug"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue, numberValue } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"
import { ElementFailureCard, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

const ACTION_KEY = "tool_action_drew_arrow"

function inputFor(context: ToolCardContext) {
  return isPlainObject(context.input) ? context.input : {}
}

function endpointSummary(input: Record<string, unknown>) {
  const from = displayValue(input.from_id)
  const to = displayValue(input.to_id)
  return from && to ? `${from} → ${to}` : null
}

function CopyableElementId({ id }: { id: string }) {
  return <CopyableSlug className="max-w-full text-xs" slug={id} />
}

function ArrowCard({ context }: { context: ToolCardContext }) {
  const result = parseElementResult(context.parsedResult)
  if (!result) {
    return (
      <CompactActionCard
        action={t(ACTION_KEY)}
        rows={[{ label: t("tool_status"), value: t(context.parsedResult == null ? "tool_pending" : "tool_missing_result") }]}
        tone="info"
      />
    )
  }

  const input = inputFor(context)
  const from = displayValue(input.from_id)
  const to = displayValue(input.to_id)
  const label = displayValue(input.label)
  const color = displayValue(input.color)
  const strokeWidth = numberValue(input.stroke_width)
  const startArrowhead = displayValue(input.start_arrowhead)
  const endArrowhead = displayValue(input.end_arrowhead)
  const rows: CompactActionRow[] = []

  if (from || to) {
    rows.push({
      label: `${t("tool_field_from")} → ${t("tool_field_to")}`,
      value: (
        <div className="flex min-w-0 max-w-full flex-wrap items-center gap-1 sm:flex-nowrap">
          {from ? <CopyableElementId id={from} /> : <span>—</span>}
          <span aria-hidden="true" className="shrink-0 text-text-subtle">
            →
          </span>
          {to ? <CopyableElementId id={to} /> : <span>—</span>}
        </div>
      )
    })
  }
  if (label) rows.push({ label: t("tool_field_label"), value: <span className="break-words">{label}</span> })
  if (color || strokeWidth != null || startArrowhead || endArrowhead) {
    rows.push({
      label: t("tool_details"),
      value: (
        <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
          {color ? (
            <span className="inline-flex min-w-0 items-center gap-1">
              <span aria-label={color} className="h-3 w-3 shrink-0 rounded-full border border-border" style={{ backgroundColor: color }} />
              <span className="break-all font-mono">{color}</span>
            </span>
          ) : null}
          {strokeWidth != null ? (
            <span>
              {t("tool_field_stroke_width")}: {strokeWidth}
            </span>
          ) : null}
          {startArrowhead ? (
            <span>
              {t("tool_field_start_arrowhead")}: {startArrowhead}
            </span>
          ) : null}
          {endArrowhead ? (
            <span>
              {t("tool_field_end_arrowhead")}: {endArrowhead}
            </span>
          ) : null}
        </div>
      )
    })
  }
  if (result.labelId) rows.push({ label: t("tool_field_label_id"), value: <CopyableElementId id={result.labelId} /> })

  return (
    <CompactActionCard
      action={t(ACTION_KEY)}
      badges={result.version != null ? [`v${result.version}`] : []}
      entity={<CopyableElementId id={result.id} />}
      rows={rows}
      tone="success"
    />
  )
}

const drawArrowToolCard: ToolCardRenderer = {
  toolName: "draw_arrow",
  collapsedSummary(context) {
    const action = t(ACTION_KEY)
    const failure = elementFailureSummary(context, action)
    if (failure) return failure
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    const endpoints = endpointSummary(inputFor(context))
    return `${action}${endpoints ? ` ${endpoints}` : ""} · ${result.id}`
  },
  renderExpanded(context) {
    const action = t(ACTION_KEY)
    if (context.resultError) return <ElementFailureCard action={action} context={context} />
    return <ArrowCard context={context} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "bound_labeled_arrow",
    label: "Bound labeled arrow",
    input: {
      from_id: "shape-start",
      to_id: "shape-finish",
      label: "Ready for review",
      start_arrowhead: "dot",
      end_arrowhead: "arrow",
      color: "#b6492e",
      stroke_width: 3
    },
    parsedResult: { result: { id: "arrow-demo", label_id: "label-demo", version: 4 } },
    sourceType: "generic"
  },
  {
    id: "unknown_endpoint",
    label: "Unknown endpoint",
    input: { from_id: "missing-shape", to_id: "shape-finish" },
    parsedResult: { message: "element missing-shape not found", retryable: false },
    resultError: true,
    sourceType: "generic"
  },
  { id: "pending", label: "Pending result", input: { from_id: "shape-start", to_id: "shape-finish" }, resultBody: "", sourceType: "generic" }
]

export default drawArrowToolCard
