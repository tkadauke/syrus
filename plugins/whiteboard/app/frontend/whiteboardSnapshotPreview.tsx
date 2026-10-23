import { useEffect, useState } from "react"
import { fetchWhiteboardSnapshot, type ChatWhiteboardScene } from "@app/api/chats"
import { asExcalidrawElements, normalizeWhiteboardScene } from "@app/routes/chat/whiteboardScene"
import { MediaPreviewShell, type MediaPreviewItem } from "@app/routes/chat/mediaPreviewShell"
import i18n from "i18next"

type PreviewState = { status: "loading"; src: null } | { status: "ready"; src: string } | { status: "error"; src: null }

export function WhiteboardSnapshotPreview({
  chatId,
  snapshotId,
  item,
  scene
}: {
  chatId?: string
  snapshotId?: string
  item: MediaPreviewItem
  scene?: ChatWhiteboardScene | null
}) {
  const [preview, setPreview] = useState<PreviewState>({ status: "loading", src: null })

  useEffect(() => {
    let cancelled = false

    void renderSnapshotPreviewSource(chatId, snapshotId, scene)
      .then((src) => {
        if (!cancelled) setPreview({ status: "ready", src })
      })
      .catch(() => {
        if (!cancelled) setPreview({ status: "error", src: null })
      })

    return () => {
      cancelled = true
    }
  }, [chatId, scene, snapshotId])

  const fallbackLabel = preview.status === "loading" ? translate("tool_snapshot_loading") : translate("tool_snapshot_preview_error")

  return (
    <MediaPreviewShell
      item={{ ...item, src: preview.src, fallbackLabel }}
      modalLabel={translate("tool_snapshot_preview")}
      thumbnailClassName="w-full sm:w-72"
    />
  )
}

export function WhiteboardScenePreview({ scene, item }: { scene: Partial<ChatWhiteboardScene>; item: MediaPreviewItem }) {
  const [preview, setPreview] = useState<PreviewState>({ status: "loading", src: null })

  useEffect(() => {
    let cancelled = false

    void renderScene(scene)
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

async function renderSnapshotPreviewSource(chatId: string | undefined, snapshotId: string | undefined, embeddedScene?: ChatWhiteboardScene | null) {
  if (!embeddedScene && (!chatId || !snapshotId)) throw new Error("A snapshot reference or embedded scene is required")
  const snapshotScene = embeddedScene ?? (await fetchWhiteboardSnapshot(chatId!, snapshotId!)).scene_json
  const scene = normalizeWhiteboardScene(snapshotScene)
  const excalidraw = await import("./whiteboardSceneRenderer")
  const elements = embeddedScene
    ? excalidraw.convertToExcalidrawElements(scene.elements as Parameters<typeof excalidraw.convertToExcalidrawElements>[0])
    : asExcalidrawElements(scene.elements)
  const svg = await excalidraw.exportToSvg({
    elements,
    appState: { ...scene.appState, exportBackground: true },
    files: scene.files
  })

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`
}

async function renderScene(input: Partial<ChatWhiteboardScene> | null | undefined) {
  const scene = normalizeWhiteboardScene(input)
  const excalidraw = await import("./whiteboardSceneRenderer")
  const svg = await excalidraw.exportToSvg({
    elements: excalidraw.convertToExcalidrawElements(scene.elements as Parameters<typeof excalidraw.convertToExcalidrawElements>[0]),
    appState: { ...scene.appState, exportBackground: true },
    files: scene.files
  })

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`
}
