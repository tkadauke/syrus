import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction, type MediaPreviewMeta } from "../mediaPreviewShell"

type Snapshot = { id: string; kind: "snapshot"; name: string; element_count: number | null; created_at: string; thumbnail_url: string; whiteboard_url: string }
type Image = { id: string; kind: "chat_image"; filename: string; content_type: string; file_path: string; image_url: string }
type Media = Snapshot | Image
type ContextRow = { label: string; value: string }
type Payload = { snapshots: Snapshot[]; images: Image[]; context: ContextRow[] }

const stringValue = (value: unknown) => (typeof value === "string" ? value : "")
const numberValue = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : null)
const firstString = (record: Record<string, unknown>, keys: string[]) => keys.map((key) => stringValue(record[key])).find(Boolean) ?? ""

function parseSnapshot(value: unknown): Snapshot | null {
  if (!isPlainObject(value) || !stringValue(value.id)) return null
  return {
    id: stringValue(value.id),
    kind: "snapshot",
    name: stringValue(value.name) || stringValue(value.id),
    element_count: numberValue(value.element_count),
    created_at: stringValue(value.created_at),
    thumbnail_url: firstString(value, ["thumbnail_url", "render_url", "image_url"]),
    whiteboard_url: firstString(value, ["whiteboard_url", "url"])
  }
}

function parseImage(value: unknown): Image | null {
  if (!isPlainObject(value) || !stringValue(value.id)) return null
  return {
    id: stringValue(value.id),
    kind: "chat_image",
    filename: stringValue(value.filename) || stringValue(value.name) || stringValue(value.id),
    content_type: stringValue(value.content_type) || "unknown",
    file_path: stringValue(value.file_path),
    image_url: firstString(value, ["image_url", "file_url", "url"])
  }
}

function typedArray<T>(value: unknown, mapper: (item: unknown) => T | null): T[] {
  return Array.isArray(value)
    ? value.flatMap((item) => {
        const mapped = mapper(item)
        return mapped ? [mapped] : []
      })
    : []
}

function displayContextValue(value: unknown): string | null {
  if (["string", "boolean"].includes(typeof value)) return String(value)
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (Array.isArray(value) && value.every((entry) => ["string", "number", "boolean"].includes(typeof entry))) return value.join(", ")
  return null
}

function mediaPayload(context: ToolCardContext): Payload | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const snapshotsRaw = parsed.snapshots
  const imagesRaw = parsed.chat_images ?? parsed.images ?? parsed.media
  if (snapshotsRaw === undefined && imagesRaw === undefined) return null
  if ((snapshotsRaw !== undefined && !Array.isArray(snapshotsRaw)) || (imagesRaw !== undefined && !Array.isArray(imagesRaw))) return null
  const reserved = new Set(["snapshots", "chat_images", "images", "media"])
  const extraContext = Object.entries(parsed).flatMap(([key, value]) => {
    const display = reserved.has(key) ? null : displayContextValue(value)
    if (display === null) return []
    if (key === "whiteboard_element_count") return [{ label: "", value: `${display} whiteboard elements` }]
    return [{ label: key.replace(/_/g, " ").replace(/^./, (letter) => letter.toUpperCase()), value: display }]
  })
  return { snapshots: typedArray(snapshotsRaw, parseSnapshot), images: typedArray(imagesRaw, parseImage), context: extraContext }
}

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  return isPlainObject(context.parsedResult)
    ? firstString(context.parsedResult, ["message", "error_message", "error", "detail", "reason"]) || "Unable to list chat media."
    : context.resultBody || "Unable to list chat media."
}

function pendingMessage(context: ToolCardContext) {
  const pending = context.livePendingAction
  return pending?.state === "pending" ? pending.detail || pending.label || "Waiting for confirmation." : null
}

function collapsedSummary(context: ToolCardContext) {
  const status = errorMessage(context) || pendingMessage(context)
  if (status) return status
  const media = mediaPayload(context)
  if (!media) return null
  const count = media.snapshots.length + media.images.length
  return `${count} media item${count === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error) return <StatusMessage tone="error">{error}</StatusMessage>
  const pending = pendingMessage(context)
  if (pending) return <StatusMessage tone="pending">{pending}</StatusMessage>
  const media = mediaPayload(context)
  if (!media) return null
  const items = [...media.images, ...media.snapshots]
  if (items.length === 0)
    return (
      <div className="mt-1 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
        No media in this chat yet.
        <ContextRows rows={media.context} />
      </div>
    )
  return <MediaGallery contextRows={media.context} items={items} />
}

function StatusMessage({ children, tone }: { children: string; tone: "error" | "pending" }) {
  const colors =
    tone === "error"
      ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
      : "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
  return <div className={`mt-1 rounded border px-3 py-2 text-xs ${colors}`}>{children}</div>
}

function ContextRows({ rows }: { rows: ContextRow[] }) {
  if (rows.length === 0) return null
  return (
    <dl className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
      {rows.map((row) => (
        <div className="flex min-w-0 gap-1" key={row.label}>
          {row.label ? <dt className="font-medium">{row.label}:</dt> : null}
          <dd className="break-words">{row.value}</dd>
        </div>
      ))}
    </dl>
  )
}

function MediaGallery({ items, contextRows }: { items: Media[]; contextRows: ContextRow[] }) {
  return (
    <div className="mt-1 rounded border border-gray-200 bg-gray-50 p-2 dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-2 text-gray-600 dark:text-gray-300">
        <span className="text-xs font-medium text-gray-900 dark:text-gray-100">
          {items.length} media {items.length === 1 ? "item" : "items"}
        </span>
        <ContextRows rows={contextRows} />
      </div>
      <div className="grid grid-cols-1 gap-2 min-[360px]:grid-cols-2 sm:grid-cols-3">
        {items.map((item) => (
          <MediaTile item={item} key={item.id} />
        ))}
      </div>
    </div>
  )
}

function MediaTile({ item }: { item: Media }) {
  const thumbnailSrc = mediaThumbnailSrc(item)
  const imageSource = item.kind === "chat_image" ? item.file_path || item.image_url : ""
  const href = item.kind === "snapshot" ? safeMediaUrl(item.whiteboard_url) : thumbnailSrc
  const actions: MediaPreviewAction[] = [{ label: "Copy ID", copyValue: item.id }]
  if (href) actions.unshift({ label: item.kind === "snapshot" ? "Open whiteboard" : "Open image", href })
  if (thumbnailSrc && item.kind === "chat_image") actions.splice(1, 0, { label: "Download", href: thumbnailSrc, download: true })
  if (item.kind === "chat_image" && item.file_path) actions.push({ label: "Copy path", copyValue: item.file_path })
  const meta: MediaPreviewMeta[] = [
    { label: "ID", value: item.id, copyValue: item.id },
    { label: "Kind", value: item.kind === "chat_image" ? "Image" : "Whiteboard snapshot" },
    item.kind === "chat_image"
      ? { label: "Content type", value: item.content_type }
      : { label: "Elements", value: item.element_count == null ? null : String(item.element_count) },
    item.kind === "chat_image"
      ? { label: "Path", value: inlineImageSource(imageSource) ? null : imageSource, copyValue: imageSource }
      : { label: "Created", value: item.created_at }
  ]
  const title = item.kind === "chat_image" ? item.filename : item.name
  return (
    <MediaPreviewShell
      item={{
        title,
        subtitle: item.kind === "chat_image" ? item.content_type : item.created_at,
        src: thumbnailSrc,
        alt: title,
        badge: item.kind === "chat_image" ? "image" : "snapshot",
        fallbackLabel: item.kind === "chat_image" ? contentTypeLabel(item.content_type) : "Whiteboard snapshot",
        actions,
        meta
      }}
      modalLabel={title}
      thumbnailClassName="min-h-11 w-full"
    />
  )
}

function safeMediaUrl(value: string) {
  return value && (value.startsWith("/") || value.startsWith("data:image/") || /^https?:\/\//i.test(value)) ? value : null
}

function inlineImageSource(value: string) {
  return value.startsWith("data:image/")
}

function mediaThumbnailSrc(item: Media) {
  return safeMediaUrl(item.kind === "chat_image" ? item.image_url || item.file_path : item.thumbnail_url)
}

function contentTypeLabel(contentType: string) {
  return contentType.split("/").pop()?.toUpperCase() || "Image"
}

export const examples: ToolCardExample[] = [
  {
    id: "images_and_snapshot",
    label: "Images and whiteboard snapshot",
    description: "Direct result with remote thumbnail and all context fields.",
    sourceType: "claude",
    parsedResult: {
      snapshots: [{ id: "snapshot:9", name: "Checkout flow", element_count: 4, whiteboard_url: "/chats/12" }],
      chat_images: [{ id: "chat_image:3", filename: "desktop.png", content_type: "image/png", file_path: "https://media.example/desktop.png" }],
      whiteboard_element_count: 7,
      whiteboard_has_unsaved_content: true
    }
  },
  { id: "empty", label: "Empty chat", parsedResult: { snapshots: [], chat_images: [], whiteboard_element_count: 0 }, sourceType: "generic" },
  { id: "error", label: "Tool error", parsedResult: { error: "Media service unavailable" }, resultError: true, sourceType: "codex" }
]

const listChatMediaToolCard: ToolCardRenderer = { toolName: "list_chat_media", collapsedSummary, renderExpanded }
export default listChatMediaToolCard
