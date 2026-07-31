import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ErrorInfo, MouseEvent as ReactMouseEvent, ReactNode } from "react"
import { Component, useCallback, useEffect, useRef, useState } from "react"
import { Link } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import { ApiError } from "../../api/client"
import { formatClock } from "../../components/WalkthroughRecorder"
import { updateRecentChatCache } from "../../lib/chatCache"
import { createWhiteboardSnapshot, fetchChatWhiteboard, fetchWhiteboardSnapshot, fetchWhiteboardSnapshots, patchChatWhiteboard, updateChatProvider, fetchCodingFileTree, fetchCodingCommits, fetchCodingFileContent, fetchCodingDiff, updateChatMode, type ChatMode, type ChatPayload, type ChatRenderItem, type ChatWhiteboardElement, type ChatWhiteboardScene, type WhiteboardSnapshot } from "../../api/chats"
import { CloseIcon } from "../../components/CloseIcon"
import { ProviderAvailabilityWarning } from "../../components/ProviderAvailabilityWarning"
import { createConsumer, type Subscription } from "@rails/actioncable"
import { useT } from "../../hooks/useT"
import { ChatJobStatusPanel } from "../ChatJobStatusPanel"
import { errorMessage } from "../../lib/errorMessage"
import { highlightCode, inferToolResultLanguage } from "../../lib/syntaxHighlight"
import { asExcalidrawElements, asExcalidrawFiles, cleanWhiteboardAppState, cleanWhiteboardFiles, cloneWhiteboardScene, signatureForScene, whiteboardScene, withFreshElementIds } from "./whiteboardScene"
import { type ChatQueryKey, WHITEBOARD_MAX_ELEMENTS, WHITEBOARD_SAVE_DEBOUNCE_MS } from "./constants"
import { chatDisplayTitle, codingFilesTabVisible, jobsTabVisible, snapshotKindLabel, secondaryButton, errorAsError, formatCurrency, formatTokenCount, truncateSnapshotName, withRoutePrefix } from "./utils"
import { ImageLightbox } from "./MessageCards"
import { Attachments } from "./Attachments"
import type { WorkspaceTab } from "./workspaceTabs"
import type { ChatMessageImageAttachment } from "./messageDisplay"
import type { FileTreeNode } from "./fileTree"
import { buildFileTree } from "./fileTree"
import { attachmentDataUrl, imageAttachments } from "./messageDisplay"
import { defaultWorkspaceTab, workspaceTabClass, workspaceTabLabel } from "./workspaceTabs"
import { diffGutterClass, diffLineClass, diffMarkerClass, parseUnifiedDiff } from "../jobDetail/diffRendering"





export type ExcalidrawComponent = typeof import("@excalidraw/excalidraw")["Excalidraw"]
export type ExcalidrawApi = Pick<ExcalidrawImperativeAPI, "addFiles" | "updateScene">
// Chat workspace panels extracted from Chat.tsx: the workspace tab shell
// (ChatWorkspacePanel) and its panels — local diff, media gallery, settings
// dialog, whiteboard, coding files — plus the shared PanelMessage primitive.
// Depends only on leaf modules and shared UI imports; unused header imports pruned.

export function ChatWorkspacePanel({
  activeTab,
  fullscreen,
  showTabs = true,
  onSelectTab,
  onToggleCollapse,
  onToggleWhiteboardFullscreen,
  payload,
  prefix,
  queryKey,
  onNotice,
  onBookmarkSelect
}: {
  activeTab: WorkspaceTab
  fullscreen: boolean
  showTabs?: boolean
  onSelectTab: (tab: WorkspaceTab) => void
  onToggleCollapse?: () => void
  onToggleWhiteboardFullscreen: () => void
  payload: ChatPayload
  prefix: string
  queryKey: ChatQueryKey
  onNotice: (message: string | null) => void
  onBookmarkSelect: (messageId: number) => void
}) {
  const { t } = useT("chat")
  useEffect(() => {
    if (activeTab === "files" && !codingFilesTabVisible(payload)) {
      onSelectTab(defaultWorkspaceTab(payload))
    }
  }, [activeTab, onSelectTab, payload])

  return (
    <aside aria-label={t("aria_chat_workspace")} className={`flex min-h-0 min-w-0 flex-1 flex-col rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900 ${fullscreen ? "" : "h-full w-full"}`}>
      {fullscreen || !showTabs ? null : (
        <nav aria-label={t("aria_workspace_tabs")} className="flex items-center border-b border-gray-200 px-3 pt-3 text-sm font-medium dark:border-gray-700">
          {(["whiteboard", "context", "media", ...(codingFilesTabVisible(payload) ? (["files"] as WorkspaceTab[]) : []), ...(payload.local_tunnel_connected ? (["diff"] as WorkspaceTab[]) : []), ...(jobsTabVisible(payload) ? (["jobs"] as WorkspaceTab[]) : [])] as WorkspaceTab[]).map((tab) => (
            <button
              className={workspaceTabClass(activeTab === tab)}
              key={tab}
              onClick={() => onSelectTab(tab)}
              type="button"
            >
              {workspaceTabLabel(tab, t)}
            </button>
          ))}
          {onToggleCollapse ? (
            <button
              aria-label={t("aria_close_workspace")}
              className="ml-auto self-center rounded p-1.5 text-gray-400 transition hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onToggleCollapse}
              title={t("aria_close_panel")}
              type="button"
            >
              <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <rect height="18" rx="2" ry="2" width="18" x="3" y="3" />
                <line x1="15" x2="15" y1="3" y2="21" />
                <polyline points="18 9 15 12 18 15" />
              </svg>
            </button>
          ) : null}
        </nav>
      )}
      <div className={`min-h-0 flex-1 ${activeTab === "whiteboard" ? "overflow-hidden p-3" : activeTab === "files" ? "overflow-hidden" : "overflow-y-auto p-4"}`}>
        {activeTab === "whiteboard" ? (
          <WhiteboardBoundary>
            <WhiteboardPanel fullscreen={fullscreen} onToggleFullscreen={onToggleWhiteboardFullscreen} payload={payload} />
          </WhiteboardBoundary>
        ) : null}
        {activeTab === "context" ? <Attachments payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} /> : null}
        {activeTab === "media" ? <MediaGallery messages={payload.messages} payload={payload} queryKey={queryKey} onNotice={onNotice} /> : null}
        {activeTab === "files" ? <CodingFilesPanel payload={payload} /> : null}
        {activeTab === "diff" && payload.local_tunnel_connected ? <LocalDiffPanel /> : null}
        {activeTab === "jobs" ? <ChatJobStatusPanel chatId={payload.chat.id} /> : null}
      </div>
    </aside>
  )
}

type DiffMode = "head" | "staged"

type LocalDiffState = {
  diff: string | null
  mode: DiffMode
  loading: boolean
  error: string | null
}

function LocalDiffPanel() {
  const { t } = useT("chat")
  const [state, setState] = useState<LocalDiffState>({ diff: null, mode: "head", loading: true, error: null })
  const subscriptionRef = useRef<Subscription | null>(null)

  useEffect(() => {
    const sub = createConsumer().subscriptions.create(
      { channel: "LocalDiffChannel" },
      {
        connected() {
          // Initial diff requested automatically by channel on subscribe.
        },
        received(data: { type?: string; diff?: string | null; mode?: string; error?: string | null }) {
          if (data.type !== "diff_result") return
          const mode: DiffMode = data.mode === "staged" ? "staged" : "head"
          setState({ diff: data.diff ?? null, mode, loading: false, error: data.error ?? null })
        }
      }
    )
    subscriptionRef.current = sub
    return () => sub.unsubscribe()
  }, [])

  function refresh(mode: DiffMode) {
    setState((s) => ({ ...s, loading: true, error: null }))
    subscriptionRef.current?.perform("receive", { mode })
  }

  const { diff, mode, loading, error } = state
  const isEmpty = !loading && !error && (diff === null || diff === "")

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-2">
        <div className="flex gap-1 rounded border border-gray-200 p-0.5 dark:border-gray-700">
          <button
            className={`rounded px-2 py-0.5 text-xs font-medium transition ${mode === "head" ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"}`}
            disabled={loading}
            onClick={() => refresh("head")}
            type="button"
          >
            HEAD
          </button>
          <button
            className={`rounded px-2 py-0.5 text-xs font-medium transition ${mode === "staged" ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"}`}
            disabled={loading}
            onClick={() => refresh("staged")}
            type="button"
          >
            {t("diff_mode_staged")}
          </button>
        </div>
        <button
          aria-label={t("aria_refresh_diff")}
          className="rounded p-1 text-gray-400 transition hover:bg-gray-100 hover:text-gray-700 disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
          disabled={loading}
          onClick={() => refresh(mode)}
          title={t("aria_refresh")}
          type="button"
        >
          <svg aria-hidden="true" className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
            <path d="M23 4v6h-6" />
            <path d="M1 20v-6h6" />
            <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
          </svg>
        </button>
      </div>

      {loading && diff === null ? (
        <p className="text-sm text-gray-500 dark:text-gray-400">{t("diff_loading")}</p>
      ) : error ? (
        <p className="text-sm text-red-600 dark:text-red-400">
          {error === "not_connected" ? t("local_diff_daemon_not_connected") : t("local_diff_error", { code: error })}
        </p>
      ) : isEmpty ? (
        <p className="text-sm text-gray-500 dark:text-gray-400">
          {mode === "staged" ? t("local_diff_no_staged") : t("local_diff_no_uncommitted")}
        </p>
      ) : (
        <div className="overflow-x-auto rounded border border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-950">
          <UnifiedDiffViewer diff={diff!} />
        </div>
      )}
    </div>
  )
}

function MediaGallery({ messages, payload, queryKey, onNotice }: { messages: ChatRenderItem[]; payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const images = imageAttachments(messages)
  const walkthroughs = payload.video_walkthroughs || []
  const walkthroughStateLabel = (state: string) =>
    ({ uploaded: t("walkthrough_state_uploaded"), analyzing: t("walkthrough_state_analyzing"), analyzed: t("walkthrough_state_analyzed"), failed: t("walkthrough_state_failed") } as Record<string, string>)[state] || state
  const [lightboxImage, setLightboxImage] = useState<ChatMessageImageAttachment | null>(null)
  const [loadingSnapshotId, setLoadingSnapshotId] = useState<number | null>(null)
  const [snapshotError, setSnapshotError] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const snapshots = useQuery({
    queryKey: ["whiteboard_snapshots", String(payload.chat.id)],
    queryFn: () => fetchWhiteboardSnapshots(payload.chat.id),
    enabled: payload.chat.id != null
  })
  const whiteboardLocked = payload.agent_busy
  const snapshotItems = snapshots.data?.whiteboard_snapshots || []

  async function loadSnapshot(snapshot: WhiteboardSnapshot) {
    if (whiteboardLocked || loadingSnapshotId != null) return

    setSnapshotError(null)
    setLoadingSnapshotId(snapshot.id)
    try {
      const fullSnapshot = await fetchWhiteboardSnapshot(payload.chat.id, snapshot.id)
      const snapshotScene = cloneWhiteboardScene(fullSnapshot.scene_json || { elements: [], appState: {}, files: {} })
      const current = await fetchChatWhiteboard(payload.paths.app_whiteboard_path)
      const currentScene = cloneWhiteboardScene(current.scene_json)
      const nextElements = [
        ...currentScene.elements,
        ...withFreshElementIds(snapshotScene.elements)
      ]

      if (nextElements.length > WHITEBOARD_MAX_ELEMENTS) {
        throw new ApiError(`Loading this snapshot would exceed the ${WHITEBOARD_MAX_ELEMENTS} element limit.`, { status: 422 })
      }

      if (currentScene.elements.length > 0) {
        await createWhiteboardSnapshot(payload.chat.id, {
          scene_json: currentScene,
          snapshot_kind: "auto_before_load",
          name: `Before load · ${new Date().toLocaleString()}`
        })
      }

      const mergedScene: ChatWhiteboardScene = {
        elements: nextElements,
        appState: currentScene.appState,
        files: { ...currentScene.files, ...snapshotScene.files }
      }
      const result = await patchChatWhiteboard(payload.paths.app_whiteboard_path, {
        ...mergedScene,
        expected_version: current.version
      })
      if (result.status === 409) throw new ApiError("Whiteboard changed before the snapshot could load. Try again.", { status: 409 })

      queryClient.setQueryData<ChatPayload>(queryKey, (currentPayload) => {
        if (!currentPayload) return currentPayload

        return {
          ...currentPayload,
          whiteboard: {
            version: result.payload.version,
            elements: result.payload.scene_json.elements,
            appState: result.payload.scene_json.appState,
            files: result.payload.scene_json.files
          }
        }
      })
      await queryClient.invalidateQueries({ queryKey: ["whiteboard_snapshots", String(payload.chat.id)] })
      onNotice(t("snapshot_loaded", { name: fullSnapshot.name || t("snapshot_name_default") }))
    } catch (error) {
      setSnapshotError(errorMessage(errorAsError(error), "Snapshot could not be loaded."))
    } finally {
      setLoadingSnapshotId(null)
    }
  }

  if (images.length === 0 && snapshotItems.length === 0 && walkthroughs.length === 0 && !snapshots.isPending && !snapshots.isError) {
    return <PanelMessage>{t("media_empty")}</PanelMessage>
  }

  return (
    <div className="space-y-5">
      {snapshots.isPending ? <PanelMessage>{t("snapshots_loading")}</PanelMessage> : null}
      {snapshots.isError ? <PanelMessage tone="error">{errorMessage(snapshots.error, "Unable to load snapshots.")}</PanelMessage> : null}
      {snapshotError ? <PanelMessage tone="error">{snapshotError}</PanelMessage> : null}
      {whiteboardLocked ? <div className="rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">{t("canvas_busy")}</div> : null}

      {snapshotItems.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("whiteboard_snapshots")}</h2>
          <div className="space-y-2">
            {snapshotItems.map((snapshot) => (
              <article className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-950" key={snapshot.id}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium text-gray-900 dark:text-gray-100" title={snapshot.name || "Snapshot"}>{truncateSnapshotName(snapshot.name || "Snapshot")}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                      <span className="rounded bg-gray-100 px-1.5 py-0.5 font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{snapshotKindLabel(snapshot.snapshot_kind)}</span>
                      <span>{snapshot.element_count} {snapshot.element_count === 1 ? "element" : "elements"}</span>
                      <span><RelativeTimestamp value={snapshot.created_at} /></span>
                    </div>
                  </div>
                  <button
                    className={`${secondaryButton()} shrink-0 px-2 py-1 text-xs`}
                    disabled={whiteboardLocked || loadingSnapshotId != null}
                    onClick={() => void loadSnapshot(snapshot)}
                    type="button"
                  >
                    {loadingSnapshotId === snapshot.id ? t("common:loading") : t("snapshot_load")}
                  </button>
                </div>
              </article>
            ))}
          </div>
        </section>
      ) : null}

      {walkthroughs.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("walkthrough_media_heading")}</h2>
          <div className="space-y-2">
            {walkthroughs.map((walkthrough) => (
              <article className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-950" key={walkthrough.id}>
                <div className="flex items-start gap-3">
                  <div aria-hidden="true" className="flex h-10 w-10 shrink-0 items-center justify-center rounded bg-gray-100 text-lg dark:bg-gray-800">🎥</div>
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm font-medium text-gray-900 dark:text-gray-100" title={walkthrough.title}>{walkthrough.title}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                      {walkthrough.duration_seconds != null ? <span className="tabular-nums">{formatClock(walkthrough.duration_seconds)}</span> : null}
                      <span className="rounded bg-gray-100 px-1.5 py-0.5 font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{walkthroughStateLabel(walkthrough.state)}</span>
                      <span><RelativeTimestamp value={walkthrough.created_at} /></span>
                    </div>
                    {walkthrough.state === "failed" && walkthrough.error_message ? (
                      <p className="mt-1 text-xs text-red-600 dark:text-red-400">{walkthrough.error_message}</p>
                    ) : null}
                    {!walkthrough.has_video && walkthrough.state !== "failed" ? (
                      <p className="mt-1 text-xs text-gray-400 dark:text-gray-500">{t("walkthrough_media_expired")}</p>
                    ) : null}
                  </div>
                </div>
              </article>
            ))}
          </div>
        </section>
      ) : null}

      {images.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("image_attachments")}</h2>
          <div className="grid grid-cols-3 gap-2">
            {images.map(({ attachment, key }) => {
              const src = attachmentDataUrl(attachment)
              const name = attachment.name || "image attachment"

              return (
                <figure className="group/media min-w-0 space-y-1" key={key}>
                  <div className="relative aspect-square overflow-hidden rounded border border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-950">
                    <button
                      aria-label={`Open ${name}`}
                      className="h-full w-full p-0 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-blue-500"
                      onClick={() => setLightboxImage(attachment)}
                      title={name}
                      type="button"
                    >
                      <img alt={name} className="h-full w-full object-contain transition group-hover/media:scale-105" src={src} />
                    </button>
                    <a
                      aria-label={`Download ${name}`}
                      className="absolute right-1 top-1 rounded bg-white/90 px-2 py-1 text-xs font-medium text-gray-700 opacity-0 shadow transition hover:bg-white hover:text-gray-900 focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-blue-500 group-hover/media:opacity-100 dark:bg-gray-900/90 dark:text-gray-200 dark:hover:bg-gray-900"
                      download={attachment.name || "image"}
                      href={src}
                    >
                      {t("image_download")}
                    </a>
                  </div>
                  <figcaption className="truncate text-xs text-gray-600 dark:text-gray-300" title={name}>{name}</figcaption>
                </figure>
              )
            })}
          </div>
        </section>
      ) : null}
      {lightboxImage ? <ImageLightbox attachment={lightboxImage} onClose={() => setLightboxImage(null)} /> : null}
    </div>
  )
}

export function ChatSettingsDialog({ payload, prefix, queryKey, onClose }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onClose: () => void }) {
  const queryClient = useQueryClient()
  const { t } = useT("chat")
  const providerOptions = payload.chat.chat_provider_options || []
  const configuredExplicitOptions = providerOptions.filter((option) => option.value && option.configured)
  const showProviderSelector = configuredExplicitOptions.length > 1
  const provider = useMutation({
    mutationFn: (value: string) => updateChatProvider(payload.chat.id, value || null),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, updated.chat)
    }
  })

  const modeOptions: Array<{ value: ChatMode; label: string }> = [
    { value: "planning", label: t("mode_planning") },
    ...(payload.coding_mode_enabled ? [{ value: "coding" as ChatMode, label: t("mode_coding") }] : []),
    ...(payload.local_mode_enabled ? [{ value: "local" as ChatMode, label: t("mode_local") }] : [])
  ]
  const mode = useMutation({
    mutationFn: (value: string) => updateChatMode(payload.chat.id, value as ChatMode || null),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, updated.chat)
    }
  })

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" role="presentation">
      <section aria-modal="true" aria-labelledby="chat-settings-title" className="w-full max-w-md rounded border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900" role="dialog">
        <div className="mb-4 flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="chat-settings-title">{t("chat_settings")}</h2>
            <p className="mt-1 break-words text-sm text-gray-600 dark:text-gray-300">{chatDisplayTitle(payload.chat)}</p>
          </div>
          <button aria-label={t("aria_close_settings")} className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <div className="space-y-3 text-sm">
          {showProviderSelector ? (
            <label className="block">
              <span className="mb-1 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("provider")}</span>
              <select
                aria-label={t("aria_chat_provider")}
                className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-gray-100 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:disabled:bg-gray-800"
                disabled={provider.isPending}
                onChange={(event) => provider.mutate(event.target.value)}
                value={payload.chat.chat_provider || ""}
              >
                {providerOptions.map((option) => (
                  <option disabled={!option.configured} key={option.value || "default"} value={option.value || ""}>
                    {option.label}
                  </option>
                ))}
              </select>
              <span className="mt-1 flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
                <span>{t("chat_settings_effective_provider", { label: payload.chat.effective_chat_provider_label || t("chat_settings_effective_default") })}</span>
                <ProviderAvailabilityWarning availability={payload.chat.provider_availability} />
              </span>
            </label>
          ) : null}
          {provider.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(provider.error, t("provider_update_error"))}</div> : null}
          <label className="block">
            <span className="mb-1 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mode_label")}</span>
            <div className="flex rounded border border-gray-300 bg-white dark:border-gray-700 dark:bg-gray-950" role="group" aria-label={t("mode_label")}>
              {modeOptions.map(({ value, label }) => (
                <button
                  className={[
                    "flex-1 px-3 py-2 text-sm first:rounded-l last:rounded-r focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-terracotta-500",
                    (payload.chat.mode || "planning") === value
                      ? "bg-terracotta-600 font-medium text-white"
                      : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800",
                    mode.isPending ? "cursor-not-allowed opacity-50" : ""
                  ].join(" ")}
                  disabled={mode.isPending}
                  key={value}
                  onClick={() => mode.mutate(value)}
                  type="button"
                >
                  {label}
                </button>
              ))}
            </div>
            <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("mode_hint")}</span>
          </label>
          {mode.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(mode.error, t("mode_update_error"))}</div> : null}
          {payload.chat.repository?.repository_path ? (
            <Link className="block rounded border border-gray-200 px-3 py-2 text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:text-gray-200 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200" onClick={onClose} to={withRoutePrefix(`${payload.chat.repository.repository_path}/edit`, prefix)}>
              {t("chat_settings_repo")}
            </Link>
          ) : null}
          <Link className="block rounded border border-gray-200 px-3 py-2 text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:text-gray-200 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200" onClick={onClose} to={withRoutePrefix("/credentials", prefix)}>
            {t("chat_settings_credentials")}
          </Link>
        </div>
      </section>
    </div>
  )
}

type WhiteboardBoundaryState = {
  failed: boolean
}

function WhiteboardErrorFallback() {
  const { t } = useT("chat")
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

function WhiteboardPanel({ fullscreen, onToggleFullscreen, payload }: { fullscreen: boolean; onToggleFullscreen: () => void; payload: ChatPayload }) {
  const { t } = useT("chat")
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
      applyRemoteScene(current.scene_json, current.version)
      const retry = await patchChatWhiteboard(pathRef.current, {
        ...originalScene,
        expected_version: current.version
      })
      if (retry.status === 409) throw new ApiError("Whiteboard changed again before the retry completed.", { status: 409 })

      applyRemoteScene(retry.payload.scene_json, retry.payload.version)
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

      applyRemoteScene(result.payload.scene_json, result.payload.version)
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

  return (
    <section className="flex h-full min-h-0 flex-col">
      <div className="mb-2 flex items-center justify-between gap-3">
        <div className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("whiteboard_title")}</div>
        <div className="flex items-center gap-2">
          <button
            aria-pressed={fullscreen}
            className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
            onClick={onToggleFullscreen}
            type="button"
          >
            {fullscreen ? t("fullscreen_exit") : t("fullscreen_enter")}
          </button>
        </div>
      </div>
      <div className="relative min-h-0 flex-1 overflow-hidden rounded border border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-950">
        {Excalidraw ? (
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
}

export function UsageOverlay({ payload }: { payload: ChatPayload }) {
  return (
    <p className="pointer-events-none absolute left-0 right-0 top-0 border-b border-gray-100 bg-white/95 px-4 py-1.5 text-xs text-gray-500 dark:border-gray-800 dark:bg-gray-950/95 dark:text-gray-400">
      Tokens: {formatTokenCount(payload.chat.cumulative_input_tokens)} in / {formatTokenCount(payload.chat.cumulative_output_tokens)} out · {formatCurrency(payload.chat.cumulative_cost_usd)}
    </p>
  )
}

export function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-800 dark:bg-green-950 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function FileTreeEntry({
  node,
  openDirs,
  selectedFile,
  onToggleDir,
  onSelectFile,
  depth
}: {
  node: FileTreeNode
  openDirs: Set<string>
  selectedFile: string | null
  onToggleDir: (path: string) => void
  onSelectFile: (path: string) => void
  depth: number
}) {
  const indent = depth * 12
  if (node.type === "directory") {
    const open = openDirs.has(node.path)
    return (
      <div>
        <button
          className="flex w-full items-center gap-1 px-2 py-0.5 text-left text-xs text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"
          onClick={() => onToggleDir(node.path)}
          style={{ paddingLeft: `${indent + 8}px` }}
          type="button"
        >
          <span aria-hidden="true" className="shrink-0 font-mono text-gray-400 dark:text-gray-500">{open ? "▾" : "▸"}</span>
          <span className="truncate font-medium">{node.name}</span>
        </button>
        {open ? (
          <div>
            {node.children.map((child) => (
              <FileTreeEntry
                depth={depth + 1}
                key={child.path}
                node={child}
                openDirs={openDirs}
                selectedFile={selectedFile}
                onSelectFile={onSelectFile}
                onToggleDir={onToggleDir}
              />
            ))}
          </div>
        ) : null}
      </div>
    )
  }

  const selected = selectedFile === node.path
  return (
    <button
      className={`flex w-full items-center gap-1 px-2 py-0.5 text-left text-xs ${selected ? "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"}`}
      onClick={() => onSelectFile(node.path)}
      style={{ paddingLeft: `${indent + 8}px` }}
      title={node.path}
      type="button"
    >
      <span className="truncate font-mono">{node.name}</span>
    </button>
  )
}

function CodingFilesPanel({ payload }: { payload: ChatPayload }) {
  const { t } = useT("chat")
  const [view, setView] = useState<"files" | "diff">("files")
  const [diffMode, setDiffMode] = useState<"cumulative" | "turn">("cumulative")
  const [selectedFile, setSelectedFile] = useState<string | null>(null)
  const [selectedDiffFile, setSelectedDiffFile] = useState<string | null>(null)
  const [selectedRef, setSelectedRef] = useState<string>("")
  const [openDirs, setOpenDirs] = useState<Set<string>>(new Set())

  const filesPath = payload.paths.app_coding_files_path
  const commitsPath = payload.paths.app_coding_commits_path
  const fileContentBasePath = payload.paths.app_coding_file_path
  const diffPath = payload.paths.app_coding_diff_path
  const agentBusy = payload.agent_busy
  const refetchInterval = agentBusy ? 3000 : 15000

  const fileTree = useQuery({
    queryKey: ["coding_files", filesPath, selectedRef],
    queryFn: () => fetchCodingFileTree(filesPath!, selectedRef || null),
    enabled: !!filesPath,
    refetchInterval
  })

  const commits = useQuery({
    queryKey: ["coding_commits", commitsPath],
    queryFn: () => fetchCodingCommits(commitsPath!),
    enabled: !!commitsPath,
    refetchInterval
  })

  const fileContent = useQuery({
    queryKey: ["coding_file_content", fileContentBasePath, selectedFile, selectedRef],
    queryFn: () => fetchCodingFileContent(fileContentBasePath!, selectedFile!, selectedRef || null),
    enabled: !!fileContentBasePath && !!selectedFile && view === "files",
    refetchInterval
  })

  const diffResult = useQuery({
    queryKey: ["coding_diff", diffPath, diffMode, selectedRef],
    queryFn: () => fetchCodingDiff(diffPath!, diffMode, selectedRef || null),
    enabled: !!diffPath && view === "diff",
    refetchInterval
  })

  function toggleDir(path: string) {
    setOpenDirs((prev) => {
      const next = new Set(prev)
      if (next.has(path)) next.delete(path)
      else next.add(path)
      return next
    })
  }

  const treeNodes = fileTree.data ? buildFileTree(fileTree.data.files) : []
  const commitOptions = commits.data?.commits ?? []
  const diffFiles = diffResult.data?.diff ? parseCodingDiffFiles(diffResult.data.diff) : []
  const selectedDiff = selectedDiffFile ? diffFiles.find((file) => file.path === selectedDiffFile) || null : null

  useEffect(() => {
    if (selectedDiffFile && !diffFiles.some((file) => file.path === selectedDiffFile)) {
      setSelectedDiffFile(null)
    }
  }, [diffFiles, selectedDiffFile])

  useEffect(() => {
    if (selectedFile && fileTree.data && !fileTree.data.files.includes(selectedFile)) {
      setSelectedFile(null)
    }
  }, [fileTree.data, selectedFile])

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex shrink-0 items-center gap-1 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
        <button
          className={`rounded px-2 py-1 text-xs font-medium ${view === "files" ? "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200" : "text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"}`}
          onClick={() => setView("files")}
          type="button"
        >
          {t("view_files")}
        </button>
        <button
          className={`rounded px-2 py-1 text-xs font-medium ${view === "diff" ? "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200" : "text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"}`}
          onClick={() => setView("diff")}
          type="button"
        >
          {t("view_diff")}
        </button>
        {view === "diff" && !selectedRef ? (
          <div className="ml-auto flex items-center gap-1">
            <button
              className={`rounded px-2 py-1 text-xs ${diffMode === "cumulative" ? "font-semibold text-gray-900 dark:text-gray-100" : "text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"}`}
              onClick={() => setDiffMode("cumulative")}
              type="button"
            >
              {t("diff_tab_cumulative")}
            </button>
            <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">·</span>
            <button
              className={`rounded px-2 py-1 text-xs ${diffMode === "turn" ? "font-semibold text-gray-900 dark:text-gray-100" : "text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"}`}
              onClick={() => setDiffMode("turn")}
              type="button"
            >
              {t("diff_tab_turn")}
            </button>
          </div>
        ) : null}
      </div>
      <div className="shrink-0 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
        <select
          aria-label={t("commit_selector_label")}
          className="w-full rounded border border-gray-200 bg-white px-2 py-1 font-mono text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
          onChange={(event) => {
            setSelectedRef(event.target.value)
            setSelectedFile(null)
            setSelectedDiffFile(null)
          }}
          value={selectedRef}
        >
          <option value="">{t("commit_selector_head")}</option>
          {commitOptions.map((commit) => (
            <option key={commit.sha} value={commit.sha}>
              {commit.sha.slice(0, 7)} · {commit.date.slice(0, 16)} · {truncateCommitMessage(commit.message)}
            </option>
          ))}
        </select>
      </div>

      {view === "files" ? (
        <div className="flex min-h-0 flex-1">
          <div className="w-48 shrink-0 overflow-y-auto border-r border-gray-200 py-1 dark:border-gray-700">
            {fileTree.isPending ? (
              <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">{t("files_loading")}</p>
            ) : fileTree.isError ? (
              <p className="px-3 py-2 text-xs text-red-600 dark:text-red-400">{t("files_error")}</p>
            ) : treeNodes.length === 0 ? (
              <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">{t("files_empty")}</p>
            ) : (
              treeNodes.map((node) => (
                <FileTreeEntry
                  depth={0}
                  key={node.path}
                  node={node}
                  openDirs={openDirs}
                  selectedFile={selectedFile}
                  onSelectFile={setSelectedFile}
                  onToggleDir={toggleDir}
                />
              ))
            )}
          </div>
          <div className="min-w-0 flex-1 overflow-y-auto">
            {!selectedFile ? (
              <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("file_content_empty")}</p>
            ) : fileContent.isPending ? (
              <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("file_content_loading")}</p>
            ) : fileContent.isError ? (
              <p className="px-4 py-3 text-xs text-red-600 dark:text-red-400">{t("file_content_error")}</p>
            ) : fileContent.data?.binary ? (
              <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("file_content_binary")}</p>
            ) : fileContent.data?.too_large ? (
              <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("file_content_too_large")}</p>
            ) : (
              <CodingSourceViewer content={fileContent.data?.content ?? ""} path={selectedFile} />
            )}
          </div>
        </div>
      ) : (
        <div className="min-h-0 flex-1">
          {diffResult.isPending ? (
            <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("diff_loading")}</p>
          ) : diffResult.isError ? (
            <p className="px-4 py-3 text-xs text-red-600 dark:text-red-400">{t("diff_error")}</p>
          ) : !diffResult.data?.diff ? (
            <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("diff_empty")}</p>
          ) : (
            <div className="grid h-full min-h-0 overflow-hidden lg:grid-cols-[16rem_minmax(0,1fr)]">
              <div className="overflow-y-auto border-b border-gray-200 bg-gray-50 py-1 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
                {diffFiles.map((file) => (
                  <button
                    className={`flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs hover:bg-blue-50 dark:hover:bg-blue-950/40 ${selectedDiff?.path === file.path ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200" : "text-gray-700 dark:text-gray-300"}`}
                    key={file.path}
                    onClick={() => setSelectedDiffFile(file.path)}
                    title={`${file.path} (+${file.additions} -${file.deletions})`}
                    type="button"
                  >
                    <CodingDiffStatusBadge status={file.status} />
                    <span className="min-w-0 flex-1 truncate">{file.path}</span>
                  </button>
                ))}
              </div>
              <div className="min-w-0 overflow-auto">
                {selectedDiff ? (
                  <>
                    <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
                      <span className="min-w-0 flex-1 truncate">{selectedDiff.path}</span>
                      <span>+{selectedDiff.additions}</span>
                      <span>-{selectedDiff.deletions}</span>
                    </div>
                    <UnifiedDiffViewer diff={selectedDiff.patch} testId="coding-diff-viewer" />
                  </>
                ) : (
                  <div className="flex h-full min-h-[16rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_diff_file")}</div>
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

type CodingDiffFile = {
  path: string
  patch: string
  status: "added" | "modified" | "removed" | "renamed"
  additions: number
  deletions: number
}

function truncateCommitMessage(message: string) {
  return message.length > 72 ? `${message.slice(0, 69)}...` : message
}

function CodingSourceViewer({ content, path }: { content: string; path: string }) {
  const language = inferToolResultLanguage(path, "Read")
  const lines = content.split("\n")

  return (
    <table className="min-w-full border-separate border-spacing-0 font-mono text-xs" data-testid="coding-source-viewer">
      <tbody>
        {lines.map((line, index) => {
          const lineNum = index + 1
          return (
            <tr className="bg-white dark:bg-gray-950" data-line={lineNum} key={lineNum}>
              <td className="w-10 select-none px-2 py-0.5 text-right text-xs text-gray-400 dark:text-gray-600">{lineNum}</td>
              <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 leading-relaxed text-gray-900 dark:text-gray-100">
                {language ? highlightCode(line, language) : line}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}

function UnifiedDiffViewer({ diff, testId }: { diff: string; testId?: string }) {
  const lines = parseUnifiedDiff(diff)

  return (
    <table className="min-w-full border-separate border-spacing-0 font-mono text-xs" data-testid={testId}>
      <tbody>
        {lines.map((line, index) => (
          <tr className={diffLineClass(line.kind)} data-diff-kind={line.kind} key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
            <td className={diffGutterClass(line.kind)}>{line.oldLine ?? ""}</td>
            <td className={diffGutterClass(line.kind)}>{line.newLine ?? ""}</td>
            <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
            <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200">{line.code || " "}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function CodingDiffStatusBadge({ status }: { status: CodingDiffFile["status"] }) {
  const styles: Record<CodingDiffFile["status"], string> = {
    added: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-200",
    modified: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-200",
    removed: "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-200",
    renamed: "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200"
  }
  const labels: Record<CodingDiffFile["status"], string> = { added: "A", modified: "M", removed: "D", renamed: "R" }

  return <span className={`inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-[11px] font-semibold ${styles[status]}`}>{labels[status]}</span>
}

function parseCodingDiffFiles(diff: string): CodingDiffFile[] {
  const rawLines = diff.replace(/\r\n/g, "\n").split("\n")
  const sections: string[][] = []
  let current: string[] = []

  for (const line of rawLines) {
    if (line.startsWith("diff --git ") && current.length > 0) {
      sections.push(current)
      current = []
    }
    if (line || current.length > 0) current.push(line)
  }
  if (current.length > 0) sections.push(current)

  return sections.map((lines) => {
    const patch = lines.join("\n").replace(/\n$/, "")
    const parsedLines = parseUnifiedDiff(patch)
    const additions = parsedLines.filter((line) => line.kind === "add").length
    const deletions = parsedLines.filter((line) => line.kind === "delete").length
    return {
      additions,
      deletions,
      patch,
      path: codingDiffPath(lines),
      status: codingDiffStatus(lines)
    }
  })
}

function codingDiffPath(lines: string[]) {
  const renameTo = lines.find((line) => line.startsWith("rename to "))?.replace(/^rename to /, "")
  if (renameTo) return renameTo

  const newPath = diffHeaderPath(lines.find((line) => line.startsWith("+++ ")))
  if (newPath) return newPath

  return diffHeaderPath(lines.find((line) => line.startsWith("--- "))) || diffGitPath(lines[0]) || "unknown"
}

function diffHeaderPath(line: string | undefined) {
  if (!line) return null
  const path = line.replace(/^(---|\+\+\+) /, "").trim()
  if (path === "/dev/null") return null
  return path.replace(/^[ab]\//, "")
}

function diffGitPath(line: string | undefined) {
  const match = line?.match(/^diff --git a\/(.+) b\/(.+)$/)
  return match?.[2] || match?.[1] || null
}

function codingDiffStatus(lines: string[]): CodingDiffFile["status"] {
  if (lines.some((line) => line.startsWith("new file mode "))) return "added"
  if (lines.some((line) => line.startsWith("deleted file mode "))) return "removed"
  if (lines.some((line) => line.startsWith("rename from ") || line.startsWith("rename to "))) return "renamed"
  return "modified"
}

export function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function isPlainAnchorClick(event: ReactMouseEvent<HTMLAnchorElement>) {
  return event.button === 0 && !event.defaultPrevented && !event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey
}
