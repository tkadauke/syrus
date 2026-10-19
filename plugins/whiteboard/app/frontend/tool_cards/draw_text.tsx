import type { ReactNode } from "react"
import { linkifySlugs } from "@app/lib/linkifySlugs"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CardShell, Badge, displayValue, numberValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

const URL_PATTERN = /https?:\/\/[^\s<]+[^\s<.,;:!?"')\]}]/gi
const SLUG_PATTERN = /[A-Z]{2,}(?:_[A-Z0-9]+)*-\d+/g

function linksIn(text: string): ReactNode[] {
  const references = [...(text.match(URL_PATTERN) ?? []), ...(text.match(SLUG_PATTERN) ?? [])]
  return [...new Set(references)].map((reference) =>
    /^https?:\/\//i.test(reference) ? (
      <a className="break-all text-brand hover:underline" href={reference} key={reference} rel="noreferrer" target="_blank">
        {reference}
      </a>
    ) : (
      <span className="min-w-0" key={reference}>
        {linkifySlugs(reference)}
      </span>
    )
  )
}

function Detail({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className="flex min-w-0 flex-wrap items-center gap-1.5 break-words text-xs text-text-secondary">{children}</div>
    </div>
  )
}

function DrawTextCard({ context }: { context: ToolCardContext }) {
  const action = t("tool_action_drew_text")
  if (context.resultError) return <ElementFailureCard action={action} context={context} />

  const result = parseElementResult(context.parsedResult)
  if (!result)
    return (
      <CardShell>
        <StatePill state={action} tone="info" />
        <Row label={t("tool_status")} value={t(context.parsedResult == null ? "tool_pending" : "tool_missing_result")} />
      </CardShell>
    )

  const input = isPlainObject(context.input) ? context.input : {}
  const content = typeof input.content === "string" ? input.content : ""
  const x = numberValue(input.x)
  const y = numberValue(input.y)
  const fontSize = numberValue(input.font_size)
  const color = displayValue(input.color)
  const links = linksIn(content)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={action} tone="success" />
        <span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>
        {result.version != null ? <Badge>v{result.version}</Badge> : null}
      </div>
      <div className="min-w-0">
        <SectionLabel>{t("tool_field_content")}</SectionLabel>
        {content.trim() ? <TextPreview maxLines={4} modalLabel={t("tool_field_content")} text={content} /> : <span className="text-xs text-text-muted">—</span>}
      </div>
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {x != null ? <Row label="X" value={String(x)} /> : null}
        {y != null ? <Row label="Y" value={String(y)} /> : null}
        {fontSize != null ? <Row label={t("tool_field_font_size")} value={String(fontSize)} /> : null}
        {color ? (
          <Detail label={t("tool_field_color")}>
            <span aria-label={color} className="h-3 w-3 shrink-0 rounded-full border border-border" style={{ backgroundColor: color }} />
            <span className="break-all font-mono">{color}</span>
          </Detail>
        ) : null}
        {links.length > 0 ? (
          <Detail label={t("tool_field_link")}>
            <span className="flex min-w-0 flex-col gap-1">{links}</span>
          </Detail>
        ) : null}
      </dl>
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "formatted_text",
    label: "Literal text with links",
    input: { content: "**Literal** canvas note for JOB-42: https://example.com/details", x: 40, y: 60, font_size: 24, color: "#7c3aed" },
    parsedResult: { result: { id: "text-demo", version: 3 } }
  },
  { id: "empty", label: "Empty result", input: { content: "", x: 0, y: 0 }, parsedResult: {} },
  {
    id: "element_limit",
    label: "Element limit exceeded",
    input: { content: "One more note", x: 10, y: 10 },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" },
    resultError: true
  }
]

const drawTextToolCard: ToolCardRenderer = {
  toolName: "draw_text",
  collapsedSummary(context) {
    const action = t("tool_action_drew_text")
    const failureSummary = elementFailureSummary(context, action)
    if (failureSummary) return failureSummary
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result)
  },
  renderExpanded(context) {
    return <DrawTextCard context={context} />
  }
}

export default drawTextToolCard
