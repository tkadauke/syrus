import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import type { ErrorInfo, ReactNode } from "react"
import { Component, useCallback, useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import "@excalidraw/excalidraw/index.css"
import { ApiError } from "@app/api/client"
import { fetchChatWhiteboard, patchChatWhiteboard, type ChatPayload, type ChatWhiteboardElement, type ChatWhiteboardScene } from "@app/api/chats"
import { errorMessage } from "@app/lib/errorMessage"
import { errorAsError } from "@app/routes/chat/utils"
import { WHITEBOARD_SAVE_DEBOUNCE_MS } from "@app/routes/chat/constants"
import { asExcalidrawElements, asExcalidrawFiles, cleanWhiteboardAppState, cleanWhiteboardFiles, cloneWhiteboardScene, normalizeWhiteboardScene, signatureForScene, whiteboardScene } from "@app/routes/chat/whiteboardScene"
import { useT } from "@app/hooks/useT"
import type { PluginWorkspaceTabProps } from "@app/pluginWorkspaceTabs"

// Whiteboard workspace tab (see WhiteboardTools::WorkspaceTabs /
// config/syrus_docs/plugins.md). Ported from the core WhiteboardPanel that
// used to render behind a hardcoded "whiteboard" tab id. The plugin
// :workspace_tab extension point only hands a component `payload:
// ChatPayload` -- no fullscreen prop/callback exists on that contract, so
// fullscreen is owned entirely in here: local state plus a fixed, full
// -viewport portal into document.body (Escape or the toggle button exits),
// rather than the old core-threaded layout-shift (hide the chat column,
// hide the tab bar) that Chat.tsx used to implement for this one tab.
type ExcalidrawComponent = typeof import("@excalidraw/excalidraw")["Excalidraw"]
type ExcalidrawApi = Pick<ExcalidrawImperativeAPI, "addFiles" | "updateScene">

export default function WhiteboardTab({ payload }: PluginWorkspaceTabProps) {
  return (
    <WhiteboardBoundary>
      <WhiteboardPanel payload={payload} />
    </WhiteboardBoundary>
  )
}

type WhiteboardBoundaryState = {
  failed: boolean
}

function WhiteboardErrorFallback() {
  const { t } = useT("whiteboard_tools")
  return (
    <section>
      <div className="mb-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("whiteboard_title")}</div>
      <div className="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
        {t("whiteboard_unavailable")}
      </div>
    </section>
  )
}

class WhiteboardBoundary extends Component<{ children: ReactNode }, WhiteboardBoundaryState> {
  state: WhiteboardBoundaryState = { failed: false }

  static getDerivedStateFromError(): WhiteboardBoundaryState {
    return { failed: true }
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Whiteboard render failed.", error, errorInfo)
  }

  render() {
    if (this.state.failed) {
      return <WhiteboardErrorFallback />
    }

    return this.props.children
  }
}

function WhiteboardPanel({ payload }: { payload: ChatPayload }) {
  const { t } = useT("whiteboard_tools")
  const queryClient = useQueryClient()
  const [fullscreen, setFullscreen] = useState(false)
  const [Excalidraw, setExcalidraw] = useState<ExcalidrawComponent | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [scene, setScene] = useState<ChatWhiteboardScene>(() => whiteboardScene(payload))
  const apiRef = useRef<ExcalidrawApi | null>(null)
  const appliedSignatureRef = useRef(signatureForScene(scene))
  const chatIdRef = useRef(payload.chat.id)
  const pathRef = useRef(payload.paths.app_whiteboard_path)
  const pendingSceneRef = useRef<ChatWhiteboardScene | null>(null)
  const remoteUpdateInProgressRef = useRef(false)
  const retryingConflictRef = useRef(false)
  const saveTimerRef = useRef<number | null>(null)
  const versionRef = useRef(payload.whiteboard.version)
  const whiteboardLoaded = payload.whiteboard.loaded ?? payload.whiteboard.elements.length > 0
  const whiteboard = useQuery({
    queryKey: ["chat_whiteboard", String(payload.chat.id)],
    queryFn: () => fetchChatWhiteboard(payload.paths.app_whiteboard_path),
    enabled: payload.chat.id != null && !whiteboardLoaded
  })
  const whiteboardLoading = !whiteboardLoaded && whiteboard.isPending

  useEffect(() => {
    if (!fullscreen) return

    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") setFullscreen(false)
    }

    window.addEventListener("keydown", handleKeyDown)
    return () => window.removeEventListener("keydown", handleKeyDown)
  }, [fullscreen])

  useEffect(() => {
    setFullscreen(false)
  }, [payload.chat.id])

  const clearPendingSave = useCallback(() => {
    if (saveTimerRef.current == null) return

    window.clearTimeout(saveTimerRef.current)
    saveTimerRef.current = null
  }, [])

  const applyRemoteScene = useCallback((nextScene: ChatWhiteboardScene, nextVersion: number) => {
    remoteUpdateInProgressRef.current = true
    const copied = cloneWhiteboardScene(nextScene)
    appliedSignatureRef.current = signatureForScene(copied)
    setScene(copied)
    apiRef.current?.addFiles(asExcalidrawFiles(copied.files))
    apiRef.current?.updateScene({
      elements: asExcalidrawElements(copied.elements),
      appState: copied.appState as never
    })
    versionRef.current = nextVersion
    queueMicrotask(() => {
      remoteUpdateInProgressRef.current = false
    })
  }, [])

  const recoverConflict = useCallback(async (originalScene: ChatWhiteboardScene) => {
    if (retryingConflictRef.current) return

    retryingConflictRef.current = true
    try {
      const current = await fetchChatWhiteboard(pathRef.current)
      applyRemoteScene(normalizeWhiteboardScene(current.scene_json), current.version)
      const retry = await patchChatWhiteboard(pathRef.current, {
        ...originalScene,
        expected_version: current.version
      })
      if (retry.status === 409) throw new ApiError("Whiteboard changed again before the retry completed.", { status: 409 })

      applyRemoteScene(normalizeWhiteboardScene(retry.payload.scene_json), retry.payload.version)
    } finally {
      retryingConflictRef.current = false
    }
  }, [applyRemoteScene])

  const savePending = useCallback(async () => {
    const pendingScene = pendingSceneRef.current
    if (!pendingScene) return

    pendingSceneRef.current = null
    setSaveError(null)
    try {
      const result = await patchChatWhiteboard(pathRef.current, {
        ...pendingScene,
        expected_version: versionRef.current
      })
      if (result.status === 409) {
        await recoverConflict(pendingScene)
        return
      }

      applyRemoteScene(normalizeWhiteboardScene(result.payload.scene_json), result.payload.version)
    } catch (error) {
      setSaveError(errorMessage(errorAsError(error), "Whiteboard save failed."))
    }
  }, [applyRemoteScene, recoverConflict])

  useEffect(() => {
    let cancelled = false
    void import("@excalidraw/excalidraw")
      .then((module) => {
        if (!cancelled) setExcalidraw(() => module.Excalidraw)
      })
      .catch((error: unknown) => {
        if (!cancelled) setLoadError(errorMessage(errorAsError(error), "Unable to load the whiteboard."))
      })

    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    pathRef.current = payload.paths.app_whiteboard_path
  }, [payload.paths.app_whiteboard_path])

  useEffect(() => {
    const nextScene = whiteboardScene(payload)
    const chatChanged = chatIdRef.current !== payload.chat.id
    if (!chatChanged && payload.whiteboard.version <= versionRef.current) return

    chatIdRef.current = payload.chat.id
    applyRemoteScene(nextScene, payload.whiteboard.version)
  }, [applyRemoteScene, payload])

  useEffect(() => {
    const data = whiteboard.data
    if (!data) return

    queryClient.setQueriesData<ChatPayload>({ queryKey: ["chats", String(payload.chat.id)] }, (currentPayload) => currentPayload ? {
      ...currentPayload,
      whiteboard: {
        version: data.version,
        ...normalizeWhiteboardScene(data.scene_json),
        loaded: true
      }
    } : currentPayload)
    applyRemoteScene(normalizeWhiteboardScene(data.scene_json), data.version)
  }, [applyRemoteScene, payload.chat.id, queryClient, whiteboard.data])

  useEffect(() => () => {
    clearPendingSave()
    const pendingScene = pendingSceneRef.current
    if (pendingScene) {
      void patchChatWhiteboard(pathRef.current, {
        ...pendingScene,
        expected_version: versionRef.current
      }).catch(() => {})
    }
  }, [clearPendingSave])

  const handleChange = useCallback((nextElements: readonly ChatWhiteboardElement[], nextAppState: unknown, nextFiles: unknown) => {
    if (remoteUpdateInProgressRef.current) return

    const copied = cloneWhiteboardScene({
      elements: Array.from(nextElements),
      appState: cleanWhiteboardAppState(nextAppState),
      files: cleanWhiteboardFiles(nextFiles)
    })
    const signature = signatureForScene(copied)
    if (signature === appliedSignatureRef.current) return

    appliedSignatureRef.current = signature
    setScene(copied)
    pendingSceneRef.current = copied
    clearPendingSave()
    saveTimerRef.current = window.setTimeout(() => {
      void savePending()
    }, WHITEBOARD_SAVE_DEBOUNCE_MS)
  }, [clearPendingSave, savePending])

  const panel = (
    <section className="flex h-full min-h-0 flex-col">
      <div className="mb-2 flex items-center justify-between gap-3">
        <div className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("whiteboard_title")}</div>
        <div className="flex items-center gap-2">
          <button
            aria-pressed={fullscreen}
            className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
            onClick={() => setFullscreen((current) => !current)}
            type="button"
          >
            {fullscreen ? t("fullscreen_exit") : t("fullscreen_enter")}
          </button>
        </div>
      </div>
      <div className="relative min-h-0 flex-1 overflow-hidden rounded border border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-950">
        {whiteboardLoading ? (
          <div className="flex h-full items-center justify-center text-sm text-gray-500 dark:text-gray-400">{t("loading_whiteboard")}</div>
        ) : whiteboard.isError ? (
          <div className="p-3 text-sm text-red-700 dark:text-red-300">{errorMessage(whiteboard.error, t("whiteboard_unavailable"))}</div>
        ) : Excalidraw ? (
          <Excalidraw
            excalidrawAPI={(api) => {
              apiRef.current = api
            }}
            initialData={{
              elements: asExcalidrawElements(scene.elements),
              appState: scene.appState as never,
              files: scene.files as never
            }}
            onChange={(nextElements, nextAppState, nextFiles) => handleChange(nextElements as readonly ChatWhiteboardElement[], nextAppState, nextFiles)}
          />
        ) : (
          <div className="flex h-full items-center justify-center p-4 text-sm text-gray-500 dark:text-gray-400">
            {loadError || t("canvas_loading")}
          </div>
        )}
        {scene.elements.length === 0 ? (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center px-6 text-center text-sm text-gray-400 dark:text-gray-500">
            {t("canvas_empty_hint")}
          </div>
        ) : null}
      </div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {saveError || t("canvas_elements", { count: scene.elements.length })}
      </div>
    </section>
  )

  if (!fullscreen) return <div className="h-full min-h-0 p-3">{panel}</div>

  return createPortal(
    <div className="fixed inset-0 z-50 flex flex-col bg-white p-3 dark:bg-gray-950">
      {panel}
    </div>,
    document.body
  )
}
