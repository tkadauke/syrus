import { useEffect, useState } from "react"
import { fetchWhiteboardSnapshot } from "@app/api/chats"
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

function translate(key: string) {
  return i18n.t(`whiteboard:${key}`)
}

async function renderSnapshot(chatId: string, snapshotId: string) {
  const snapshot = await fetchWhiteboardSnapshot(chatId, snapshotId)
  const scene = normalizeWhiteboardScene(snapshot.scene_json)
  const { exportToSvg } = await import("@excalidraw/excalidraw")
  const svg = await exportToSvg({
    elements: asExcalidrawElements(scene.elements),
    appState: { ...scene.appState, exportBackground: true },
    files: scene.files
  })

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`
}
