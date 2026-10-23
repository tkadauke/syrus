import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

function safeExternalUrl(value: string | null) {
  if (!value) return null
  try {
    const url = new URL(value)
    return url.protocol === "http:" || url.protocol === "https:" ? url : null
  } catch {
    return null
  }
}

function coordinate(input: Record<string, unknown>, key: string) {
  return displayValue(input[key]) ?? "—"
}

function EmbedLink({ link }: { link: string }) {
  const url = safeExternalUrl(link)
  if (!url)
    return (
      <div aria-invalid="true" className="min-w-0 rounded border border-danger/30 bg-danger/10 px-2 py-1.5">
        <div aria-hidden="true" className="text-xs text-danger-text">
          ⚠
        </div>
        <div className="break-all font-mono text-xs text-text-secondary">{link}</div>
      </div>
    )

  return (
    <a
      aria-label={link}
      className="flex min-w-0 items-center gap-2 rounded border border-border bg-surface-muted px-2 py-1.5 text-brand hover:underline"
      href={url.href}
      rel="noreferrer noopener"
      target="_blank"
    >
      <span aria-hidden="true" className="flex h-5 w-5 shrink-0 items-center justify-center rounded bg-surface font-semibold uppercase text-text-subtle">
        {url.hostname.charAt(0)}
      </span>
      <span className="min-w-0">
        <span className="block text-2xs text-text-subtle">{url.hostname}</span>
        <span className="block break-all font-mono text-xs">{link}</span>
      </span>
    </a>
  )
}

function EmbedCard({ context }: { context: ToolCardContext }) {
  const action = t("tool_action_drew_embed")
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
  const link = displayValue(input.link)
  const type = displayValue(input.type)
  const rows: CompactActionRow[] = [
    ...(link ? [{ label: t("tool_field_link"), value: <EmbedLink link={link} /> }] : []),
    ...(type ? [{ label: t("tool_field_type"), value: <span className="font-mono">{type}</span> }] : []),
    {
      label: "X / Y",
      value: (
        <span className="break-all font-mono">
          {coordinate(input, "x")} / {coordinate(input, "y")}
        </span>
      )
    },
    {
      label: `${t("tool_field_width")} / ${t("tool_field_height")}`,
      value: (
        <span className="break-all font-mono">
          {coordinate(input, "width")} × {coordinate(input, "height")}
        </span>
      )
    }
  ]

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

const drawEmbedToolCard: ToolCardRenderer = {
  toolName: "draw_embed",
  collapsedSummary(context) {
    const action = t("tool_action_drew_embed")
    const failureSummary = elementFailureSummary(context, action)
    if (failureSummary) return failureSummary
    const result = parseElementResult(context.parsedResult)
    if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
    return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
  },
  renderExpanded(context) {
    return <EmbedCard context={context} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "web_embed",
    label: "Web embed",
    input: { type: "iframe", link: "https://example.com/a/very/long/embed/path?layout=wide", x: 15, y: 25, width: 400, height: 225 },
    parsedResult: { result: { id: "embed-demo", version: 3 } }
  },
  {
    id: "unsafe_url",
    label: "Unsupported URL",
    input: { type: "embeddable", link: "javascript:alert(1)", x: 10, y: 20, width: 300, height: 180 },
    parsedResult: { id: "embed-unsafe", version: 1 }
  },
  { id: "pending", label: "Pending result", input: { link: "https://example.com", x: 10, y: 20, width: 300, height: 180 }, resultBody: "" },
  {
    id: "failure",
    label: "Failed embed",
    input: { link: "https://example.com", x: 10, y: 20, width: 300, height: 180 },
    parsedResult: { message: "width must be positive", retryable: false },
    resultError: true
  }
]

export default drawEmbedToolCard
