import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction, type MediaPreviewMeta } from "@app/routes/chat/mediaPreviewShell"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import {
  Badge,
  CardShell,
  displayValue,
  EmptyState,
  EntityReference,
  InternalLink,
  numberValue,
  Row,
  SectionLabel,
  StatePill
} from "@app/routes/chat/toolCardUi"

type FrameImage = {
  src: string
  mimeType: string
  label: string
}

type ArtifactLink = {
  label: string
  href: string
}

type WalkthroughFrameCard = {
  status: "pending" | "success" | "error" | "missing"
  walkthroughId: string | null
  walkthroughName: string | null
  timestamp: string | null
  range: string | null
  frameIndex: string | null
  image: FrameImage | null
  transcript: string | null
  context: string | null
  links: ArtifactLink[]
  message: string | null
}

type FrameInstruction = {
  walkthroughId: string | null
  timestamp: string | null
}

const FRAME_INSTRUCTION_PATTERN = /^Screenshot from walkthrough #(\d+) at (\d+:\d{2})\.(?:\s|$)/
const ERROR_NOTICE_CLASS = [
  "break-words rounded-[var(--radius-panel)] border border-danger/30 bg-danger/10 px-3 py-2",
  "text-sm text-danger-text [overflow-wrap:anywhere]"
].join(" ")

const EXAMPLE_FRAME_IMAGE = [
  "data:image/svg+xml;utf8,",
  encodeURIComponent(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180">
      <rect width="320" height="180" fill="#f8fafc"/>
      <rect x="18" y="18" width="284" height="144" rx="8" fill="#ffffff" stroke="#94a3b8" stroke-width="2"/>
      <rect x="38" y="42" width="122" height="16" rx="3" fill="#cbd5e1"/>
      <rect x="38" y="70" width="244" height="34" rx="4" fill="#fee2e2" stroke="#ef4444"/>
      <text x="52" y="92" fill="#991b1b" font-family="Arial, sans-serif" font-size="15" font-weight="700">Checkout error</text>
      <rect x="38" y="122" width="92" height="24" rx="4" fill="#2563eb"/>
      <text x="61" y="139" fill="#ffffff" font-family="Arial, sans-serif" font-size="12" font-weight="700">Save</text>
    </svg>
  `)
].join("")

function contentBlocks(value: unknown): unknown[] {
  if (Array.isArray(value)) return value
  if (isPlainObject(value) && Array.isArray(value.content)) return value.content
  if (isPlainObject(value) && isPlainObject(value.result) && Array.isArray(value.result.content)) return value.result.content
  return []
}

function objectPayload(value: unknown): Record<string, unknown> | null {
  if (isPlainObject(value)) {
    if (isPlainObject(value.structured_content)) return value.structured_content
    if (isPlainObject(value.result) && isPlainObject(value.result.structured_content)) return value.result.structured_content
    return value
  }
  return null
}

function parseCard(context: ToolCardContext): WalkthroughFrameCard | null {
  const payload = objectPayload(context.parsedResult)
  const input = isPlainObject(context.input) ? context.input : {}
  const textBlocks = contentBlocks(context.parsedResult)
    .filter((block): block is Record<string, unknown> => isPlainObject(block) && block.type === "text")
    .map((block) => displayValue(block.text))
    .filter((value): value is string => Boolean(value))
  const message = diagnosticMessage(context, payload, textBlocks)
  const image = imageFromPayload(payload) || imageFromContent(context.parsedResult)
  const instruction = frameInstruction(textBlocks)
  const payloadSignal = payload != null && Object.keys(payload).length > 0

  if (!context.resultError && !payloadSignal && !image && textBlocks.length === 0 && !displayValue(input.walkthrough_id) && context.resultBody.trim())
    return null

  const pending = !context.resultError && context.parsedResult == null && !context.resultBody.trim()

  return {
    status: pending ? "pending" : context.resultError || errorFlag(payload) ? "error" : image ? "success" : "missing",
    walkthroughId: displayValue(input.walkthrough_id) || instruction.walkthroughId,
    walkthroughName:
      displayValue(payload?.walkthrough_name) ||
      displayValue(payload?.title) ||
      displayValue(nested(payload, "walkthrough", "title")) ||
      displayValue(nested(payload, "walkthrough", "name")),
    timestamp: instruction.timestamp || timestampLabel(input, payload),
    range: rangeLabel(payload),
    frameIndex: displayValue(payload?.frame_index) || displayValue(payload?.index) || displayValue(payload?.frame_number),
    image,
    transcript: displayValue(payload?.transcript) || displayValue(payload?.associated_transcript) || displayValue(payload?.caption),
    context: displayValue(payload?.context) || displayValue(payload?.surrounding_context),
    links: artifactLinks(payload),
    message
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  const subject = card.walkthroughName || (card.walkthroughId ? `Walkthrough ${card.walkthroughId}` : "Walkthrough frame")
  const frame = [card.frameIndex ? `frame ${card.frameIndex}` : null, card.timestamp].filter(Boolean).join(" @ ")
  const state = card.status === "pending" ? "pending" : card.status === "success" ? "captured" : card.status === "missing" ? "missing frame" : "failed"

  return [subject, frame || null, state].filter(Boolean).join(" - ")
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  return card ? <WalkthroughFrameCardBody card={card} /> : null
}

function WalkthroughFrameCardBody({ card }: { card: WalkthroughFrameCard }) {
  const state = card.status === "pending" ? "pending" : card.status === "success" ? "captured" : card.status === "missing" ? "missing" : "failed"
  const tone = card.status === "pending" ? "info" : card.status === "success" ? "success" : card.status === "missing" ? "warning" : "failure"

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Walkthrough frame</Badge>
        <StatePill state={state} tone={tone} />
      </div>
      {card.message ? <ErrorNotice message={card.message} /> : null}
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {card.walkthroughName ? <Row label="Walkthrough" value={card.walkthroughName} /> : null}
        {card.walkthroughId ? (
          <div className="min-w-0">
            <SectionLabel>Walkthrough</SectionLabel>
            <EntityReference id={card.walkthroughId} kind="walkthrough" />
          </div>
        ) : null}
        {card.timestamp ? <Row label="Timestamp" value={card.timestamp} /> : null}
        {card.range ? <Row label="Range" value={card.range} /> : null}
        {card.frameIndex ? <Row label="Frame" value={card.frameIndex} /> : null}
      </dl>
      {card.image ? (
        <FramePreview card={card} image={card.image} />
      ) : card.status === "pending" ? (
        <EmptyState>Waiting for a frame image.</EmptyState>
      ) : (
        <MissingFrameNotice />
      )}
      {card.transcript ? <ProsePanel label="Transcript" text={card.transcript} /> : null}
      {card.context ? <ProsePanel label="Context" text={card.context} /> : null}
      {card.links.length > 0 ? <ArtifactLinks links={card.links} /> : null}
    </CardShell>
  )
}

function FramePreview({ card, image }: { card: WalkthroughFrameCard; image: FrameImage }) {
  const actions: MediaPreviewAction[] = [
    { label: "Open", href: image.src },
    { label: "Download", href: image.src, download: true }
  ]
  const meta: MediaPreviewMeta[] = [
    { label: "Walkthrough", value: card.walkthroughName || card.walkthroughId },
    { label: "Timestamp", value: card.timestamp },
    { label: "Range", value: card.range },
    { label: "Frame", value: card.frameIndex },
    { label: "Content type", value: image.mimeType }
  ]

  return (
    <MediaPreviewShell
      item={{
        title: image.label,
        subtitle: [card.timestamp, card.range].filter(Boolean).join(" - "),
        src: image.src,
        alt: image.label,
        badge: image.mimeType.split("/").pop()?.toUpperCase() ?? "IMAGE",
        actions,
        meta
      }}
      modalLabel={image.label}
      thumbnailClassName="w-full"
    />
  )
}

function MissingFrameNotice() {
  return <EmptyState>No frame image or thumbnail was returned.</EmptyState>
}

function ProsePanel({ label, text }: { label: string; text: string }) {
  return (
    <div className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-2">
      <MarkdownPreview linkifySlugs linkifyUrls maxChars={960} maxLines={6} modalLabel={label} text={text} title={label} />
    </div>
  )
}

function ErrorNotice({ message }: { message: string }) {
  return <div className={ERROR_NOTICE_CLASS}>{message}</div>
}

function ArtifactLinks({ links }: { links: ArtifactLink[] }) {
  return (
    <div className="space-y-1">
      <SectionLabel>Artifacts</SectionLabel>
      <div className="flex flex-wrap gap-2">
        {links.map((link) => (
          <InternalLink href={link.href} key={`${link.label}-${link.href}`}>
            {link.label}
          </InternalLink>
        ))}
      </div>
    </div>
  )
}

function imageFromContent(value: unknown): FrameImage | null {
  for (const block of contentBlocks(value)) {
    if (!isPlainObject(block) || block.type !== "image") continue
    const data = displayValue(block.data)
    if (!data) continue
    const mimeType = displayValue(block.mimeType) || displayValue(block.mime_type) || "image/jpeg"
    return {
      src: dataUrl(data, mimeType),
      mimeType,
      label: displayValue(block.title) || displayValue(block.label) || "Walkthrough frame"
    }
  }
  return null
}

function imageFromPayload(payload: Record<string, unknown> | null): FrameImage | null {
  if (!payload) return null
  const candidates = [payload.image, payload.thumbnail, payload.frame_image, payload.frame, payload]

  for (const candidate of candidates) {
    if (!isPlainObject(candidate)) continue
    const directUrl = displayValue(candidate.image_url) || displayValue(candidate.thumbnail_url) || displayValue(candidate.url) || displayValue(candidate.src)
    const data =
      displayValue(candidate.data) || displayValue(candidate.image_base64) || displayValue(candidate.thumbnail_base64) || displayValue(candidate.base64)
    const mimeType = displayValue(candidate.mimeType) || displayValue(candidate.mime_type) || displayValue(candidate.content_type) || "image/jpeg"
    const src = directUrl || (data ? dataUrl(data, mimeType) : null)
    if (!src) continue

    return {
      src,
      mimeType,
      label: displayValue(candidate.title) || displayValue(candidate.label) || "Walkthrough frame"
    }
  }

  return null
}

function timestampLabel(input: Record<string, unknown>, payload: Record<string, unknown> | null) {
  return (
    displayValue(payload?.timestamp) ||
    displayValue(payload?.timestamp_label) ||
    clockValue(payload?.timestamp_seconds) ||
    clockValue(payload?.seconds) ||
    displayValue(input.timestamp)
  )
}

function rangeLabel(payload: Record<string, unknown> | null) {
  if (!payload) return null
  const range = isPlainObject(payload.range) ? payload.range : null
  const start = displayValue(range?.start) || displayValue(payload.range_start) || clockValue(range?.start_seconds) || clockValue(payload.start_seconds)
  const end = displayValue(range?.end) || displayValue(payload.range_end) || clockValue(range?.end_seconds) || clockValue(payload.end_seconds)
  if (start && end) return `${start}-${end}`
  return displayValue(payload.range)
}

function artifactLinks(payload: Record<string, unknown> | null): ArtifactLink[] {
  if (!payload) return []

  const links: ArtifactLink[] = []
  const add = (label: string, value: unknown) => {
    const href = displayValue(value)
    if (!href || !/^(?:https?:|data:|blob:|\/api\/)/i.test(href)) return
    if (links.some((link) => link.href === href)) return
    links.push({ label, href })
  }

  add("Frame", payload.frame_url)
  add("Thumbnail", payload.thumbnail_url)
  add("Artifact", payload.artifact_url)

  const collections = [payload.links, payload.artifacts, payload.artifact_links]
  for (const collection of collections) {
    if (!Array.isArray(collection)) continue
    for (const item of collection) {
      if (typeof item === "string") add("Artifact", item)
      if (isPlainObject(item)) add(displayValue(item.label) || displayValue(item.name) || "Artifact", item.href || item.url)
    }
  }

  return links
}

function diagnosticMessage(context: ToolCardContext, payload: Record<string, unknown> | null, textBlocks: string[]) {
  if (!context.resultError && !errorFlag(payload) && !missingFlag(payload)) return null
  return displayValue(payload?.error) || displayValue(payload?.message) || textBlocks.join("\n") || context.resultBody.trim() || "Frame capture failed."
}

function frameInstruction(textBlocks: string[]): FrameInstruction {
  for (const text of textBlocks) {
    const match = text.match(FRAME_INSTRUCTION_PATTERN)
    if (match) return { walkthroughId: match[1], timestamp: match[2] }
  }
  return { walkthroughId: null, timestamp: null }
}

function errorFlag(payload: Record<string, unknown> | null) {
  return payload?.isError === true || payload?.success === false || displayValue(payload?.status)?.toLowerCase() === "error"
}

function missingFlag(payload: Record<string, unknown> | null) {
  return displayValue(payload?.status)?.toLowerCase() === "missing"
}

function nested(payload: Record<string, unknown> | null, key: string, nestedKey: string) {
  const value = payload?.[key]
  return isPlainObject(value) ? value[nestedKey] : undefined
}

function clockValue(value: unknown) {
  const seconds = numberValue(value)
  if (seconds == null) return null
  const wholeSeconds = Math.max(0, Math.floor(seconds))
  return `${Math.floor(wholeSeconds / 60)}:${String(wholeSeconds % 60).padStart(2, "0")}`
}

function dataUrl(data: string, mimeType: string) {
  if (data.startsWith("data:")) return data
  return `data:${mimeType};base64,${data}`
}

const readWalkthroughFrameToolCard: ToolCardRenderer = {
  toolName: "read_walkthrough_frame",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "normal_frame",
    label: "Captured frame",
    input: { walkthrough_id: 42, timestamp: "01:12" },
    description: "The real MCP image-plus-agent-instruction content envelope; the instruction is used only for frame metadata.",
    parsedResult: [
      { type: "image", data: EXAMPLE_FRAME_IMAGE, mimeType: "image/svg+xml" },
      {
        type: "text",
        text: "Screenshot from walkthrough #42 at 1:12. Read any on-screen text directly off this image and use the exact characters you see."
      }
    ],
    sourceType: "claude"
  },
  {
    id: "missing_frame",
    label: "Missing frame image",
    input: { walkthrough_id: 42, timestamp: "05:00" },
    parsedResult: {
      walkthrough_id: 42,
      timestamp: "05:00",
      status: "missing",
      message: "Frame extraction produced no image at this timestamp.",
      transcript: "The recording had already ended."
    }
  },
  {
    id: "capture_error",
    label: "Error payload",
    input: { walkthrough_id: 42, timestamp: "banana" },
    resultError: true,
    parsedResult: {
      walkthrough_id: 42,
      timestamp: "banana",
      error: "timestamp must be mm:ss or whole seconds"
    }
  }
]

export default readWalkthroughFrameToolCard
