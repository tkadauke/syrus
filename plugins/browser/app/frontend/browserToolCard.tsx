import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

export type BrowserAction = "navigate" | "snapshot" | "screenshot" | "resize" | "wait" | "close"

type BrowserPreview = {
  src: string | null
  label: string
  mimeType: string | null
  byteSize: number | null
  large: boolean
}

export type BrowserCard = {
  action: BrowserAction
  status: string
  errorMessage: string | null
  target: string | null
  url: string | null
  title: string | null
  viewport: string | null
  snapshotLabel: string | null
  preview: BrowserPreview | null
  details: string | null
}

type BrowserObjectPayload = {
  url: string | null
  title: string | null
  viewport: string | null
  status: string | null
  snapshotLabel: string | null
  errorMessage: string | null
  preview: BrowserPreview | null
}

type ActionConfig = {
  action: BrowserAction
  label: string
  targetLabel: string
}

const ACTION_CONFIGS: Record<BrowserAction, ActionConfig> = {
  navigate: { action: "navigate", label: "Navigate", targetLabel: "Target" },
  snapshot: { action: "snapshot", label: "Snapshot", targetLabel: "Target" },
  screenshot: { action: "screenshot", label: "Screenshot", targetLabel: "Target" },
  resize: { action: "resize", label: "Resize", targetLabel: "Viewport" },
  wait: { action: "wait", label: "Wait", targetLabel: "Condition" },
  close: { action: "close", label: "Close browser", targetLabel: "Target" }
}

const MAX_INLINE_IMAGE_DATA_CHARS = 1_500_000

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
    preview: fromObject?.preview || null,
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
      {card.preview ? <BrowserPreviewPanel preview={card.preview} /> : card.action === "screenshot" ? <BrowserPreviewFallback /> : null}
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

function BrowserPreviewPanel({ preview }: { preview: BrowserPreview }) {
  if (!preview.src || preview.large) {
    return <BrowserPreviewFallback detail={preview.large ? "Image payload is too large to preview inline." : "No image preview is available."} />
  }

  return (
    <figure className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <a href={preview.src} rel="noreferrer" target="_blank">
        <img
          alt={preview.label}
          className="max-h-80 w-full bg-white object-contain dark:bg-gray-950"
          loading="lazy"
          src={preview.src}
        />
      </a>
      <figcaption className="flex flex-wrap gap-2 border-t border-gray-200 px-2 py-1 text-2xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
        <span>{preview.label}</span>
        {preview.mimeType ? <span>{preview.mimeType}</span> : null}
        {preview.byteSize != null ? <span>{formatBytes(preview.byteSize)}</span> : null}
      </figcaption>
    </figure>
  )
}

function BrowserPreviewFallback({ detail = "No image preview is available." }: { detail?: string }) {
  return (
    <div className="rounded border border-dashed border-gray-300 bg-white px-3 py-4 text-center text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-400">
      {detail}
    </div>
  )
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
  if (action === "screenshot") return displayValue(input.element) || displayValue(input.target) || displayValue(input.ref)
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
  if (Array.isArray(value)) {
    const imageFromContent = imagePreviewFromContent(value)
    if (!imageFromContent) return null

    return { url: null, title: null, viewport: null, status: "success", snapshotLabel: imageFromContent.label, errorMessage: null, preview: imageFromContent }
  }

  if (!isPlainObject(value)) return null

  const url = displayValue(value.url) || displayValue(value.current_url) || displayValue(value.page_url)
  const title = displayValue(value.title) || displayValue(value.page_title)
  const viewport = viewportValue(value.viewport) || viewportValue(value)
  const status = statusValue(value)
  const snapshotLabel = snapshotLabelValue(value)
  const errorMessage = displayValue(value.error) || displayValue(value.message)
  const preview = imagePreviewFromContent(value) || imagePreviewFromObject(value)
  const effectiveSnapshotLabel = snapshotLabel || preview?.label || null

  if (!url && !title && !viewport && !status && !effectiveSnapshotLabel && !errorMessage && !preview) return null

  return { url, title, viewport, status, snapshotLabel: effectiveSnapshotLabel, errorMessage, preview }
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

function imagePreviewFromContent(value: unknown): BrowserPreview | null {
  const content = Array.isArray(value)
    ? value
    : isPlainObject(value) && Array.isArray(value.content)
      ? value.content
      : null
  if (!content) return null

  for (const block of content) {
    if (!isPlainObject(block)) continue

    const direct = imagePreviewFromObject(block)
    if (direct) return direct
  }

  return null
}

function imagePreviewFromObject(value: Record<string, unknown>): BrowserPreview | null {
  const imageUrl = displayValue(value.image_url) || displayValue(value.file_path) || displayValue(value.artifact_url) || displayValue(value.src)
  const mimeType = displayValue(value.mimeType) || displayValue(value.mime_type) || displayValue(value.content_type)
  const title = displayValue(value.title) || displayValue(value.filename) || "Browser screenshot"
  const byteSize = numberValue(value.byte_size) || numberValue(value.bytes)

  if (imageUrl) return { src: imageUrl, label: title, mimeType, byteSize, large: false }

  const data = displayValue(value.data) || displayValue(value.image_base64) || displayValue(value.base64)
  if (!data) return null

  const large = data.length > MAX_INLINE_IMAGE_DATA_CHARS
  return {
    src: large ? null : imageDataUrl(data, mimeType),
    label: title,
    mimeType: mimeType || "image/png",
    byteSize: byteSize || estimatedBase64Bytes(data),
    large
  }
}

function imageDataUrl(data: string, mimeType: string | null) {
  if (data.startsWith("data:")) return data
  return `data:${mimeType || "image/png"};base64,${data}`
}

function estimatedBase64Bytes(data: string) {
  const clean = data.replace(/^data:[^,]+,/, "").replace(/\s/g, "")
  if (!clean) return null
  return Math.floor(clean.length * 0.75)
}

function formatBytes(bytes: number) {
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`
  if (bytes >= 1_000) return `${Math.round(bytes / 1_000)} KB`
  return `${bytes} B`
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
