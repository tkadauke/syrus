import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction } from "@app/components/media/MediaPreviewShell"

// Core-owned tool card for list_chat_media (the Tier 1 tool-card work), registered
// through the plugin-aware extension point core and plugins share (see
// app/frontend/pluginToolCards.tsx and Renders a compact gallery
// with thumbnails/preview affordances, stable media IDs, filenames, kind,
// and content type.
type ChatMediaSnapshot = { id: string; kind: "snapshot"; name: string; element_count: number | null; created_at: string }
type ChatMediaImage = { id: string; kind: "chat_image"; filename: string; content_type: string; file_path: string }
type ChatMediaItem = ChatMediaSnapshot | ChatMediaImage

type MediaPayload = {
  snapshots: ChatMediaSnapshot[]
  images: ChatMediaImage[]
  whiteboardElementCount: number | null
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : ""
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseSnapshot(value: unknown): ChatMediaSnapshot | null {
  if (!isPlainObject(value) || !stringValue(value.id)) return null
  return {
    id: stringValue(value.id),
    kind: "snapshot",
    name: stringValue(value.name) || stringValue(value.id),
    element_count: numberValue(value.element_count),
    created_at: stringValue(value.created_at)
  }
}

function parseImage(value: unknown): ChatMediaImage | null {
  if (!isPlainObject(value) || !stringValue(value.id)) return null
  return {
    id: stringValue(value.id),
    kind: "chat_image",
    filename: stringValue(value.filename) || stringValue(value.id),
    content_type: stringValue(value.content_type) || "unknown",
    file_path: stringValue(value.file_path)
  }
}

function typedArray<T>(value: unknown, mapper: (item: unknown) => T | null): T[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const mapped = mapper(item)
    return mapped ? [mapped] : []
  })
}

// Distinguishes "no media yet" (a well-formed, empty payload) from a
// malformed/unexpected shape: the latter falls back to the generic renderer
// (return null), the former renders an explicit empty state.
function mediaPayload(context: ToolCardContext): MediaPayload | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const snapshotsRaw = parsed.snapshots
  const imagesRaw = parsed.chat_images ?? parsed.media
  if (snapshotsRaw === undefined && imagesRaw === undefined) return null
  if (snapshotsRaw !== undefined && !Array.isArray(snapshotsRaw)) return null
  if (imagesRaw !== undefined && !Array.isArray(imagesRaw)) return null

  return {
    snapshots: typedArray(snapshotsRaw, parseSnapshot),
    images: typedArray(imagesRaw, parseImage),
    whiteboardElementCount: numberValue(parsed.whiteboard_element_count)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const media = mediaPayload(context)
  if (!media) return null

  const count = media.snapshots.length + media.images.length
  return `${count} media item${count === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const media = mediaPayload(context)
  if (!media) return null

  const items = [...media.images, ...media.snapshots]
  if (items.length === 0) {
    return (
      <div className="mt-1 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
        No media in this chat yet.
      </div>
    )
  }

  return <MediaGallery items={items} whiteboardElementCount={media.whiteboardElementCount} />
}

function MediaGallery({ items, whiteboardElementCount }: { items: ChatMediaItem[]; whiteboardElementCount: number | null }) {
  return (
    <div className="mt-1 rounded border border-gray-200 bg-gray-50 p-2 dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
        <span className="font-medium text-gray-900 dark:text-gray-100">{items.length} media {items.length === 1 ? "item" : "items"}</span>
        {whiteboardElementCount != null ? <span>{whiteboardElementCount} whiteboard elements</span> : null}
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        {items.map((item) => <MediaTile item={item} key={item.id} />)}
      </div>
    </div>
  )
}

function MediaTile({ item }: { item: ChatMediaItem }) {
  const thumbnailSrc = mediaThumbnailSrc(item)
  const actions: MediaPreviewAction[] = [{ label: "Copy ID", copyValue: item.id }]
  if (thumbnailSrc) {
    actions.unshift({ label: "Download", href: thumbnailSrc, download: true })
    actions.unshift({ label: "Open", href: thumbnailSrc })
  }
  if (item.kind === "chat_image" && item.file_path) actions.push({ label: "Copy path", copyValue: item.file_path })

  return (
    <MediaPreviewShell
      item={{
        title: mediaTitle(item),
        subtitle: item.kind === "chat_image" ? item.content_type : item.created_at,
        src: thumbnailSrc,
        alt: mediaTitle(item),
        badge: item.kind === "chat_image" ? "image" : "snapshot",
        fallbackLabel: item.kind === "chat_image" ? contentTypeLabel(item.content_type) : "Snapshot",
        actions,
        meta: [
          { label: "ID", value: item.id, copyValue: item.id },
          { label: "Kind", value: item.kind === "chat_image" ? "Image" : "Whiteboard snapshot" },
          item.kind === "chat_image" ? { label: "Content type", value: item.content_type } : { label: "Elements", value: item.element_count != null ? String(item.element_count) : null },
          item.kind === "chat_image" ? { label: "Path", value: item.file_path, copyValue: item.file_path } : { label: "Created", value: item.created_at }
        ]
      }}
      modalLabel={mediaTitle(item)}
      thumbnailClassName="w-full"
    />
  )
}

function mediaTitle(item: ChatMediaItem) {
  return item.kind === "chat_image" ? item.filename : item.name
}

function mediaThumbnailSrc(item: ChatMediaItem) {
  if (item.kind !== "chat_image" || !item.file_path) return null
  return item.file_path.startsWith("/") || item.file_path.startsWith("data:image/") ? item.file_path : null
}

function contentTypeLabel(contentType: string) {
  const suffix = contentType.split("/").pop()
  return suffix ? suffix.toUpperCase() : "Image"
}

const listChatMediaToolCard: ToolCardRenderer = {
  toolName: "list_chat_media",
  collapsedSummary,
  renderExpanded
}

export default listChatMediaToolCard
