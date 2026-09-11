import type { ToolCardContext } from "@app/pluginToolCards"
import { MediaPreviewShell } from "@app/routes/chat/mediaPreviewShell"
import { Badge, CardShell, Disclosure, displayValue, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

export type BrowserAction =
  | "navigate"
  | "snapshot"
  | "screenshot"
  | "resize"
  | "wait"
  | "close"
  | "click"
  | "fill"
  | "evaluate"
  | "hover"
  | "drag"
  | "drop"
  | "file_upload"

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
  resultSummary: string | null
  resultDetails: string | null
  inputTextSummary: string | null
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
  close: { action: "close", label: "Close browser", targetLabel: "Target" },
  click: { action: "click", label: "Click", targetLabel: "Target" },
  fill: { action: "fill", label: "Fill", targetLabel: "Target" },
  evaluate: { action: "evaluate", label: "Evaluate", targetLabel: "Target" },
  hover: { action: "hover", label: "Hover", targetLabel: "Target" },
  drag: { action: "drag", label: "Drag", targetLabel: "Path" },
  drop: { action: "drop", label: "Drop", targetLabel: "Target" },
  file_upload: { action: "file_upload", label: "File upload", targetLabel: "Files" }
}

const MAX_INLINE_IMAGE_DATA_CHARS = 1_500_000

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

export function parseBrowserCard(context: ToolCardContext, action: BrowserAction): BrowserCard | null {
  const target = actionTarget(context, action)
  const fromObject = parseObjectPayload(context.parsedResult)
  const fromText = parseTextPayload(context.resultBody)
  const result = action === "evaluate" ? evaluateResult(context.parsedResult, context.resultBody, fromObject) : null
  const errorMessage = context.resultError ? browserErrorMessage(context.resultBody, fromObject) : fromObject?.errorMessage || null

  if (!context.resultError && !target && !fromObject && !hasTextPayloadSignal(fromText) && !result) return null

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
    resultSummary: result?.summary || null,
    resultDetails: result?.details || null,
    inputTextSummary: action === "fill" ? inputTextSummary(context.input) : null,
    details: context.resultBody.trim() ? context.resultBody : null
  }
}

export function browserCardSummary(card: BrowserCard) {
  const config = ACTION_CONFIGS[card.action]
  const subject = card.target ? `${config.label} ${card.target}` : config.label
  const identity = card.action === "evaluate" ? card.resultSummary || pageIdentity(card) : pageIdentity(card)
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
        {card.inputTextSummary ? <Row label="Text" value={card.inputTextSummary} /> : null}
      </dl>
      {card.resultSummary ? <BrowserResultPanel summary={card.resultSummary} details={card.resultDetails} /> : null}
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
    <MediaPreviewShell
      item={{
        title: preview.label,
        subtitle: [preview.mimeType, preview.byteSize != null ? formatBytes(preview.byteSize) : null].filter(Boolean).join(" · "),
        src: preview.src,
        alt: preview.label,
        badge: preview.mimeType?.split("/").pop()?.toUpperCase() ?? null,
        actions: [
          { label: "Open", href: preview.src },
          { label: "Copy link", copyValue: preview.src }
        ],
        meta: [
          { label: "Label", value: preview.label },
          { label: "Type", value: preview.mimeType },
          { label: "Size", value: preview.byteSize != null ? formatBytes(preview.byteSize) : null },
          { label: "Source", value: preview.src, copyValue: preview.src }
        ]
      }}
      modalLabel={preview.label}
      thumbnailClassName="w-full"
    />
  )
}

function BrowserResultPanel({ summary, details }: { summary: string; details: string | null }) {
  return (
    <div className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Result</div>
      <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-xs text-gray-700 dark:text-gray-300">{summary}</pre>
      {details && details !== summary ? (
        <Disclosure label="Full result">
          <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">{details}</pre>
        </Disclosure>
      ) : null}
    </div>
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
  if (["click", "fill", "hover", "drop"].includes(action)) return displayValue(input.element) || displayValue(input.target) || displayValue(input.ref)
  if (action === "evaluate") return displayValue(input.element) || displayValue(input.target) || displayValue(input.ref) || (displayValue(input.function) ? "page" : null)
  if (action === "drag") return dragTarget(input)
  if (action === "file_upload") return fileUploadTarget(input)
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

function dragTarget(input: Record<string, unknown>) {
  const start = displayValue(input.start_element) || displayValue(input.startElement) || displayValue(input.start_target) || displayValue(input.startTarget)
  const end = displayValue(input.end_element) || displayValue(input.endElement) || displayValue(input.end_target) || displayValue(input.endTarget)
  if (start && end) return `${start} -> ${end}`
  return start || end
}

function fileUploadTarget(input: Record<string, unknown>) {
  if (!Array.isArray(input.paths)) return "cancel chooser"
  const count = input.paths.length
  if (count === 0) return "cancel chooser"
  return `${count} file${count === 1 ? "" : "s"}`
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
  const snapshotLabel = text.match(/(?:^|\n)\s*-?\s*(?:Page Snapshot|accessibility[- ]tree|aria snapshot)\s*:/i) ? "accessibility tree" : null

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

function evaluateResult(value: unknown, body: string, parsedObject: BrowserObjectPayload | null) {
  const extracted = evaluationValue(value, parsedObject)
  if (extracted !== undefined) return resultPreview(extracted)

  const text = body.trim()
  if (!text || parsedObject) return null
  return { summary: truncateText(text, 120), details: text }
}

function evaluationValue(value: unknown, parsedObject: BrowserObjectPayload | null) {
  if (!isPlainObject(value)) return value == null ? undefined : value

  for (const key of ["result", "value", "evaluation_result", "return_value"]) {
    if (key in value) return value[key]
  }

  if (parsedObject) return undefined
  return value
}

function resultPreview(value: unknown) {
  if (isScalar(value)) {
    const summary = scalarSummary(value)
    return { summary, details: summary }
  }

  if (Array.isArray(value)) {
    return { summary: `Array(${value.length})`, details: prettyJson(value) }
  }

  if (isPlainObject(value)) {
    return { summary: objectSummary(value), details: prettyJson(value) }
  }

  const summary = truncateText(String(value), 120)
  return { summary, details: summary }
}

function scalarSummary(value: string | number | boolean | null) {
  if (typeof value === "string") return `"${truncateText(value, 100)}"`
  if (value === null) return "null"
  return String(value)
}

function isScalar(value: unknown): value is string | number | boolean | null {
  return value == null || typeof value === "boolean" || typeof value === "number" || typeof value === "string"
}

function objectSummary(value: Record<string, unknown>) {
  const entries = Object.entries(value)
  const scalars = entries.filter((entry): entry is [string, string | number | boolean | null] => isScalar(entry[1])).slice(0, 3)
  if (scalars.length === 0) return `Object(${entries.length} key${entries.length === 1 ? "" : "s"})`

  const preview = scalars.map(([key, entryValue]) => `${key}: ${scalarSummary(entryValue)}`).join(", ")
  const suffix = entries.length > scalars.length ? ", ..." : ""
  return `{ ${preview}${suffix} }`
}

function prettyJson(value: unknown) {
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function truncateText(value: string, max: number) {
  return value.length > max ? `${value.slice(0, max - 1)}...` : value
}

function inputTextSummary(inputValue: unknown) {
  const input = isPlainObject(inputValue) ? inputValue : null
  const text = input ? displayValue(input.text) : null
  return text ? `${text.length} character${text.length === 1 ? "" : "s"}` : null
}
