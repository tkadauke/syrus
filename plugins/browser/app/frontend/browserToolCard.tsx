import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

export type BrowserAction = "navigate" | "snapshot" | "resize" | "wait" | "close"

export type BrowserCard = {
  action: BrowserAction
  status: string
  errorMessage: string | null
  target: string | null
  url: string | null
  title: string | null
  viewport: string | null
  snapshotLabel: string | null
  details: string | null
}

type BrowserObjectPayload = {
  url: string | null
  title: string | null
  viewport: string | null
  status: string | null
  snapshotLabel: string | null
  errorMessage: string | null
}

type ActionConfig = {
  action: BrowserAction
  label: string
  targetLabel: string
}

const ACTION_CONFIGS: Record<BrowserAction, ActionConfig> = {
  navigate: { action: "navigate", label: "Navigate", targetLabel: "Target" },
  snapshot: { action: "snapshot", label: "Snapshot", targetLabel: "Target" },
  resize: { action: "resize", label: "Resize", targetLabel: "Viewport" },
  wait: { action: "wait", label: "Wait", targetLabel: "Condition" },
  close: { action: "close", label: "Close browser", targetLabel: "Target" }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

export function parseBrowserCard(context: ToolCardContext, action: BrowserAction): BrowserCard | null {
  const target = actionTarget(context, action)
  const fromObject = parseObjectPayload(context.parsedResult)
  const fromText = parseTextPayload(context.resultBody)
  const errorMessage = context.resultError ? browserErrorMessage(context.resultBody, fromObject) : fromObject?.errorMessage || null

  if (!context.resultError && !target && !fromObject && !hasTextPayloadSignal(fromText)) return null

  return {
    action,
    status: context.resultError ? "error" : fromObject?.status || "success",
    errorMessage,
    target,
    url: fromObject?.url || fromText.url,
    title: fromObject?.title || fromText.title,
    viewport: fromObject?.viewport || fromText.viewport || (action === "resize" ? target : null),
    snapshotLabel: fromObject?.snapshotLabel || fromText.snapshotLabel,
    details: context.resultBody.trim() ? context.resultBody : null
  }
}

export function browserCardSummary(card: BrowserCard) {
  const config = ACTION_CONFIGS[card.action]
  const subject = card.target ? `${config.label} ${card.target}` : config.label
  const identity = pageIdentity(card)
  const suffix = card.status === "error" ? "failed" : card.status
  return [subject, identity, suffix].filter(Boolean).join(" · ")
}

export function BrowserCardBody({ card }: { card: BrowserCard }) {
  const config = ACTION_CONFIGS[card.action]

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{config.label}</Badge>
        <StatePill state={card.status} />
      </div>
      {card.errorMessage ? <div className="text-red-600 dark:text-red-300">{card.errorMessage}</div> : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        {card.target && card.action !== "resize" ? <Row label={config.targetLabel} value={card.target} /> : null}
        {card.title ? <Row label="Title" value={card.title} /> : null}
        {card.url ? <Row label="Current URL" value={card.url} /> : null}
        {card.viewport ? <Row label="Viewport" value={card.viewport} /> : null}
        {card.snapshotLabel ? <Row label="Snapshot" value={card.snapshotLabel} /> : null}
      </dl>
      {card.details ? (
        <Disclosure label="Browser details">
          <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">{card.details}</pre>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

export function browserCardRenderer(action: BrowserAction) {
  return {
    collapsedSummary(context: ToolCardContext) {
      const card = parseBrowserCard(context, action)
      return card ? browserCardSummary(card) : null
    },
    renderExpanded(context: ToolCardContext) {
      const card = parseBrowserCard(context, action)
      return card ? <BrowserCardBody card={card} /> : null
    }
  }
}

function actionTarget(context: ToolCardContext, action: BrowserAction) {
  const input = isPlainObject(context.input) ? context.input : {}

  if (action === "navigate") return displayValue(input.url)
  if (action === "resize") {
    const width = numberValue(input.width)
    const height = numberValue(input.height)
    return width != null && height != null ? `${width}x${height}` : null
  }
  if (action === "wait") return waitTarget(input)
  return null
}

function waitTarget(input: Record<string, unknown>) {
  const text = displayValue(input.text)
  if (text) return `for "${text}"`

  const textGone = displayValue(input.text_gone) || displayValue(input.textGone)
  if (textGone) return `until "${textGone}" disappears`

  const time = numberValue(input.time)
  return time != null ? `for ${time}s` : null
}

function parseObjectPayload(value: unknown) {
  if (!isPlainObject(value)) return null

  const url = displayValue(value.url) || displayValue(value.current_url) || displayValue(value.page_url)
  const title = displayValue(value.title) || displayValue(value.page_title)
  const viewport = viewportValue(value.viewport) || viewportValue(value)
  const status = statusValue(value)
  const snapshotLabel = snapshotLabelValue(value)
  const errorMessage = displayValue(value.error) || displayValue(value.message)

  if (!url && !title && !viewport && !status && !snapshotLabel && !errorMessage) return null

  return { url, title, viewport, status, snapshotLabel, errorMessage }
}

function viewportValue(value: unknown) {
  if (!isPlainObject(value)) return null

  const width = numberValue(value.width) ?? numberValue(value.viewport_width)
  const height = numberValue(value.height) ?? numberValue(value.viewport_height)
  return width != null && height != null ? `${width}x${height}` : null
}

function statusValue(value: Record<string, unknown>) {
  const status = displayValue(value.status) || displayValue(value.state)
  if (status) return status
  if (value.success === true || value.ok === true || value.closed === true) return "success"
  if (value.success === false || value.ok === false || value.error) return "error"
  return null
}

function snapshotLabelValue(value: Record<string, unknown>) {
  const direct = displayValue(value.snapshot_id) || displayValue(value.snapshot)
  if (direct) return direct

  const metadata = isPlainObject(value.metadata) ? value.metadata : isPlainObject(value.snapshot_metadata) ? value.snapshot_metadata : null
  if (!metadata) return null

  const nodes = numberValue(metadata.node_count) || numberValue(metadata.nodes)
  const elements = numberValue(metadata.element_count) || numberValue(metadata.elements)
  if (nodes != null) return `${nodes} node${nodes === 1 ? "" : "s"}`
  if (elements != null) return `${elements} element${elements === 1 ? "" : "s"}`
  return displayValue(metadata.label)
}

function parseTextPayload(body: string) {
  const text = body.trim()
  if (!text) return { url: null, title: null, viewport: null, snapshotLabel: null }

  const url = lineValue(text, /(?:Page URL|Current URL|URL):\s*(.+)/i)
  const title = lineValue(text, /(?:Page Title|Title):\s*(.+)/i)
  const viewport = lineValue(text, /(?:Viewport):\s*(.+)/i) || viewportFromText(text)
  const snapshotLabel = text.match(/Page Snapshot|accessibility[- ]tree|aria snapshot/i) ? "accessibility tree" : null

  return { url, title, viewport, snapshotLabel }
}

function hasTextPayloadSignal(payload: ReturnType<typeof parseTextPayload>) {
  return !!(payload.url || payload.title || payload.viewport || payload.snapshotLabel)
}

function lineValue(text: string, pattern: RegExp) {
  const match = text.match(pattern)
  return displayValue(match?.[1])
}

function viewportFromText(text: string) {
  const match = text.match(/\b(\d{2,5})\s*[xX]\s*(\d{2,5})\b/)
  return match ? `${match[1]}x${match[2]}` : null
}

function browserErrorMessage(body: string, parsed: BrowserObjectPayload | null) {
  if (parsed?.errorMessage) return parsed.errorMessage
  const text = body.trim()
  if (!text) return "Browser tool failed."
  return text.replace(/^Error:\s*/i, "")
}

function pageIdentity(card: BrowserCard) {
  if (card.title && card.url) return `${card.title} (${card.url})`
  return card.title || card.url || card.snapshotLabel
}
