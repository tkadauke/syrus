import { useEffect, useState } from "react"
import { CloseIcon } from "../../../components/CloseIcon"
import { stringValue } from "../utils"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "../../../pluginToolCards"

// Core-owned tool card (EPIC-291 / JOB-4220) for the `list_chat_media` MCP
// tool: a compact gallery of the media (whiteboard snapshots + pasted/
// generated images) available to attach to a Job proposal or PR feedback.
// Renders thumbnails where available, falling back to a kind/type badge —
// every tile still carries the stable media id, filename/name, kind, and
// content type in its tooltip so an operator can identify an item even
// without a preview image.
type ChatMediaSnapshot = {
  id: string
  kind: "snapshot"
  name: string
  element_count: number | null
  created_at: string
}

type ChatMediaImage = {
  id: string
  kind: "chat_image"
  filename: string
  content_type: string
  file_path: string
}

type ChatMediaItem = ChatMediaSnapshot | ChatMediaImage

type ChatMediaGalleryData = {
  snapshots: ChatMediaSnapshot[]
  images: ChatMediaImage[]
  whiteboard_element_count: number | null
}

function typedArray<T>(value: unknown, mapper: (item: unknown) => T | null) {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const mapped = mapper(item)
    return mapped ? [mapped] : []
  })
}

function chatMediaSnapshot(value: unknown): ChatMediaSnapshot | null {
  if (!isPlainObject(value) || stringValue(value.id) === "") return null
  return {
    id: stringValue(value.id),
    kind: "snapshot",
    name: stringValue(value.name) || stringValue(value.id),
    element_count: typeof value.element_count === "number" && Number.isFinite(value.element_count) ? value.element_count : null,
    created_at: stringValue(value.created_at)
  }
}

function chatMediaImage(value: unknown): ChatMediaImage | null {
  if (!isPlainObject(value) || stringValue(value.id) === "") return null
  return {
    id: stringValue(value.id),
    kind: "chat_image",
    filename: stringValue(value.filename) || stringValue(value.name) || stringValue(value.id),
    content_type: stringValue(value.content_type) || stringValue(value.mime_type) || "image",
    file_path: stringValue(value.file_path) || stringValue(value.image_url) || stringValue(value.url)
  }
}

function chatMediaGallery(context: ToolCardContext): ChatMediaGalleryData | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const snapshots = typedArray(parsed.snapshots, chatMediaSnapshot)
  const images = typedArray(parsed.chat_images ?? parsed.media, chatMediaImage)
  if (snapshots.length === 0 && images.length === 0) return null

  const elementCount = typeof parsed.whiteboard_element_count === "number" && Number.isFinite(parsed.whiteboard_element_count) ? parsed.whiteboard_element_count : null
  return { snapshots, images, whiteboard_element_count: elementCount }
}

function mediaTitle(item: ChatMediaItem) {
  return item.kind === "chat_image" ? item.filename : item.name
}

function mediaSubtitle(item: ChatMediaItem) {
  if (item.kind === "chat_image") return item.content_type
  return item.element_count == null ? "whiteboard snapshot" : `${item.element_count} ${item.element_count === 1 ? "element" : "elements"}`
}

function mediaTooltip(item: ChatMediaItem) {
  return [mediaTitle(item), item.id, mediaSubtitle(item)].filter(Boolean).join("\n")
}

function mediaThumbnailSrc(item: ChatMediaItem) {
  if (item.kind !== "chat_image" || !item.file_path) return null
  return item.file_path.startsWith("/") || item.file_path.startsWith("data:image/") ? item.file_path : null
}

function imageTypeLabel(contentType: string) {
  const suffix = contentType.split("/").pop()
  return suffix ? suffix.toUpperCase() : "Image"
}

function PreviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="break-words font-mono text-gray-800 dark:text-gray-200">{value}</dd>
    </div>
  )
}

function ChatMediaPreview({ item, onClose }: { item: ChatMediaItem; onClose: () => void }) {
  const thumbnailSrc = mediaThumbnailSrc(item)

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") onClose()
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [onClose])

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
          <>
            <h3 className="pr-8 text-sm font-semibold text-gray-900 dark:text-gray-100">{mediaTitle(item)}</h3>
            <dl className="mt-3 space-y-2 text-xs">
              <PreviewRow label="ID" value={item.id} />
              <PreviewRow label="Type" value={item.kind === "chat_image" ? item.content_type : "whiteboard snapshot"} />
              {"element_count" in item && item.element_count != null ? <PreviewRow label="Elements" value={String(item.element_count)} /> : null}
              {"created_at" in item && item.created_at ? <PreviewRow label="Created" value={item.created_at} /> : null}
            </dl>
          </>
        )}
      </section>
    </div>
  )
}

function ChatMediaGallery({ data }: { data: ChatMediaGalleryData }) {
  const [preview, setPreview] = useState<ChatMediaItem | null>(null)
  const items = [...data.images, ...data.snapshots]

  return (
    <>
      <div className="mt-1 rounded border border-gray-200 bg-gray-50 p-2 dark:border-gray-700 dark:bg-gray-900">
        <div className="mb-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
          <span className="font-medium text-gray-900 dark:text-gray-100">{items.length} media {items.length === 1 ? "item" : "items"}</span>
          {data.whiteboard_element_count != null ? <span>{data.whiteboard_element_count} whiteboard elements</span> : null}
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {items.map((item) => {
            const thumbnailSrc = mediaThumbnailSrc(item)
            return (
              <button
                aria-label={`Open ${mediaTitle(item)}`}
                className="group/media aspect-square overflow-hidden rounded border border-gray-200 bg-white p-0 shadow-sm transition hover:border-brand/40 focus:outline-none focus:ring-2 focus:ring-brand dark:border-gray-700 dark:bg-gray-950"
                key={item.id}
                onClick={() => setPreview(item)}
                title={mediaTooltip(item)}
                type="button"
              >
                {thumbnailSrc ? (
                  <img alt={mediaTitle(item)} className="h-full w-full object-cover transition group-hover/media:scale-105" src={thumbnailSrc} />
                ) : (
                  <div className="flex h-full w-full items-center justify-center bg-gray-100 text-xs font-semibold uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-300">
                    {item.kind === "chat_image" ? imageTypeLabel(item.content_type) : "Snapshot"}
                  </div>
                )}
              </button>
            )
          })}
        </div>
      </div>
      {preview ? <ChatMediaPreview item={preview} onClose={() => setPreview(null)} /> : null}
    </>
  )
}

function renderExpanded(context: ToolCardContext) {
  const data = chatMediaGallery(context)
  if (!data) return null

  return <ChatMediaGallery data={data} />
}

const listChatMediaToolCard: ToolCardRenderer = {
  toolName: "list_chat_media",
  renderExpanded
}

export default listChatMediaToolCard
