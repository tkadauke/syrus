import { useState } from "react"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CloseIcon } from "@app/components/CloseIcon"

// Core-owned tool card for list_chat_media (EPIC-291 / JOB-4220), registered
// through the plugin-aware extension point core and plugins share (see
// app/frontend/pluginToolCards.tsx and JOB-4219). Renders a compact gallery
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
  const [preview, setPreview] = useState<ChatMediaItem | null>(null)

  return (
    <>
      <div className="mt-1 rounded border border-gray-200 bg-gray-50 p-2 dark:border-gray-700 dark:bg-gray-900">
        <div className="mb-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
          <span className="font-medium text-gray-900 dark:text-gray-100">{items.length} media {items.length === 1 ? "item" : "items"}</span>
          {whiteboardElementCount != null ? <span>{whiteboardElementCount} whiteboard elements</span> : null}
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {items.map((item) => (
            <MediaTile item={item} key={item.id} onOpen={() => setPreview(item)} />
          ))}
        </div>
      </div>
      {preview ? <MediaPreviewModal item={preview} onClose={() => setPreview(null)} /> : null}
    </>
  )
}

function MediaTile({ item, onOpen }: { item: ChatMediaItem; onOpen: () => void }) {
  const thumbnailSrc = mediaThumbnailSrc(item)

  return (
    <button
      aria-label={`Open ${mediaTitle(item)}`}
      className="group/media overflow-hidden rounded border border-gray-200 bg-white p-0 text-left shadow-sm transition hover:border-brand/40 focus:outline-none focus:ring-2 focus:ring-brand dark:border-gray-700 dark:bg-gray-950"
      onClick={onOpen}
      type="button"
    >
      <span className="block aspect-square w-full overflow-hidden bg-gray-100 dark:bg-gray-800">
        {thumbnailSrc ? (
          <img alt={mediaTitle(item)} className="h-full w-full object-cover transition group-hover/media:scale-105" src={thumbnailSrc} />
        ) : (
          <span className="flex h-full w-full items-center justify-center text-xs font-semibold uppercase text-gray-500 dark:text-gray-300">
            {item.kind === "chat_image" ? contentTypeLabel(item.content_type) : "Snapshot"}
          </span>
        )}
      </span>
      <span className="block truncate px-1.5 pt-1 text-2xs font-medium text-gray-800 dark:text-gray-100" title={mediaTitle(item)}>{mediaTitle(item)}</span>
      <span className="flex items-center justify-between gap-1 px-1.5 pb-1 text-2xs text-gray-500 dark:text-gray-400">
        <span className="truncate font-mono" title={item.id}>{item.id}</span>
        <span className="shrink-0 rounded-full bg-gray-100 px-1.5 py-0.5 uppercase dark:bg-gray-800">{item.kind === "chat_image" ? "image" : "snapshot"}</span>
      </span>
      {item.kind === "chat_image" ? (
        <span className="block truncate px-1.5 pb-1.5 text-2xs text-gray-500 dark:text-gray-400">{item.content_type}</span>
      ) : null}
    </button>
  )
}

function MediaPreviewModal({ item, onClose }: { item: ChatMediaItem; onClose: () => void }) {
  const thumbnailSrc = mediaThumbnailSrc(item)

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" onClick={onClose} role="presentation">
      <section aria-label={mediaTitle(item)} aria-modal="true" className="relative max-h-full max-w-full rounded bg-white p-4 shadow-lg dark:bg-gray-900" onClick={(event) => event.stopPropagation()} role="dialog">
        <button
          aria-label="Close media preview"
          className="absolute right-2 top-2 rounded bg-white/90 p-1.5 text-gray-600 shadow hover:bg-white hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand dark:bg-gray-900/90 dark:text-gray-200 dark:hover:bg-gray-900"
          onClick={onClose}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
        {thumbnailSrc ? (
          <img alt={mediaTitle(item)} className="max-h-[calc(100dvh-2rem)] max-w-[calc(100vw-2rem)] rounded bg-white object-contain dark:bg-gray-900" src={thumbnailSrc} />
        ) : (
          <h3 className="pr-8 text-sm font-semibold text-gray-900 dark:text-gray-100">{mediaTitle(item)}</h3>
        )}
        <dl className="mt-3 space-y-2 text-xs">
          <PreviewRow label="ID" value={item.id} />
          <PreviewRow label="Kind" value={item.kind === "chat_image" ? "Image" : "Whiteboard snapshot"} />
          {item.kind === "chat_image" ? <PreviewRow label="Content type" value={item.content_type} /> : null}
          {item.kind === "snapshot" && item.element_count != null ? <PreviewRow label="Elements" value={String(item.element_count)} /> : null}
          {item.kind === "snapshot" && item.created_at ? <PreviewRow label="Created" value={item.created_at} /> : null}
        </dl>
      </section>
    </div>
  )
}

function PreviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex gap-2">
      <dt className="w-24 shrink-0 font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="min-w-0 break-words font-mono text-gray-800 dark:text-gray-200">{value}</dd>
    </div>
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
