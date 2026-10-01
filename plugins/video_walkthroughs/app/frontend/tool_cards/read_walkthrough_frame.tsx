import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction, type MediaPreviewMeta } from "@app/routes/chat/mediaPreviewShell"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"

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
  status: "success" | "error" | "missing"
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

const ONE_PIXEL_JPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2w=="

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
  const payloadSignal = payload != null && Object.keys(payload).length > 0

  if (!context.resultError && !payloadSignal && !image && textBlocks.length === 0 && !displayValue(input.walkthrough_id)) return null

  return {
    status: context.resultError || errorFlag(payload) ? "error" : image ? "success" : "missing",
    walkthroughId: displayValue(input.walkthrough_id) || displayValue(payload?.walkthrough_id) || displayValue(nested(payload, "walkthrough", "id")),
    walkthroughName: displayValue(payload?.walkthrough_name) || displayValue(payload?.title) || displayValue(nested(payload, "walkthrough", "title")) || displayValue(nested(payload, "walkthrough", "name")),
    timestamp: timestampLabel(input, payload),
    range: rangeLabel(payload),
    frameIndex: displayValue(payload?.frame_index) || displayValue(payload?.index) || displayValue(payload?.frame_number),
    image,
    transcript: displayValue(payload?.transcript) || displayValue(payload?.associated_transcript) || displayValue(payload?.caption),
    context: displayValue(payload?.context) || displayValue(payload?.surrounding_context) || (!context.resultError ? textBlocks.join("\n") || null : null),
    links: artifactLinks(payload),
    message
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  const subject = card.walkthroughName || (card.walkthroughId ? `Walkthrough ${card.walkthroughId}` : "Walkthrough frame")
  const frame = [card.frameIndex ? `frame ${card.frameIndex}` : null, card.timestamp].filter(Boolean).join(" @ ")
  const state = card.status === "success" ? "captured" : card.status === "missing" ? "missing frame" : "failed"

  return [subject, frame || null, state].filter(Boolean).join(" - ")
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  return card ? <WalkthroughFrameCardBody card={card} /> : null
}

function WalkthroughFrameCardBody({ card }: { card: WalkthroughFrameCard }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Walkthrough frame</Badge>
        <StatePill state={card.status === "success" ? "captured" : card.status === "missing" ? "missing" : "failed"} tone={card.status === "success" ? "success" : card.status === "missing" ? "warning" : "failure"} />
      </div>
      {card.message ? <div className="text-sm text-danger-text">{card.message}</div> : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        {card.walkthroughName ? <Row label="Walkthrough" value={card.walkthroughName} /> : null}
        {card.walkthroughId ? <Row label="Walkthrough ID" value={card.walkthroughId} /> : null}
        {card.timestamp ? <Row label="Timestamp" value={card.timestamp} /> : null}
        {card.range ? <Row label="Range" value={card.range} /> : null}
        {card.frameIndex ? <Row label="Frame" value={card.frameIndex} /> : null}
      </dl>
      {card.image ? <FramePreview card={card} image={card.image} /> : <MissingFrameNotice />}
      {card.transcript ? <TextPanel label="Transcript" text={card.transcript} /> : null}
      {card.context ? <TextPanel label="Context" text={card.context} /> : null}
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

function TextPanel({ label, text }: { label: string; text: string }) {
  return (
    <Disclosure label={label}>
      <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">{text}</pre>
    </Disclosure>
  )
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
  const candidates = [
    payload.image,
    payload.thumbnail,
    payload.frame_image,
    payload.frame,
    payload
  ]

  for (const candidate of candidates) {
    if (!isPlainObject(candidate)) continue
    const directUrl = displayValue(candidate.image_url) || displayValue(candidate.thumbnail_url) || displayValue(candidate.url) || displayValue(candidate.src)
    const data = displayValue(candidate.data) || displayValue(candidate.image_base64) || displayValue(candidate.thumbnail_base64) || displayValue(candidate.base64)
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
    parsedResult: {
      walkthrough: { id: 42, title: "Checkout regression" },
      timestamp: "01:12",
      range: { start: "01:10", end: "01:15" },
      frame_index: 2160,
      image: { data: ONE_PIXEL_JPEG, mimeType: "image/jpeg", label: "Checkout regression at 01:12" },
      transcript: "The save button is clicked and an error toast appears.",
      context: "The frame captures the toast text beside the checkout form.",
      links: [{ label: "Source video", url: "/api/v1/app/video_walkthroughs/42" }]
    }
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
