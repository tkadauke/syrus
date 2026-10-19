import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CompactActionCard } from "@app/routes/chat/compactActionCard"
import { Badge, CardShell, Row, StatePill, displayValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

const ACTION_KEY = "tool_action_drew_embed"

function externalHttpUrl(value: unknown): URL | null {
  if (typeof value !== "string") return null
  try {
    const url = new URL(value)
    return url.protocol === "http:" || url.protocol === "https:" ? url : null
  } catch {
    return null
  }
}

function EmbedLink({ value }: { value: unknown }) {
  const text = displayValue(value)
  if (!text) return <span className="italic text-text-subtle">No link provided</span>
  const url = externalHttpUrl(value)
  if (!url)
    return (
      <span className="min-w-0">
        <span className="break-all font-mono text-danger-text">{text}</span>
        <span className="ml-2 rounded bg-danger/10 px-1.5 py-0.5 text-2xs font-semibold uppercase text-danger-text">Not a safe HTTP(S) URL</span>
      </span>
    )

  return (
    <a className="min-w-0 break-all font-mono text-brand hover:underline" href={url.href} rel="noreferrer noopener" target="_blank">
      {text}
    </a>
  )
}

function EmbedPreview({ link }: { link: unknown }) {
  const url = externalHttpUrl(link)
  if (!url) return null
  const initial = url.hostname.charAt(0).toUpperCase()
  return (
    <div aria-label={`Embed preview for ${url.hostname}`} className="flex min-w-0 items-center gap-3 rounded border border-border bg-surface-subtle px-3 py-2">
      <span aria-hidden="true" className="flex h-8 w-8 shrink-0 items-center justify-center rounded bg-surface font-semibold text-text-secondary">
        {initial}
      </span>
      <span className="min-w-0">
        <span className="block truncate text-xs font-semibold text-text-primary">{url.hostname}</span>
        <span className="block break-all font-mono text-2xs text-text-subtle">{url.href}</span>
      </span>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const action = t(ACTION_KEY)
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
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={action} tone="success" />
        <span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>
        {result.version != null ? <Badge>v{result.version}</Badge> : null}
      </div>
      <EmbedPreview link={input.link} />
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label={t("tool_field_link")} value={<EmbedLink value={input.link} />} />
        {type ? <Row label={t("tool_field_type")} value={type} /> : null}
        <Row label="X" value={displayValue(input.x) ?? "—"} />
        <Row label="Y" value={displayValue(input.y) ?? "—"} />
        <Row label={t("tool_field_width")} value={displayValue(input.width) ?? "—"} />
        <Row label={t("tool_field_height")} value={displayValue(input.height) ?? "—"} />
      </dl>
    </CardShell>
  )
}

const drawEmbedToolCard: ToolCardRenderer = {
  toolName: "draw_embed",
  collapsedSummary(context) {
    const action = t(ACTION_KEY)
    const failureSummary = elementFailureSummary(context, action)
    if (failureSummary) return failureSummary
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
  },
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "web_embed",
    label: "Web embed",
    input: { type: "iframe", link: "https://example.com/a/very/long/embed/path", x: 15, y: 25, width: 400, height: 225 },
    parsedResult: { result: { id: "embed-demo", version: 2 } }
  },
  {
    id: "unsafe_link",
    label: "Unsafe link rejected",
    input: { type: "embeddable", link: "javascript:alert(1)", x: 10, y: 20, width: 300, height: 180 },
    parsedResult: { id: "embed-unsafe", version: 1 }
  },
  {
    id: "failed",
    label: "Failed embed",
    input: { link: "https://example.com", x: 10, y: 20, width: 300, height: 180 },
    parsedResult: { message: "Link could not be embedded" },
    resultError: true
  },
  {
    id: "pending",
    label: "Pending result",
    input: { type: "embeddable", link: "https://example.com", x: 10, y: 20, width: 300, height: 180 },
    resultBody: ""
  }
]

export default drawEmbedToolCard
