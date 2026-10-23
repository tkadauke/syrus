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
  chatId: string
  snapshotId: string
  item: MediaPreviewItem
  scene?: ChatWhiteboardScene | null
}) {
  const [preview, setPreview] = useState<PreviewState>({ status: "loading", src: null })

  useEffect(() => {
    let cancelled = false

    void renderSnapshot(chatId, snapshotId, scene)
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

function translate(key: string) {
  return i18n.t(`whiteboard:${key}`)
}

async function renderSnapshot(chatId: string, snapshotId: string, embeddedScene?: ChatWhiteboardScene | null) {
  const snapshotScene = embeddedScene ?? (await fetchWhiteboardSnapshot(chatId, snapshotId)).scene_json
  const scene = normalizeWhiteboardScene(snapshotScene)
  const { exportToSvg } = await import("@excalidraw/excalidraw")
  const svg = await exportToSvg({
    elements: asExcalidrawElements(scene.elements),
    appState: { ...scene.appState, exportBackground: true },
    files: scene.files
  })

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`
}
