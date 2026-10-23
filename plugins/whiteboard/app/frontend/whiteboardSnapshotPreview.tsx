import { useEffect, useState } from "react"
import { fetchWhiteboardSnapshot } from "@app/api/chats"
import type { ChatWhiteboardScene } from "@app/api/chats"
import { asExcalidrawElements, normalizeWhiteboardScene } from "@app/routes/chat/whiteboardScene"
import { MediaPreviewShell, type MediaPreviewItem } from "@app/routes/chat/mediaPreviewShell"
import i18n from "i18next"

type PreviewState = { status: "loading"; src: null } | { status: "ready"; src: string } | { status: "error"; src: null }

export function WhiteboardSnapshotPreview({ chatId, snapshotId, item }: { chatId: string; snapshotId: string; item: MediaPreviewItem }) {
  const [preview, setPreview] = useState<PreviewState>({ status: "loading", src: null })

  useEffect(() => {
    let cancelled = false

    void renderSnapshot(chatId, snapshotId)
      .then((src) => {
        if (!cancelled) setPreview({ status: "ready", src })
      })
      .catch(() => {
        if (!cancelled) setPreview({ status: "error", src: null })
      })

    return () => {
      cancelled = true
    }
  }, [chatId, snapshotId])

  const fallbackLabel = preview.status === "loading" ? translate("tool_snapshot_loading") : translate("tool_snapshot_preview_error")

  return (
    <MediaPreviewShell
      item={{ ...item, src: preview.src, fallbackLabel }}
      modalLabel={translate("tool_snapshot_preview")}
      thumbnailClassName="w-full sm:w-72"
    />
  )
}

export function WhiteboardScenePreview({ scene, item }: { scene: ChatWhiteboardScene; item: MediaPreviewItem }) {
  const [preview, setPreview] = useState<PreviewState>({ status: "loading", src: null })

  useEffect(() => {
    let cancelled = false
    void renderScene(scene, { maxElements: MAX_READ_SCENE_ELEMENTS, maxFiles: MAX_READ_SCENE_FILES })
      .then((src) => {
        if (!cancelled) setPreview({ status: "ready", src })
      })
      .catch(() => {
        if (!cancelled) setPreview({ status: "error", src: null })
      })
    return () => {
      cancelled = true
    }
  }, [scene])

  const fallbackLabel = preview.status === "loading" ? translate("tool_scene_loading") : translate("tool_scene_preview_error")
  return (
    <MediaPreviewShell item={{ ...item, src: preview.src, fallbackLabel }} modalLabel={translate("tool_scene_preview")} thumbnailClassName="w-full sm:w-72" />
  )
}

function translate(key: string) {
  return i18n.t(`whiteboard:${key}`)
}

async function renderSnapshot(chatId: string, snapshotId: string) {
  const snapshot = await fetchWhiteboardSnapshot(chatId, snapshotId)
  const scene = normalizeWhiteboardScene(snapshot.scene_json)
  return renderScene(scene)
}

const MAX_READ_SCENE_ELEMENTS = 200
const MAX_READ_SCENE_FILES = 100

type RenderLimits = { maxElements: number; maxFiles: number }

async function renderScene(scene: ChatWhiteboardScene, limits?: RenderLimits) {
  const elements = limits ? scene.elements.slice(0, limits.maxElements) : scene.elements
  const files = limits ? referencedFiles(elements, scene.files, limits.maxFiles) : scene.files
  const { exportToSvg } = await import("@excalidraw/excalidraw")
  const svg = await exportToSvg({
    elements: asExcalidrawElements(elements),
    appState: { ...scene.appState, exportBackground: true },
    files
  })

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`
}

function referencedFiles(elements: ChatWhiteboardScene["elements"], files: ChatWhiteboardScene["files"], maxFiles: number) {
  // Prefer the files the retained image elements actually need instead of an
  // arbitrary object prefix. If more images are retained than the file cap,
  // element order determines which references are included.
  const fileIds = elements.flatMap((element) => (typeof element.fileId === "string" ? [element.fileId] : []))
  return Object.fromEntries([...new Set(fileIds)].slice(0, maxFiles).flatMap((fileId) => (files[fileId] ? [[fileId, files[fileId]]] : [])))
}
