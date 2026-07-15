import { useMutation, useQuery, useQueryClient, type UseMutationResult } from "@tanstack/react-query"
import type { ClipboardEvent as ReactClipboardEvent, CSSProperties, DragEvent, ErrorInfo, FormEvent, KeyboardEvent, MouseEvent as ReactMouseEvent, ReactNode, UIEvent } from "react"
import { Component, useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types"
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { GeminiSetupSheet } from "../components/GeminiSetupSheet"
import { AnalyzingHint, annotationHoldLabel, annotationIdleHintKind, annotationShortcutLabel, formatClock, RECORDER_WARNING_SECONDS, shouldShowAnnotationSurfaceNote, useNativeRecorderHud, useWalkthroughRecorder, WalkthroughRecorderHUD } from "../components/WalkthroughRecorder"
import {
  isWalkthroughVideoFile,
  MAX_WALKTHROUGH_BYTES,
  MAX_WALKTHROUGH_DURATION_SECONDS,
  measureVideoDuration,
  retryVideoWalkthrough,
  uploadVideoWalkthrough,
  type VideoWalkthrough
} from "../api/videoWalkthroughs"
import { refreshRecentChats, updateRecentChatCache } from "../lib/chatCache"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import {
  addChatAttachment,
  answerAgentQuestion,
  attachChatRepository,
  branchChat,
  clearChatHistory,
  confirmChatProposal,
  confirmPendingAction,
  createChat,
  createChatBookmark,
  createChatTopicBookmark,
  createWhiteboardSnapshot,
  createScratchpadItem,
  deleteScratchpadItem,
  deleteQueuedChatMessage,
  deleteChatAttachment,
  enqueueChatMessage,
  reorderScratchpadItems,
  updateScratchpadItem,
  fetchChat,
  fetchChatMessages,
  fetchSharedChat,
  fetchChatWhiteboard,
  fetchWhiteboardSnapshot,
  fetchWhiteboardSnapshots,
  markChatRead,
  patchChatWhiteboard,
  rejectChatProposal,
  rejectPendingAction,
  renameChat,
  searchChatEpics,
  searchChatJobs,
  searchChatProposals,
  sendChatMessage,
  shareChat,
  stopChat,
  updateChatProvider,
  cancelCodingCheckout,
  fetchCodingFileTree,
  fetchCodingFileContent,
  fetchCodingDiff,
  updateChatMode,
  updateChatProposal,
  updateChatPinned,
  updateQueuedChatMessage,
  type ChatAttachmentResult,
  type ChatMode,
  type ChatAttachmentRow,
  type ChatAgentQuestion,
  type ChatBranchPayload,
  type ChatBookmark,
  type ChatMessageAttachmentInput,
  type ChatCreatedPayload,
  type ChatMcpHealth,
  type ChatNavRecord,
  type ChatEpicDependencySearchResult,
  type ChatJobDependencySearchResult,
  type ChatMessageItem,
  type ChatPendingAction,
  type ChatPendingActionInline,
  type ChatPayload,
  type ChatProposal,
  type ChatProposalChild,
  type ChatProposalChildDependency,
  type ChatProposalDependency,
  type ChatProposalSearchResult,
  type ChatQueuedMessage,
  type ChatScratchpadItem,
  type ChatRenderItem,
  type ChatStructuredTool,
  type ChatSystemMessage,
  type ChatWhiteboardElement,
  type ChatWhiteboardScene,
  type ChatToolGroupItem,
  type ShareChatPayload,
  type SharedChatPayload,
  type WhiteboardSnapshot,
  type CodingFilesPayload,
  type CodingFileContentPayload,
  type CodingDiffPayload
} from "../api/chats"
import { fetchBootstrap, readInitialBootstrap } from "../api/bootstrap"
import { postJobCommand } from "../api/jobs"
import { CloseIcon } from "../components/CloseIcon"
import { ConfirmationCard } from "../components/ConfirmationCard"
import { EnqueueIcon } from "../components/EnqueueIcon"
import { GearIcon } from "../components/GearIcon"
import { ImageAnnotationModal } from "../components/ImageAnnotationModal"
import { SendIcon } from "../components/SendIcon"
import { StartEpicButton } from "../components/StartEpicButton"
import { StopIcon } from "../components/StopIcon"
import { Markdown, PlainText } from "../lib/Markdown"
import { linkifySlugs } from "../lib/linkifySlugs"
import { createConsumer, type Subscription } from "@rails/actioncable"
import { highlightCode, inferToolResultLanguage } from "../lib/syntaxHighlight"
import {
  filterSlashCommands,
  findSlashCommand,
  slashCommandDescription,
  slashCommandPrompt,
  slashCommandQuery,
  slashCommandSignature,
  type SlashCommand,
  type SlashCommandMatch
} from "../lib/slashCommands"
import { createReportIssue } from "../api/reportIssues"
import { useT } from "../hooks/useT"
import { ChatJobStatusPanel } from "./ChatJobStatusPanel"

const WHITEBOARD_SAVE_DEBOUNCE_MS = 500
const CHAT_ENTER_SUBMIT_MIN_WIDTH = 1024
const CHAT_BOTTOM_THRESHOLD_PX = 48
const CHAT_TOP_LOAD_THRESHOLD_PX = 96
const CHAT_INITIAL_FILL_MARGIN_PX = 80
const CHAT_COMPOSE_MAX_ROWS = 5

type ChatPendingActionStreamItem = {
  type: "pending_action"
  pendingAction: ChatPendingAction
}

type ChatTimestampItem = { type: "timestamp"; time: string; fullDatetime: string }
type ChatDayDividerItem = { type: "day_divider"; date: string; label: string }
type ChatStreamItem = ChatRenderItem | ChatPendingActionStreamItem | ChatTimestampItem | ChatDayDividerItem
const CHAT_WORKSPACE_WIDTH_KEY = "syrus.chat.workspace.width"
const CHAT_WORKSPACE_TAB_KEY = "syrus.chat.workspace.tab"
const CHAT_WORKSPACE_COLLAPSED_KEY = "syrus.chat.workspace.collapsed"
const CHAT_DRAFT_KEY_PREFIX = "syrus.chat.draft."
// Tab only accepts the ghost suggestion after this grace period. A
// suggestion that streams in asynchronously mid-keystroke must not
// hijack a keyboard user's Tab navigation out of the composer.
export const GHOST_SUGGESTION_TAB_GRACE_MS = 250
const CHAT_WORKSPACE_DEFAULT_WIDTH = 520
const CHAT_WORKSPACE_MIN_WIDTH = 360
const CHAT_WORKSPACE_MAX_WIDTH = 760
const CHAT_ATTACHMENT_MAX_BYTES = 5 * 1024 * 1024
const CHAT_ATTACHMENT_TOTAL_MAX_BYTES = 20 * 1024 * 1024
const WHITEBOARD_MAX_ELEMENTS = 1000

type ExcalidrawComponent = typeof import("@excalidraw/excalidraw")["Excalidraw"]
type ExcalidrawApi = Pick<ExcalidrawImperativeAPI, "addFiles" | "updateScene">
type ChatComposeAttachment = ChatMessageAttachmentInput & { size: number }
type ChatMessageImageAttachment = { name: string; mime_type: string; data: string }

export function ChatRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const queryClient = useQueryClient()
  const queryKey = chatQueryKey(id, location.search)
  const prefix = routePrefix(location.pathname)
  const viewportStyle = useChatVisualViewportStyle()
  const { t } = useT("chat")
  const chat = useQuery({
    queryKey,
    queryFn: () => fetchChat(id, location.search),
    enabled: id.length > 0,
    placeholderData: (previousData, previousQuery) => (
      previousQuery?.queryKey[0] === "chats" && previousQuery.queryKey[1] === id ? previousData : undefined
    )
  })

  useEffect(() => {
    if (!id) return

    void markChatRead(id).then(() => {
      refreshRecentChats(queryClient)
    }).catch(() => undefined)
  }, [id, queryClient])

  return (
    <main
      aria-label="Chat"
      className="mx-auto flex h-full max-w-[96rem] flex-col gap-6 overflow-hidden p-3 sm:p-6"
      style={viewportStyle}
    >
      {chat.isPending ? <PanelMessage>{t("loading_chat")}</PanelMessage> : null}
      {chat.isError ? <PanelMessage tone="error">{errorMessage(chat.error, t("error_load_chat"))}</PanelMessage> : null}
      {chat.isSuccess ? <ChatView chatId={id} payload={chat.data} prefix={prefix} queryKey={queryKey} /> : null}
    </main>
  )
}

export function SharedChatRoute() {
  const params = useParams()
  const token = params.token || ""
  const { t } = useT("chat")
  const chat = useQuery({
    queryKey: ["shared-chat", token],
    queryFn: () => fetchSharedChat(token),
    enabled: token.length > 0
  })

  return (
    <main
      aria-label={t("shared_chat_fallback_title")}
      className="mx-auto flex h-full max-w-[64rem] flex-col gap-4 overflow-hidden p-3 sm:p-6"
      style={useChatVisualViewportStyle()}
    >
      {chat.isPending ? <PanelMessage>{t("loading_shared_chat")}</PanelMessage> : null}
      {chat.isError ? <PanelMessage tone="error">{errorMessage(chat.error, t("error_load_shared_chat"))}</PanelMessage> : null}
      {chat.isSuccess ? <SharedChatView payload={chat.data} /> : null}
    </main>
  )
}

function SharedChatView({ payload }: { payload: SharedChatPayload }) {
  const { t } = useT("chat")
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-4">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 pb-3 dark:border-gray-700">
        <h1 className="break-words text-2xl font-semibold text-gray-900 dark:text-gray-100">{payload.chat.title || t("shared_chat_fallback_title")}</h1>
        <span className="rounded border border-blue-200 bg-blue-50 px-3 py-1 text-sm font-medium text-blue-800 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-200">{t("view_only")}</span>
      </header>
      <section className="min-h-0 flex-1 overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-950">
        <ReadOnlyMessageStream payload={payload} />
      </section>
    </div>
  )
}

function ReadOnlyMessageStream({ payload }: { payload: SharedChatPayload }) {
  const items = renderChatMessages(payload.messages)
  const placeholderPayload = sharedChatRenderPayload(payload)
  const { t } = useT("chat")

  if (items.length === 0) {
    return (
      <div className="flex h-full min-h-0 items-center justify-center overflow-y-auto p-4 text-sm text-gray-500 dark:text-gray-400" data-testid="chat-message-stream">
        {t("no_shared_chat_messages")}
      </div>
    )
  }

  return (
    <div className="h-full min-h-0 space-y-4 overflow-y-auto p-3 sm:p-4" data-testid="chat-message-stream">
      {items.map((item) => item.type === "tool_group" ? (
        <ToolGroup item={item} key={renderItemKey(item)} />
      ) : (
        <ChatMessage item={item} key={renderItemKey(item)} payload={placeholderPayload} pendingActionIds={new Set()} prefix="" queryKey={chatQueryKey(payload.chat.id, "")} readOnly onNotice={() => undefined} />
      ))}
    </div>
  )
}

function sharedChatRenderPayload(payload: SharedChatPayload): ChatPayload {
  return {
    chat: {
      id: payload.chat.id,
      title: payload.chat.title,
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_provider: "claude",
      chat_path: `/chats/shared/${payload.chat.id}`,
      repository: null,
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0
    },
    chat_available: false,
    turn_in_flight: false,
    agent_busy: false,
    switching_provider: false,
    has_more_older: false,
    messages: payload.messages,
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    scratchpad_items: [],
    video_walkthroughs: [],
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
    documents_in_scope: [],
    attachment_results: [],
    whiteboard: { version: 1, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "",
      app_message_path: "",
      app_rename_path: "",
      app_clear_path: "",
      app_branch_path: "",
      app_share_path: "",
      app_enqueue_message_path: "",
      app_stop_path: "",
      app_daemon_connection_path: "",
      app_bookmarks_path: "",
      app_attachments_path: "",
      app_video_walkthroughs_path: "",
      app_whiteboard_path: "",
      app_switch_provider_path: "",
      app_scratchpad_reorder_path: ""
    },
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false
  }
}

function useChatVisualViewportStyle() {
  const [height, setHeight] = useState(visualViewportHeight)

  useEffect(() => {
    if (typeof window === "undefined" || !window.visualViewport) return

    const viewport = window.visualViewport
    const updateHeight = () => setHeight(visualViewportHeight())
    updateHeight()
    viewport.addEventListener("resize", updateHeight)
    viewport.addEventListener("scroll", updateHeight)
    return () => {
      viewport.removeEventListener("resize", updateHeight)
      viewport.removeEventListener("scroll", updateHeight)
    }
  }, [])

  if (height == null) return undefined

  return { "--chat-visual-viewport-height": `${height}px` } as CSSProperties
}

function visualViewportHeight() {
  if (typeof window === "undefined" || !window.visualViewport) return null

  return Math.round(window.visualViewport.height)
}

type ChatQueryKey = readonly ["chats", string, string]

export function chatQueryKey(id: string | number, search: string): ChatQueryKey {
  return ["chats", String(id), search] as const
}

type WalkthroughDraft = {
  // Monotonic client-side identity: state updates from an upload are keyed to
  // the draft that started them, so a late resolution can't corrupt a draft
  // the user has since replaced.
  key: number
  file: File
  filename: string
  durationSeconds: number | null
  status: "ready" | "uploading" | "analyzing" | "failed"
  percent: number
  id?: number
  error?: string
}

type PendingSlashCommandConfirmation = {
  commandName: SlashCommand["name"]
  text: string
}

type BookmarkTarget = {
  messageId: number
  requestId: number
}

type ChatSystemCommandHandlers = {
  openBookmarks: () => void
  openAttachments: () => void
  openSettings: () => void
}

type ChatSystemAction =
  | { kind: "rename"; title: string }
  | { kind: "clear" }
  | { kind: "new" }
  | { kind: "branch" }
  | { kind: "share" }
  | { kind: "attach"; slug: string }
  | { kind: "pin"; pinned: boolean }

type ChatSystemCommandAction =
  | { kind: "bookmark"; label: string }
  | { kind: "discard"; path: string }
  | { kind: "job"; action: "cancel" | "retry"; jobId: string }
  | { kind: "clear-canvas" }

function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

function ChatView({ chatId, payload, prefix, queryKey }: { chatId: string; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey }) {
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [whiteboardFullscreen, setWhiteboardFullscreen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { t } = useT("chat")

  const title = chatDisplayTitle(payload.chat)

  useEffect(() => {
    setWhiteboardFullscreen(false)
  }, [payload.chat.id])

  useEffect(() => {
    if (!whiteboardFullscreen) return

    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") setWhiteboardFullscreen(false)
    }

    window.addEventListener("keydown", handleKeyDown)
    return () => window.removeEventListener("keydown", handleKeyDown)
  }, [whiteboardFullscreen])

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-6">
      {whiteboardFullscreen || !isDesktop ? null : (
        <header className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className={`break-words text-3xl font-semibold ${payload.chat.title_pending ? "animate-pulse text-gray-400 dark:text-gray-500" : "text-gray-900 dark:text-gray-100"}`}>{title}</h1>
            {payload.local_mode_enabled && payload.chat.mode === "local" && payload.chat.local_daemon_state === "connected" ? (
              <div className="mt-1 flex items-center gap-1.5 text-sm text-emerald-700 dark:text-emerald-400">
                <span aria-hidden="true" className="h-2 w-2 rounded-full bg-emerald-500" />
                <span>{t("local_daemon_connected", { repo: payload.chat.local_daemon_repo ?? "", branch: payload.chat.local_daemon_branch ?? "" })}</span>
              </div>
            ) : null}
          </div>
          <button
            aria-label={t("chat_settings")}
            className="rounded p-1.5 text-gray-400 transition hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
            onClick={() => setSettingsOpen(true)}
            title={t("chat_settings")}
            type="button"
          >
            <GearIcon className="h-5 w-5" />
          </button>
        </header>
      )}

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      {!payload.chat_available ? (
        <section className="rounded border border-amber-200 bg-white p-6 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
          <div className="font-semibold">{t("credentials_required_title")}</div>
          <p className="mt-1">Chat uses Claude. Add a Claude OAuth token in <Link className="underline hover:no-underline" to={withRoutePrefix("/credentials", prefix)}>Credentials</Link> to enable chat.</p>
        </section>
      ) : (
        <ChatWorkspace
          chatId={chatId}
          payload={payload}
          prefix={prefix}
          queryKey={queryKey}
          onNotice={setNotice}
          whiteboardFullscreen={whiteboardFullscreen}
          onWhiteboardFullscreenChange={setWhiteboardFullscreen}
          settingsOpen={settingsOpen}
          onSettingsOpenChange={setSettingsOpen}
        />
      )}
    </div>
  )
}

function MessageStream({ bookmarkTarget, payload, prefix, queryKey, onNotice }: { bookmarkTarget: BookmarkTarget | null; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const location = useLocation()
  const { t } = useT("chat")
  // Passive observer of the shared bootstrap cache (AppChrome owns the
  // fetch; flags also arrive via the inline syrus-bootstrap-data script) —
  // same pattern as useSetupStatus. An enabled query here would clobber the
  // seeded cache and double-fetch on every thread mount.
  const initialBootstrap = readInitialBootstrap()
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: false,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const chatPolish = Boolean(bootstrap.data?.feature_flags?.chat_polish)
  const streamRef = useRef<HTMLDivElement | null>(null)
  const atBottomRef = useRef(true)
  const streamChatIdRef = useRef(payload.chat.id)
  const maxPayloadMessageIdRef = useRef(maxMessageId(payload.messages))
  // Frozen at mount / chat switch — the boundary between "history" and "new".
  const entranceBaselineMessageIdRef = useRef(maxMessageId(payload.messages))
  const bookmarkLoadBeforeRef = useRef<number | null>(null)
  const preserveScrollAfterOlderLoadRef = useRef<{ scrollHeight: number; scrollTop: number } | null>(null)
  const [newMessageCount, setNewMessageCount] = useState(0)
  const [olderMessages, setOlderMessages] = useState<ChatMessageItem[]>([])
  const [showSystemMessages, setShowSystemMessages] = useState(false)
  const [hasMoreOlder, setHasMoreOlder] = useState(payload.has_more_older)
  const [activeBookmarkTarget, setActiveBookmarkTarget] = useState<BookmarkTarget | null>(null)
  const displayedMessages = mergeChatMessages(olderMessages, payload.messages)
  const displayedItems = renderChatMessages(displayedMessages)
  const agentQuestions = payload.agent_questions || []
  const hiddenSystemMessageCount = displayedItems.filter(isLowPrioritySystemMessage).length
  const visibleItems = showSystemMessages ? displayedItems : displayedItems.filter((item) => !isLowPrioritySystemMessage(item))
  const pendingActionIds = new Set(payload.pending_actions.map((action) => action.id))
  const streamItems = injectTemporalMarkers(buildMessageStreamItems(visibleItems, payload.pending_actions))
  const agentActive = isAgentActive(payload)
  const oldestId = oldestMessageId(displayedMessages)
  const payloadMessageIdsSignature = payload.messages.map((message) => message.id).join("|")
  const visibleItemsSignature = chatStreamItemsSignature(streamItems)
  const loadOlder = useMutation({
    mutationFn: (before: number) => fetchChatMessages(payload.paths.app_messages_path, before),
    onSuccess: (page) => {
      setOlderMessages((current) => mergeChatMessages(page.messages, current))
      setHasMoreOlder(page.has_more_older)
    }
  })

  const scrollToBottom = useCallback(() => {
    scrollMessageStreamToBottom(streamRef.current, { smooth: chatPolish })
    atBottomRef.current = true
    setNewMessageCount(0)
  }, [chatPolish])

  const requestOlderMessages = useCallback((options: { preserveScroll: boolean }) => {
    if (!hasMoreOlder || oldestId == null || loadOlder.isPending) return false

    const stream = streamRef.current
    preserveScrollAfterOlderLoadRef.current = options.preserveScroll && stream ? {
      scrollHeight: stream.scrollHeight,
      scrollTop: stream.scrollTop
    } : null
    loadOlder.mutate(oldestId)
    return true
  }, [hasMoreOlder, loadOlder, oldestId])

  const handleScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    const atBottom = isMessageStreamAtBottom(event.currentTarget)
    atBottomRef.current = atBottom
    if (atBottom) setNewMessageCount(0)
    if (isMessageStreamNearTop(event.currentTarget)) {
      requestOlderMessages({ preserveScroll: true })
    }
  }, [requestOlderMessages])

  useEffect(() => {
    setOlderMessages([])
    setShowSystemMessages(false)
    setHasMoreOlder(payload.has_more_older)
    setNewMessageCount(0)
    atBottomRef.current = true
    streamChatIdRef.current = payload.chat.id
    maxPayloadMessageIdRef.current = maxMessageId(payload.messages)
    entranceBaselineMessageIdRef.current = maxMessageId(payload.messages)
  }, [payload.chat.id])

  useEffect(() => {
    if (olderMessages.length === 0) setHasMoreOlder(payload.has_more_older)
  }, [olderMessages.length, payload.has_more_older])

  useEffect(() => {
    if (streamChatIdRef.current !== payload.chat.id) {
      streamChatIdRef.current = payload.chat.id
      maxPayloadMessageIdRef.current = maxMessageId(payload.messages)
      return
    }

    const previousMaxMessageId = maxPayloadMessageIdRef.current
    const nextMaxMessageId = maxMessageId(payload.messages)
    if (previousMaxMessageId != null && nextMaxMessageId != null && nextMaxMessageId > previousMaxMessageId && !atBottomRef.current) {
      const incomingCount = countIncomingVisibleMessages(payload.messages, previousMaxMessageId, showSystemMessages)
      if (incomingCount > 0) setNewMessageCount((count) => count + incomingCount)
    }
    maxPayloadMessageIdRef.current = nextMaxMessageId
  }, [payload.chat.id, payloadMessageIdsSignature, showSystemMessages])

  useEffect(() => {
    if (atBottomRef.current) scrollMessageStreamToBottom(streamRef.current)
  }, [agentActive, visibleItemsSignature])

  useLayoutEffect(() => {
    const snapshot = preserveScrollAfterOlderLoadRef.current
    const stream = streamRef.current
    if (!snapshot || !stream) return

    stream.scrollTop = stream.scrollHeight - snapshot.scrollHeight + snapshot.scrollTop
    preserveScrollAfterOlderLoadRef.current = null
  }, [visibleItemsSignature])

  useEffect(() => {
    const stream = streamRef.current
    if (!stream || !messageStreamNeedsOlderMessages(stream)) return

    requestOlderMessages({ preserveScroll: false })
  }, [requestOlderMessages, visibleItemsSignature])

  useEffect(() => {
    if (!bookmarkTarget) return

    bookmarkLoadBeforeRef.current = null
    setActiveBookmarkTarget(bookmarkTarget)
  }, [bookmarkTarget?.messageId, bookmarkTarget?.requestId])

  useEffect(() => {
    const messageId = messageIdFromHash(location.hash)
    if (!messageId) return

    bookmarkLoadBeforeRef.current = null
    setActiveBookmarkTarget({ messageId, requestId: messageId })
  }, [location.hash, payload.chat.id])

  useEffect(() => {
    if (!activeBookmarkTarget) return

    const stream = streamRef.current
    if (!stream) return

    const target = findChatMessageAnchor(stream, activeBookmarkTarget.messageId)
    if (target) {
      scrollChatMessageIntoView(target)
      setActiveBookmarkTarget(null)
      return
    }

    if (!hasMoreOlder || oldestId == null) {
      setActiveBookmarkTarget(null)
      return
    }

    if (loadOlder.isPending || bookmarkLoadBeforeRef.current === oldestId) return

    bookmarkLoadBeforeRef.current = oldestId
    loadOlder.mutate(oldestId)
  }, [activeBookmarkTarget, hasMoreOlder, loadOlder.isPending, oldestId, visibleItemsSignature])

  if (displayedItems.length === 0 && payload.pending_actions.length === 0) {
    return (
      <div className="flex h-full min-h-0 flex-col gap-4 overflow-y-auto p-4 text-sm text-gray-500 dark:text-gray-400" data-testid="chat-message-stream">
        <div className="flex flex-1 flex-col items-center justify-center gap-3">
          <div>{payload.chat.repository ? t("empty_with_repo") : t("empty_without_repo")}</div>
          {payload.switching_provider ? <SwitchingProviderIndicator provider={payload.chat.chat_provider ?? ""} /> : agentActive ? <AgentActivityIndicator running={payload.agent_busy} /> : null}
        </div>
        {agentQuestions.length > 0 ? <AgentQuestions questions={agentQuestions} queryKey={queryKey} onNotice={onNotice} /> : null}
      </div>
    )
  }

  return (
    <div className="relative h-full min-h-0">
      <div className="h-full min-h-0 space-y-4 overflow-y-auto p-3 pt-12 sm:p-4 sm:pt-12" data-testid="chat-message-stream" onScroll={handleScroll} ref={streamRef}>
        {loadOlder.isPending ? <div className="text-center text-xs text-gray-400 dark:text-gray-500">{t("loading_older_messages")}</div> : null}
        {loadOlder.isError ? <div className="text-center text-xs text-red-700 dark:text-red-300">{errorMessage(loadOlder.error, t("error_load_older_messages"))}</div> : null}
        {hiddenSystemMessageCount > 0 ? (
          <SystemMessagesToggle count={hiddenSystemMessageCount} expanded={showSystemMessages} onToggle={() => setShowSystemMessages((value) => !value)} />
        ) : null}
        {streamItems.map((item) => item.type === "timestamp" ? (
          <MessageTimestamp fullDatetime={item.fullDatetime} key={renderItemKey(item)} time={item.time} />
        ) : item.type === "day_divider" ? (
          <DayDivider date={item.date} key={renderItemKey(item)} label={item.label} />
        ) : item.type === "pending_action" ? (
          <PendingActionCard pendingAction={pendingActionCardData(item.pendingAction)} key={renderItemKey(item)} queryKey={queryKey} onNotice={onNotice} />
        ) : item.type === "tool_group" ? (
          <ToolGroup item={item} key={renderItemKey(item)} />
        ) : (
          <ChatMessage animateIn={shouldAnimateMessageEntrance(chatPolish, item.id, entranceBaselineMessageIdRef.current)} item={item} key={renderItemKey(item)} payload={payload} pendingActionIds={pendingActionIds} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
        ))}
        {agentQuestions.length > 0 ? <AgentQuestions questions={agentQuestions} queryKey={queryKey} onNotice={onNotice} /> : null}
        {payload.switching_provider ? <SwitchingProviderIndicator provider={payload.chat.chat_provider ?? ""} /> : agentActive ? <AgentActivityIndicator running={payload.agent_busy} /> : null}
      </div>
      {newMessageCount > 0 ? (
        <button
          className="absolute bottom-4 left-1/2 -translate-x-1/2 rounded-full bg-gray-900 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-gray-800 dark:bg-gray-100 dark:text-gray-950 dark:hover:bg-gray-200"
          onClick={scrollToBottom}
          type="button"
        >
          {t("new_messages_button", { count: newMessageCount })}
        </button>
      ) : null}
    </div>
  )
}

function MessageTimestamp({ time, fullDatetime }: { time: string; fullDatetime: string }) {
  return (
    <div className="flex justify-center py-1" title={fullDatetime}>
      <span className="text-xs text-gray-400 dark:text-gray-500">{time}</span>
    </div>
  )
}

function DayDivider({ date: _date, label }: { date: string; label: string }) {
  const id = useId()

  return (
    <div className="flex items-center gap-3 py-3">
      <WaveLine patternId={`wave-${id}-left`} />
      <span className="whitespace-nowrap text-xs text-gray-300 dark:text-gray-700">{label}</span>
      <WaveLine patternId={`wave-${id}-right`} />
    </div>
  )
}

function WaveLine({ patternId }: { patternId: string }) {
  return (
    <svg className="h-[8px] flex-1 text-gray-300 dark:text-gray-700" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <pattern height="8" id={patternId} patternUnits="userSpaceOnUse" width="20" x="0" y="0">
          <path d="M0,4 C5,0 10,8 15,4 C20,0 25,8 30,4" fill="none" stroke="currentColor" strokeWidth="1.5" />
        </pattern>
      </defs>
      <rect fill={`url(#${patternId})`} height="100%" width="100%" />
    </svg>
  )
}

function SystemMessagesToggle({ count, expanded, onToggle }: { count: number; expanded: boolean; onToggle: () => void }) {
  const { t } = useT("chat")
  return (
    <div className="flex justify-center">
      <button className="rounded-full border border-gray-200 bg-white px-3 py-1 text-xs font-medium text-gray-600 shadow-sm hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800" onClick={onToggle} type="button">
        {expanded ? t("hide_system_messages") : t("show_system_messages", { count })}
      </button>
    </div>
  )
}

const WORKING_PHRASES = [
  { latin: "Cogitans", english: "thinking it through" },
  { latin: "Machinans", english: "contriving, plotting" },
  { latin: "Moliens", english: "striving, setting in motion" },
  { latin: "Meditans", english: "planning, turning over in the mind" },
  { latin: "Excogitans", english: "thinking out, devising" },
  { latin: "Elaborans", english: "working it out carefully" },
  { latin: "Perscrutans", english: "examining thoroughly" },
  { latin: "Computans", english: "calculating" },
  { latin: "Conficiens", english: "bringing to completion" },
  { latin: "Agitans", english: "setting things in motion" },
  { latin: "Evolvens", english: "unrolling, unfolding" },
  { latin: "Ponderans", english: "weighing carefully" },
  { latin: "Consilians", english: "taking counsel, deliberating" },
  { latin: "Exsequens", english: "carrying out, executing" },
  { latin: "Investigans", english: "tracking down, hunting through" },
  { latin: "Versans", english: "turning over in the mind" },
  { latin: "Struens", english: "building, constructing" },
  { latin: "Nectens", english: "weaving together, binding" },
  { latin: "Vigilans", english: "keeping watch" },
  { latin: "Expediens", english: "making ready, dispatching" }
] as const

export function getStartingPhrase() {
  const now = new Date()
  if (now.getMonth() === 2 && now.getDate() === 15) {
    return { latin: "Cave, Idus Martias.", english: "Beware the Ides of March." }
  }
  return { latin: "Accingitur", english: "girding itself" }
}

function AgentActivityIndicator({ running }: { running: boolean }) {
  const workingPhrase = useMemo(
    () => WORKING_PHRASES[Math.floor(Math.random() * WORKING_PHRASES.length)],
    []
  )
  const phrase = running ? workingPhrase : getStartingPhrase()

  return (
    <div aria-label={phrase.english} aria-live="polite" className="flex justify-start" role="status">
      <div className="inline-flex items-center gap-2 rounded-full border border-blue-100 bg-blue-50 px-3 py-1.5 text-xs font-medium text-blue-700 shadow-sm dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200">
        <span aria-hidden="true" className="inline-flex items-center gap-1">
          {[0, 1, 2].map((index) => (
            <span
              className="h-1.5 w-1.5 animate-bounce rounded-full bg-blue-500 dark:bg-blue-300"
              key={index}
              style={{ animationDelay: `${index * 140}ms` }}
            />
          ))}
        </span>
        <span title={phrase.english}>{phrase.latin}</span>
      </div>
    </div>
  )
}

function SwitchingProviderIndicator({ provider }: { provider: string }) {
  const { t } = useT("chat")
  const label = t("switching_to_provider", { provider: providerLabel(provider) })
  return (
    <div aria-label={label} aria-live="polite" className="flex justify-start" role="status">
      <div className="inline-flex items-center gap-2 rounded-full border border-amber-100 bg-amber-50 px-3 py-1.5 text-xs font-medium text-amber-700 shadow-sm dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
        <span aria-hidden="true" className="inline-flex items-center gap-1">
          {[0, 1, 2].map((index) => (
            <span
              className="h-1.5 w-1.5 animate-bounce rounded-full bg-amber-500 dark:bg-amber-300"
              key={index}
              style={{ animationDelay: `${index * 140}ms` }}
            />
          ))}
        </span>
        <span>{label}</span>
      </div>
    </div>
  )
}

function ChatMessage({ animateIn = false, item, payload, pendingActionIds, prefix, queryKey, readOnly = false, onNotice }: { animateIn?: boolean; item: Extract<ChatRenderItem, { type: "message" }>; payload: ChatPayload; pendingActionIds: Set<number>; prefix: string; queryKey: ChatQueryKey; readOnly?: boolean; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  // chat_polish entrance; motion-safe: keeps reduced-motion users at rest.
  const entranceClass = animateIn ? " motion-safe:animate-chat-message-in" : ""
  if (item.role === "user") {
    return (
      <article className={`group/message relative flex justify-end pt-6${entranceClass}`} id={`chat_message_${item.id}`}>
        <span className="absolute -top-4" id={`message-${item.id}`} />
        {readOnly ? null : <BookmarkControl item={item} payload={payload} queryKey={queryKey} onNotice={onNotice} />}
        <div className="max-w-[min(42rem,85%)] space-y-2">
          {item.video_walkthrough_id ? (
            <div className="flex items-center justify-end gap-2 text-sm text-gray-500 dark:text-gray-400" data-testid="walkthrough-message-chip">
              <span aria-hidden="true">🎥</span>
              <span>{t("walkthrough_shared_chip")}</span>
            </div>
          ) : null}
          {item.text.trim().length > 0 ? (
            <PlainText className="whitespace-pre-wrap break-words rounded bg-blue-600 px-4 py-2 text-sm leading-normal text-white dark:bg-blue-500" text={item.text} />
          ) : null}
          <MessageImageAttachments attachments={item.attachments} align="end" />
          <MessageFileAttachments attachments={item.attachments} align="end" />
        </div>
      </article>
    )
  }

  if (item.role === "assistant") {
    if (!item.text) return null
    return (
      <article className={`group/message relative pt-6${entranceClass}`} id={`chat_message_${item.id}`}>
        <span className="absolute -top-4" id={`message-${item.id}`} />
        {readOnly ? null : <BookmarkControl item={item} payload={payload} queryKey={queryKey} onNotice={onNotice} />}
        <div className="space-y-3">
          <div className="max-w-3xl rounded border border-gray-200 bg-white px-4 py-3 dark:border-gray-700 dark:bg-gray-900">
            <Markdown className="chat-prose text-gray-800 dark:text-gray-100" text={item.text} />
          </div>
          <MessageImageAttachments attachments={item.attachments} />
          {!readOnly && item.proposal ? <ProposalCard proposal={item.proposal} prefix={prefix} queryKey={queryKey} onNotice={onNotice} /> : null}
          {!readOnly && !item.proposal && item.pending_action && !pendingActionIds.has(item.pending_action.id) ? <PendingActionCard pendingAction={item.pending_action} queryKey={queryKey} onNotice={onNotice} /> : null}
        </div>
      </article>
    )
  }

  if (item.role === "system") {
    return <SystemMessage item={item.system || { tone: "neutral", label: "System", body: item.text }} prefix={prefix} />
  }

  return <StructuredTool tool={item.tool} fallback={item.text} />
}

function MessageImageAttachments({ attachments, align = "start" }: { attachments?: ChatMessageItem["attachments"]; align?: "start" | "end" }) {
  const images = (attachments || []).filter((attachment): attachment is ChatMessageImageAttachment => attachment.mime_type.startsWith("image/"))
  const [lightboxImage, setLightboxImage] = useState<ChatMessageImageAttachment | null>(null)

  if (images.length === 0) return null

  return (
    <>
      <div className={`flex flex-wrap gap-2 ${align === "end" ? "justify-end" : "justify-start"}`}>
        {images.map((attachment, index) => {
          const src = attachmentDataUrl(attachment)
          return (
            <button
              aria-label={`Open ${attachment.name || "image attachment"}`}
              className="min-h-12 min-w-12 max-h-[10rem] max-w-[16rem] overflow-hidden rounded border border-gray-200 bg-white p-0 shadow-sm transition hover:border-blue-300 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900"
              key={`${attachment.name}-${index}`}
              onClick={() => setLightboxImage(attachment)}
              type="button"
            >
              <img alt={attachment.name || "Image attachment"} className="max-h-[10rem] min-h-12 min-w-12 max-w-[16rem] object-contain" src={src} />
            </button>
          )
        })}
      </div>
      {lightboxImage ? <ImageLightbox attachment={lightboxImage} onClose={() => setLightboxImage(null)} /> : null}
    </>
  )
}

// Non-image attachments (e.g. PDFs) — images render as thumbnails, but a PDF (or
// any other file) would otherwise show nothing, leaving a blank bubble when the
// message has no text. Render each as a labeled chip so it's always visible.
function MessageFileAttachments({ attachments, align = "start" }: { attachments?: ChatMessageItem["attachments"]; align?: "start" | "end" }) {
  const files = (attachments || []).filter((attachment) => !attachment.mime_type.startsWith("image/"))
  if (files.length === 0) return null

  return (
    <div className={`flex flex-wrap gap-2 ${align === "end" ? "justify-end" : "justify-start"}`}>
      {files.map((attachment, index) => (
        <span
          className="inline-flex max-w-[16rem] items-center gap-1.5 truncate rounded border border-gray-200 bg-white px-2 py-1 text-xs text-gray-600 shadow-sm dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
          key={`${attachment.name}-${index}`}
          title={attachment.name}
        >
          <span aria-hidden="true">📎</span>
          <span className="truncate">{attachment.name || "attachment"}</span>
        </span>
      ))}
    </div>
  )
}

function ImageLightbox({ attachment, onClose }: { attachment: ChatMessageImageAttachment; onClose: () => void }) {
  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") onClose()
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" onClick={onClose} role="presentation">
      <section aria-label={attachment.name || "Image attachment"} aria-modal="true" className="relative max-h-full max-w-full" onClick={(event) => event.stopPropagation()} role="dialog">
        <button
          aria-label="Close image preview"
          className="absolute right-2 top-2 rounded bg-white/90 p-1.5 text-gray-600 shadow hover:bg-white hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-900/90 dark:text-gray-200 dark:hover:bg-gray-900"
          onClick={onClose}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
        <img alt={attachment.name || "Image attachment"} className="max-h-[calc(100dvh-2rem)] max-w-[calc(100vw-2rem)] rounded bg-white object-contain shadow-lg dark:bg-gray-900" src={attachmentDataUrl(attachment)} />
      </section>
    </div>
  )
}

function attachmentDataUrl(attachment: ChatMessageImageAttachment) {
  return `data:${attachment.mime_type};base64,${attachment.data}`
}

function imageAttachments(messages: ChatRenderItem[]) {
  return messages.flatMap((message) => {
    if (message.type !== "message") return []

    return (message.attachments || [])
      .filter((attachment): attachment is ChatMessageImageAttachment => attachment.mime_type.startsWith("image/"))
      .map((attachment, index) => ({ attachment, key: `${message.id}-${attachment.name}-${index}` }))
  })
}

function isLowPrioritySystemMessage(item: ChatRenderItem) {
  return item.type === "message" &&
    item.role === "system" &&
    !isProposalOutcomeSystemMessage(item) &&
    ["neutral", "success"].includes(item.system?.tone || "neutral")
}

function isProposalOutcomeSystemMessage(item: Extract<ChatRenderItem, { type: "message" }>) {
  return contentRecord(item.content)?.source === "proposal_notification"
}

function isAgentActive(payload: ChatPayload) {
  return payload.agent_busy || payload.turn_in_flight || payload.switching_provider
}

function isMessageStreamAtBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= CHAT_BOTTOM_THRESHOLD_PX
}

function isMessageStreamNearTop(element: HTMLElement) {
  return element.scrollTop <= CHAT_TOP_LOAD_THRESHOLD_PX
}

function messageStreamNeedsOlderMessages(element: HTMLElement) {
  return element.clientHeight > 0 && element.scrollHeight <= element.clientHeight + CHAT_INITIAL_FILL_MARGIN_PX
}

function scrollMessageStreamToBottom(element: HTMLElement | null, options: { smooth?: boolean } = {}) {
  if (!element) return
  // Smooth only for explicit user gestures under chat_polish; auto-follow
  // during streaming stays instant so the viewport never chases animations.
  const reduceMotion = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches
  if (options.smooth && !reduceMotion && typeof element.scrollTo === "function") {
    element.scrollTo({ top: element.scrollHeight, behavior: "smooth" })
    return
  }
  element.scrollTop = element.scrollHeight
}

// chat_polish: only messages that ARRIVE while the thread is open animate in —
// the initially loaded history must render at rest (and older pages prepend
// with LOWER ids, so they can never satisfy the > check).
export function shouldAnimateMessageEntrance(polish: boolean, messageId: number | null | undefined, initialMaxId: number | null): boolean {
  if (!polish || messageId == null || initialMaxId == null) return false
  return messageId > initialMaxId
}

function findChatMessageAnchor(stream: HTMLElement, messageId: number) {
  return stream.querySelector<HTMLElement>(`#message-${messageId}`)
}

function scrollChatMessageIntoView(element: HTMLElement) {
  if (typeof element.scrollIntoView === "function") {
    element.scrollIntoView({ block: "start", behavior: "smooth" })
  }
}

function messageIdFromHash(hash: string) {
  const match = hash.match(/^#message-(\d+)$/)
  if (!match) return null

  const messageId = Number.parseInt(match[1], 10)
  return Number.isFinite(messageId) && messageId > 0 ? messageId : null
}

function countIncomingVisibleMessages(messages: ChatMessageItem[], previousMaxMessageId: number, showSystemMessages: boolean) {
  return messages.filter((message) => {
    if (message.id <= previousMaxMessageId) return false
    const item = renderMessage(message)
    if (item === null) return false

    return showSystemMessages || !isLowPrioritySystemMessage(item)
  }).length
}

function formatMessageTimestamp(createdAt: string): string {
  const date = new Date(createdAt)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffMinutes = Math.floor(diffMs / 60_000)
  const diffHours = Math.floor(diffMinutes / 60)

  if (diffMinutes < 1) return "just now"
  if (diffMinutes < 60) return `${diffMinutes}m ago`
  if (diffHours < 24) return `${diffHours}h ago`

  const m = date.getMonth() + 1
  const d = date.getDate()
  const hh = date.getHours()
  const mm = String(date.getMinutes()).padStart(2, "0")
  const period = hh >= 12 ? "pm" : "am"
  const h = hh % 12 || 12

  if (date.getFullYear() === now.getFullYear()) {
    return `${m}/${d} ${h}:${mm}${period}`
  }
  return `${m}/${d}/${date.getFullYear()} ${h}:${mm}${period}`
}

function BookmarkControl({ item, payload, queryKey, onNotice }: { item: Extract<ChatRenderItem, { type: "message" }>; payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [open, setOpen] = useState(false)
  const [label, setLabel] = useState("")
  const [copied, setCopied] = useState(false)
  const copyTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => () => { if (copyTimeoutRef.current) clearTimeout(copyTimeoutRef.current) }, [])
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const bookmark = useMutation({
    mutationFn: () => createChatBookmark(appendSearch(payload.paths.app_bookmarks_path, search), item.id, label),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(null)
      setLabel("")
      setOpen(false)
    }
  })

  if (!item.text) return null

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    bookmark.mutate()
  }

  function handleCopy() {
    void navigator.clipboard.writeText(item.text).then(() => {
      setCopied(true)
      copyTimeoutRef.current = setTimeout(() => setCopied(false), 1500)
    })
  }

  return (
    <div className={`absolute right-0 top-0 z-10 flex gap-1 ${open ? "flex" : "hidden group-hover/message:flex"}`} ref={menuRef}>
      {item.created_at ? (
        <time
          className="flex items-center rounded border border-gray-200 bg-white px-2 py-1 text-xs text-gray-400 shadow-sm dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500"
          dateTime={item.created_at}
          title={new Date(item.created_at).toLocaleString()}
        >
          {formatMessageTimestamp(item.created_at)}
        </time>
      ) : null}
      <button className="rounded border border-gray-200 bg-white px-2 py-1 text-xs font-medium text-gray-600 shadow-sm hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800" onClick={handleCopy} type="button">
        {copied ? "Copied!" : "Copy"}
      </button>
      {item.bookmarkable ? (
        <>
          <button className="rounded border border-gray-200 bg-white px-2 py-1 text-xs font-medium text-gray-600 shadow-sm hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800" onClick={() => setOpen((value) => !value)} type="button">
            Bookmark
          </button>
          {open ? (
            <form className="absolute right-0 top-8 w-64 space-y-3 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900" onSubmit={submit}>
              <label className="block text-xs font-medium text-gray-600 dark:text-gray-300">
                Label
                <input className="mt-1 w-full rounded border border-gray-300 px-2 py-1.5 text-sm dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100" maxLength={120} onChange={(event) => setLabel(event.target.value)} required type="text" value={label} />
              </label>
              {bookmark.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(bookmark.error, "Bookmark failed.")}</div> : null}
              <div className="flex justify-end gap-2">
                <button className={secondaryButton()} disabled={bookmark.isPending} onClick={() => setOpen(false)} type="button">Cancel</button>
                <button className={primaryButton()} disabled={bookmark.isPending} type="submit">Save</button>
              </div>
            </form>
          ) : null}
        </>
      ) : null}
    </div>
  )
}

function ToolGroup({ item }: { item: ChatToolGroupItem }) {
  const details = item.calls.map((call) => [call.detail, call.result_summary].filter(Boolean).join(" · ")).filter(Boolean).join(", ")
  return (
    <details className="group/tool">
      <summary className="flex min-w-0 cursor-pointer items-baseline gap-2 py-0.5 text-sm text-gray-700 hover:text-gray-900 dark:text-gray-300 dark:hover:text-gray-100">
        <span className="text-gray-400 group-open/tool:rotate-90 dark:text-gray-500">▸</span>
        <span className="font-mono font-medium text-gray-900 dark:text-gray-100">{item.tool}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-gray-600 dark:text-gray-400">{details}</span>
        {item.calls.length > 1 ? <span className="ml-auto rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-500 dark:bg-gray-800 dark:text-gray-400">{item.calls.length}</span> : null}
      </summary>
      <div className="ml-5 mt-1 space-y-2 border-l border-gray-200 pl-3 text-xs dark:border-gray-700">
        {item.calls.map((call) => (
          <div key={call.message_id}>
            <div className="break-words font-mono text-gray-700 dark:text-gray-300">{item.tool}{call.detail ? `(${call.detail})` : ""}</div>
            {call.result_summary ? <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">{call.result_summary}</div> : null}
            {call.result_body ? <HighlightedToolResult code={call.result_body} detail={call.detail} error={call.result_error} tool={item.tool} /> : null}
          </div>
        ))}
      </div>
    </details>
  )
}

function HighlightedToolResult({ code, detail, error, tool }: { code: string; detail: string; error: boolean; tool: string }) {
  const language = inferToolResultLanguage(detail, tool)
  const className = `mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 dark:text-gray-400 ${error ? "text-red-600 dark:text-red-300" : ""}`

  if (!language || error) return <pre className={className}>{code}</pre>

  return <pre className={className}>{highlightCode(code, language)}</pre>
}

function StructuredTool({ tool, fallback }: { tool?: ChatStructuredTool; fallback: string }) {
  const name = tool?.name || "tool"
  return (
    <details className="text-xs open:rounded open:border open:border-gray-200 open:bg-gray-50 dark:open:border-gray-700 dark:open:bg-gray-900">
      <summary className="flex cursor-pointer items-baseline gap-2 py-0.5 text-sm text-gray-700 hover:text-gray-900 group-open/tool:px-3 group-open/tool:py-2 dark:text-gray-300 dark:hover:text-gray-100">
        <span className="text-gray-400 dark:text-gray-500">▸</span>
        <span className="font-mono font-medium text-gray-900 dark:text-gray-100">{name}</span>
        {tool?.proposal_id ? <span className="text-gray-600 dark:text-gray-400">Proposal #{tool.proposal_id} {tool.proposal_state_label ? `created (${tool.proposal_state_label})` : ""}</span> : null}
      </summary>
      <pre className="overflow-x-auto px-3 pb-3 font-mono text-gray-700 whitespace-pre-wrap break-words dark:text-gray-300">{JSON.stringify(tool?.payload || fallback, null, 2)}</pre>
    </details>
  )
}

function SystemMessage({ item, prefix }: { item: ChatSystemMessage; prefix: string }) {
  const colors = {
    success: "border-emerald-200 bg-emerald-50 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-100",
    warning: "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100",
    error: "border-red-200 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-100",
    neutral: "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return (
    <div className="flex justify-center">
      <div className={`inline-flex max-w-full items-center gap-2 rounded-full border px-3 py-1 text-xs ${colors[item.tone]}`}>
        <span className="shrink-0 rounded bg-white/70 px-1.5 py-0.5 font-medium uppercase tracking-wide dark:bg-black/25">{item.label}</span>
        <span className="min-w-0 break-words">{item.body}</span>
        {item.cta ? (
          <Link className="shrink-0 font-medium underline hover:no-underline" to={withRoutePrefix(item.cta.path, prefix)}>
            {item.cta.label}
          </Link>
        ) : null}
      </div>
    </div>
  )
}

type EditableProposal = Pick<ChatProposal, "id" | "title" | "slug" | "body" | "proposed" | "app_update_path"> & {
  dependency_slugs?: string[]
  dependencies?: ChatProposalDependency[]
  depends_on_job_ids?: number[]
  depends_on_epic_ids?: number[]
}

type DependencyPill = {
  key: string
  label: string
  detail?: string
}

function ProposalEditModal({ chatId, proposal, search, queryKey, onClose, onNotice }: { chatId: string | number; proposal: EditableProposal; search: string; queryKey: ChatQueryKey; onClose: () => void; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [title, setTitle] = useState(proposal.title)
  const [body, setBody] = useState(proposal.body)
  const [activeTab, setActiveTab] = useState<"edit" | "preview">("edit")
  const [proposalDeps, setProposalDeps] = useState<DependencyPill[]>(initialProposalDependencyPills(proposal))
  const [jobDeps, setJobDeps] = useState<DependencyPill[]>((proposal.depends_on_job_ids || []).map((id) => ({ key: String(id), label: `JOB-${id}` })))
  const [epicDeps, setEpicDeps] = useState<DependencyPill[]>((proposal.depends_on_epic_ids || []).map((id) => ({ key: String(id), label: `EPIC-${id}` })))
  const [proposalQuery, setProposalQuery] = useState("")
  const [jobQuery, setJobQuery] = useState("")
  const [epicQuery, setEpicQuery] = useState("")
  const [proposalResults, setProposalResults] = useState<ChatProposalSearchResult[]>([])
  const [jobResults, setJobResults] = useState<ChatJobDependencySearchResult[]>([])
  const [epicResults, setEpicResults] = useState<ChatEpicDependencySearchResult[]>([])
  const searchProposals = useCallback((query: string, signal: AbortSignal) => searchChatProposals(chatId, query, proposal.id, { signal }), [chatId, proposal.id])
  const searchJobs = useCallback((query: string, signal: AbortSignal) => searchChatJobs(query, { signal }), [])
  const searchEpics = useCallback((query: string, signal: AbortSignal) => searchChatEpics(query, { signal }), [])

  const save = useMutation({
    mutationFn: () => updateChatProposal(appendSearch(proposal.app_update_path, search), {
      title: title.trim(),
      body,
      dependency_slugs: proposalDeps.map((dep) => dep.key),
      depends_on_job_ids: jobDeps.map((dep) => Number(dep.key)).filter((id) => Number.isFinite(id)),
      depends_on_epic_ids: epicDeps.map((dep) => Number(dep.key)).filter((id) => Number.isFinite(id))
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || "Proposal updated")
      onClose()
    }
  })

  useDebouncedDependencySearch(proposalQuery, searchProposals, setProposalResults)
  useDebouncedDependencySearch(jobQuery, searchJobs, setJobResults)
  useDebouncedDependencySearch(epicQuery, searchEpics, setEpicResults)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (title.trim().length === 0) return
    save.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-3 py-6">
      <div className="max-h-full w-full max-w-5xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-950" role="dialog" aria-modal="true" aria-labelledby="proposal-edit-title">
        <form onSubmit={submit}>
          <div className="flex items-center justify-between border-b border-gray-200 px-5 py-4 dark:border-gray-800">
            <div>
              <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="proposal-edit-title">Edit proposal</h2>
              <p className="mt-0.5 font-mono text-xs text-gray-500 dark:text-gray-400">{proposal.slug}</p>
            </div>
            <button className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button" aria-label="Close proposal editor">
              <CloseIcon className="h-4 w-4" />
            </button>
          </div>
          <div className="space-y-5 px-5 py-4">
            {save.isError ? <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">{errorMessage(save.error, "Proposal update failed.")}</div> : null}
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-200">
              Title
              <input
                className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                onChange={(event) => setTitle(event.target.value)}
                required
                type="text"
                value={title}
              />
            </label>
            <div>
              <div className="mb-2 flex gap-2 sm:hidden">
                {(["edit", "preview"] as const).map((tab) => (
                  <button className={`rounded border px-3 py-1 text-sm ${activeTab === tab ? "border-blue-600 bg-blue-50 text-blue-700 dark:border-blue-500 dark:bg-blue-950 dark:text-blue-200" : "border-gray-300 text-gray-600 dark:border-gray-700 dark:text-gray-300"}`} key={tab} onClick={() => setActiveTab(tab)} type="button">
                    {tab === "edit" ? "Edit" : "Preview"}
                  </button>
                ))}
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                <label className={`${activeTab === "preview" ? "hidden sm:block" : "block"} text-sm font-medium text-gray-700 dark:text-gray-200`}>
                  Body
                  <textarea
                    className="mt-1 h-72 w-full resize-y rounded border border-gray-300 bg-white px-3 py-2 font-mono text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                    onChange={(event) => setBody(event.target.value)}
                    value={body}
                  />
                </label>
                <div className={`${activeTab === "edit" ? "hidden sm:block" : "block"}`}>
                  <div className="text-sm font-medium text-gray-700 dark:text-gray-200">Preview</div>
                  <div className="mt-1 h-72 overflow-y-auto rounded border border-gray-200 bg-gray-50 px-3 py-2 dark:border-gray-800 dark:bg-gray-900">
                    <Markdown className="chat-prose text-sm text-gray-800 dark:text-gray-100" text={body} />
                  </div>
                </div>
              </div>
            </div>
            <div className="grid gap-4 lg:grid-cols-3">
              <DependencyPicker
                label="Proposal dependencies"
                placeholder="Search proposals"
                query={proposalQuery}
                results={proposalResults.map((result) => ({ key: result.slug, label: result.slug, detail: result.title }))}
                selected={proposalDeps}
                setQuery={setProposalQuery}
                setSelected={setProposalDeps}
              />
              <DependencyPicker
                label="Job dependencies"
                placeholder="Search Jobs"
                query={jobQuery}
                results={jobResults.map((result) => ({ key: String(result.id), label: `JOB-${result.id}`, detail: result.issue_title || result.title || "" }))}
                selected={jobDeps}
                setQuery={setJobQuery}
                setSelected={setJobDeps}
              />
              <DependencyPicker
                label="Epic dependencies"
                placeholder="Search Epics"
                query={epicQuery}
                results={epicResults.map((result) => ({ key: String(result.id), label: result.display_number || `EPIC-${result.id}`, detail: result.title }))}
                selected={epicDeps}
                setQuery={setEpicQuery}
                setSelected={setEpicDeps}
              />
            </div>
          </div>
          <div className="flex justify-end gap-2 border-t border-gray-200 px-5 py-4 dark:border-gray-800">
            <button className={secondaryButton()} onClick={onClose} type="button">Cancel</button>
            <button className={primaryButton()} disabled={save.isPending || title.trim().length === 0} type="submit">Save</button>
          </div>
        </form>
      </div>
    </div>
  )
}

function DependencyPicker({ label, placeholder, query, results, selected, setQuery, setSelected }: { label: string; placeholder: string; query: string; results: DependencyPill[]; selected: DependencyPill[]; setQuery: (query: string) => void; setSelected: (selected: DependencyPill[]) => void }) {
  const selectedKeys = new Set(selected.map((item) => item.key))
  const availableResults = results.filter((item) => !selectedKeys.has(item.key))
  return (
    <div>
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-200">
        {label}
        <input
          className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          onChange={(event) => setQuery(event.target.value)}
          placeholder={placeholder}
          type="text"
          value={query}
        />
      </label>
      {availableResults.length > 0 ? (
        <div className="mt-1 max-h-36 overflow-y-auto rounded border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-900">
          {availableResults.map((result) => (
            <button
              className="block w-full px-3 py-2 text-left text-sm hover:bg-blue-50 dark:hover:bg-blue-950"
              key={result.key}
              onClick={() => {
                setSelected([...selected, result])
                setQuery("")
              }}
              type="button"
            >
              <span className="font-medium text-gray-900 dark:text-gray-100">{result.label}</span>
              {result.detail ? <span className="ml-2 text-gray-500 dark:text-gray-400">{result.detail}</span> : null}
            </button>
          ))}
        </div>
      ) : null}
      <div className="mt-2 flex flex-wrap gap-2">
        {selected.map((item) => (
          <span className="inline-flex max-w-full items-center gap-1 rounded border border-gray-200 bg-gray-50 px-2 py-1 text-xs text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={item.key}>
            <span className="min-w-0 truncate font-medium">{item.label}</span>
            {item.detail ? <span className="min-w-0 truncate text-gray-500 dark:text-gray-400">{item.detail}</span> : null}
            <button className="ml-1 rounded text-gray-400 hover:text-red-600 dark:hover:text-red-300" onClick={() => setSelected(selected.filter((selectedItem) => selectedItem.key !== item.key))} type="button" aria-label={`Remove ${item.label}`}>
              <CloseIcon className="h-3 w-3" />
            </button>
          </span>
        ))}
      </div>
    </div>
  )
}

function useDebouncedDependencySearch<T>(query: string, searcher: (query: string, signal: AbortSignal) => Promise<T[]>, setResults: (results: T[]) => void) {
  useEffect(() => {
    const trimmed = query.trim()
    if (trimmed.length === 0) {
      setResults([])
      return
    }

    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      searcher(trimmed, controller.signal)
        .then(setResults)
        .catch((error) => {
          if (error.name !== "AbortError") setResults([])
        })
    }, 200)

    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [query, searcher, setResults])
}

function initialProposalDependencyPills(proposal: EditableProposal) {
  const details = new Map((proposal.dependencies || []).map((dependency) => [dependency.slug, dependency.title]))
  return (proposal.dependency_slugs || []).map((slug) => ({ key: slug, label: slug, detail: details.get(slug) }))
}

type ProposalActionInput = { action: "confirm" | "reject"; path: string; start?: boolean }

function ProposalCard({ proposal, prefix, queryKey, onNotice }: { proposal: ChatProposal; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [editingProposal, setEditingProposal] = useState<EditableProposal | null>(null)
  const childJobCount = proposal.children?.length || 0
  const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })
  const currentUser = bootstrap.data?.current_user
  const showConfirmAndStart = proposal.epic_bundle && (currentUser?.role === "developer" || currentUser?.admin === true)
  const proposalAction = useMutation({
    mutationFn: (input: ProposalActionInput) => {
      const path = appendSearch(input.path, search)
      return input.action === "confirm" ? confirmChatProposal(path, { start: input.start }) : rejectChatProposal(path)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  return (
    <>
      <ConfirmationCard
        muted={proposal.resolved}
        proposalCard
        header={
          <>
            <div className="flex items-start justify-between gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="rounded bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-700 dark:bg-indigo-950 dark:text-indigo-200">{proposal.epic_bundle ? "Epic" : proposal.kind_label}</span>
                <span className={`rounded px-2 py-0.5 text-xs font-medium ${proposal.proposed ? "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{proposal.state_label}</span>
                {proposal.epic_bundle ? <span className="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{proposal.active_children_count || 0} child Jobs</span> : null}
              </div>
              {proposal.proposed ? <ProposalEditButton label={`Edit ${proposal.slug}`} onClick={() => setEditingProposal(proposal)} /> : null}
            </div>
          <ProposalDependencyStrip dependencies={proposal.dependencies} hasDependencies={proposal.has_dependencies} prefix={prefix} />
          <h3 className="mt-2 text-base font-semibold text-gray-900 dark:text-gray-100">{proposal.title}</h3>
          <p className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">{proposal.slug}</p>
        </>
      }
      body={
        <>
          <Markdown className="chat-prose text-sm text-gray-800 dark:text-gray-100" text={proposal.body} />
          {proposal.epic_bundle ? <ProposalChildren children={proposal.children || []} parentProposed={proposal.proposed} mutation={proposalAction} prefix={prefix} onEdit={(child) => setEditingProposal(editableChildProposal(child))} /> : <ProposalMeta proposal={proposal} />}
        </>
      }
      footer={
        <>
          <ProposalResultFooter proposal={proposal} prefix={prefix} onNotice={onNotice} />
          {proposal.proposed ? (
            <div className="mt-4 flex flex-wrap gap-2">
              <button
                className={showConfirmAndStart ? secondaryButton() : primaryButton()}
                disabled={proposalAction.isPending}
                onClick={() => proposalAction.mutate({ action: "confirm", path: proposal.app_confirm_path })}
                type="button"
              >
                {proposalConfirmLabel(proposal, childJobCount)}
              </button>
              {showConfirmAndStart ? (
                <button
                  className={primaryButton()}
                  disabled={proposalAction.isPending}
                  onClick={() => proposalAction.mutate({ action: "confirm", path: proposal.app_confirm_path, start: true })}
                  type="button"
                >
                  {t("create_epic_and_start")}
                </button>
              ) : null}
              <button
                className={secondaryButton()}
                disabled={proposalAction.isPending}
                onClick={() => proposalAction.mutate({ action: "reject", path: proposal.app_reject_path })}
                type="button"
              >
                Reject
              </button>
              {proposalAction.isError ? <div className="basis-full text-xs text-red-700 dark:text-red-300">{errorMessage(proposalAction.error, "Proposal command failed.")}</div> : null}
            </div>
          ) : null}
        </>
      }
      />
      {editingProposal ? <ProposalEditModal chatId={queryKey[1]} proposal={editingProposal} search={search} queryKey={queryKey} onClose={() => setEditingProposal(null)} onNotice={onNotice} /> : null}
    </>
  )
}

function ProposalEditButton({ label, onClick }: { label: string; onClick: (event: ReactMouseEvent<HTMLButtonElement>) => void }) {
  return (
    <button className="shrink-0 rounded border border-gray-200 p-1.5 text-gray-500 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:text-gray-400 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200" onClick={onClick} type="button" aria-label={label}>
      <PencilIcon className="h-4 w-4" />
    </button>
  )
}

function editableChildProposal(child: ChatProposalChild): EditableProposal {
  return {
    id: child.id,
    title: child.title,
    slug: child.slug,
    body: child.body,
    proposed: child.proposed,
    app_update_path: child.app_update_path,
    dependency_slugs: child.dependencies,
    dependencies: (child.dependency_details || []).map((dependency) => ({
      slug: dependency.slug,
      title: dependency.title,
      state: "",
      confirmed: dependency.confirmed,
      materialized_label: dependency.materialized_label,
      materialized_path: dependency.materialized_path
    })),
    depends_on_job_ids: child.depends_on_job_ids || [],
    depends_on_epic_ids: child.depends_on_epic_ids || []
  }
}

function proposalConfirmLabel(proposal: ChatProposal, childJobCount: number) {
  if (!proposal.epic_bundle) return "Confirm"

  return childJobCount > 0 ? "Confirm Epic and Jobs" : "Confirm Epic"
}

function PendingActionCard({ pendingAction, queryKey, onNotice, onSelectMessage }: { pendingAction: ChatPendingActionInline | ChatPendingAction; queryKey: ChatQueryKey; onNotice: (message: string | null) => void; onSelectMessage?: (messageId: number) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const action = useMutation({
    mutationFn: (input: { action: "confirm" | "reject"; path: string }) => {
      const path = appendSearch(input.path, search)
      return input.action === "confirm" ? confirmPendingAction(path) : rejectPendingAction(path)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const terminalLabel = pendingActionTerminalLabel(pendingAction.state)
  const actionKey = pendingActionKey(pendingAction)
  const rejectLabel = actionKey === "schedule_recurring" ? "Cancel" : "Decline"
  const isQueued = pendingAction.state === "queued"
  const isPending = pendingAction.state === "pending"
  const rejectPath = pendingAction.app_reject_path
  const chatMessageId = "chat_message_id" in pendingAction ? pendingAction.chat_message_id : null
  const resourceTitle = pendingActionResourceTitle(pendingAction)
  const resourceUrl = pendingActionResourceUrl(pendingAction)

  return (
    <ConfirmationCard
      muted={Boolean(terminalLabel)}
      header={
        <>
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-700 dark:bg-indigo-950 dark:text-indigo-200">{pendingActionBadgeLabel(pendingAction)}</span>
            <span className={`rounded px-2 py-0.5 text-xs font-medium ${isPending ? "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{isQueued ? "Waiting..." : terminalLabel || "Needs confirmation"}</span>
          </div>
          {chatMessageId && onSelectMessage ? (
            <h3 className="mt-2 text-base font-semibold">
              <a
                className="break-words text-blue-700 hover:underline dark:text-blue-300"
                href={`#message-${chatMessageId}`}
                onClick={(event) => {
                  event.preventDefault()
                  onSelectMessage(chatMessageId)
                }}
              >
                {pendingAction.label}
              </a>
            </h3>
          ) : (
            <h3 className="mt-2 text-base font-semibold text-gray-900 dark:text-gray-100">{terminalLabel ? pendingAction.label : linkifySlugs(pendingAction.label)}</h3>
          )}
        </>
      }
      body={
        resourceTitle || pendingAction.detail ? (
          <>
            {resourceTitle && resourceUrl ? (
              <a className="inline-block break-words text-sm font-medium text-blue-700 hover:underline dark:text-blue-300" href={resourceUrl}>{resourceTitle}</a>
            ) : resourceTitle ? (
              <p className="break-words text-sm font-medium text-gray-700 dark:text-gray-300">{resourceTitle}</p>
            ) : null}
            {pendingAction.detail ? <PendingActionDetail detail={pendingAction.detail} /> : null}
          </>
        ) : null
      }
      footer={
        terminalLabel ? (
          <div className="flex flex-wrap items-center gap-2 border-t border-gray-100 pt-3 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-300">
            <span className={`rounded px-2 py-0.5 font-medium ${pendingAction.state === "confirmed" ? "bg-green-50 text-green-700 dark:bg-green-950 dark:text-green-200" : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"}`}>{terminalLabel}</span>
          </div>
        ) : isPending ? (
          <div className="flex flex-wrap gap-2">
            <button
              className={primaryButton()}
              disabled={action.isPending}
              onClick={() => action.mutate({ action: "confirm", path: pendingAction.app_confirm_path })}
              type="button"
            >
              Confirm
            </button>
            <button
              className={secondaryButton()}
              disabled={action.isPending}
              onClick={() => action.mutate({ action: "reject", path: rejectPath })}
              type="button"
            >
              {rejectLabel}
            </button>
            {action.isError ? <div className="basis-full text-xs text-red-700 dark:text-red-300">{errorMessage(action.error, "Pending action failed.")}</div> : null}
          </div>
        ) : null
      }
    />
  )
}

function pendingActionTerminalLabel(state: ChatPendingAction["state"] | ChatPendingActionInline["state"]) {
  if (state === "confirmed") return "Confirmed"
  if (state === "rejected") return "Rejected"
  if (state === "cancelled") return "Cancelled"
  return null
}

function pendingActionResourceTitle(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  return "resource_title" in pendingAction ? pendingAction.resource_title : null
}

function pendingActionResourceUrl(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  return "resource_url" in pendingAction ? pendingAction.resource_url : null
}

function pendingActionKey(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  return pendingAction.action || ("action_type" in pendingAction ? pendingAction.action_type : null)
}

function pendingActionBadgeLabel(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  const actionKey = pendingActionKey(pendingAction)
  if (actionKey === "submit_chat_feedback") return "Submit feedback"
  if (actionKey === "cancel_job") return "Cancel"
  if (actionKey === "retry_job") return "Retry"
  if (actionKey === "rebase_job") return "Rebase"
  if (actionKey === "reopen_job") return "Reopen"
  if ("action_type" in pendingAction && pendingAction.action_type) return pendingAction.action_type.replace(/_/g, " ")
  return "Action"
}

function PendingActionDetail({ detail }: { detail: string }) {
  return (
    <div className="mt-2 max-h-40 overflow-y-auto rounded border border-gray-200 bg-gray-50 px-3 py-2 dark:border-gray-800 dark:bg-gray-950">
      <Markdown className="chat-prose text-xs text-gray-700 dark:text-gray-300" text={detail} />
    </div>
  )
}

function ProposalDependencyStrip({ dependencies, hasDependencies, prefix }: { dependencies: ChatProposalDependency[]; hasDependencies: boolean; prefix: string }) {
  if (!hasDependencies) {
    return <div className="mt-2 text-xs font-medium text-gray-500 dark:text-gray-400">No dependencies</div>
  }

  return (
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
      <span className="font-medium text-gray-700 dark:text-gray-200">Depends on:</span>
      {dependencies.map((dependency) => (
        <ProposalDependencyLink dependency={dependency} key={dependency.slug} prefix={prefix} />
      ))}
    </div>
  )
}

function ProposalDependencyLink({ dependency, prefix }: { dependency: ChatProposalDependency; prefix: string }) {
  const title = dependency.display_label || dependency.materialized_label || dependency.title
  const label = dependency.display_label ? title : `${title} ${dependency.confirmed ? "✓" : "⏳"}`
  const className = "inline-flex max-w-full items-center gap-1 rounded border border-gray-200 bg-gray-50 px-2 py-0.5 font-medium text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200"

  if (dependency.anchor_message_id) {
    return <a className={className} href={`#message-${dependency.anchor_message_id}`}>{label}</a>
  }

  if (dependency.materialized_path) {
    return <Link className={className} to={withRoutePrefix(dependency.materialized_path, prefix)}>{label}</Link>
  }

  return <span className={className}>{label}</span>
}

function ProposalResultFooter({ proposal, prefix, onNotice }: { proposal: ChatProposal; prefix: string; onNotice: (message: string | null) => void }) {
  if (proposal.state === "confirmed") {
    return (
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-gray-100 pt-3 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-300">
        <span className="rounded bg-green-50 px-2 py-0.5 font-medium text-green-700 dark:bg-green-950 dark:text-green-200">Confirmed</span>
        <ProposalMaterializedResult proposal={proposal} prefix={prefix} />
        <StartEpicButton proposal={proposal} onNotice={onNotice} />
      </div>
    )
  }

  if (proposal.state === "rejected" || proposal.state === "withdrawn") {
    const label = proposal.state === "withdrawn" ? "Withdrawn" : "Rejected"
    return (
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-gray-100 pt-3 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-300">
        <span className="rounded bg-gray-100 px-2 py-0.5 font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-200">{label}</span>
      </div>
    )
  }

  return null
}

function ProposalMaterializedResult({ proposal, prefix }: { proposal: ChatProposal; prefix: string }) {
  const materialized = proposal.materialized
  if (materialized?.kind === "job") {
    const label = proposal.materialized_label || `JOB-${materialized.job_id}`
    return (
      <span>
        → <ProposalResultLink path={proposal.materialized_path} prefix={prefix}>{label}</ProposalResultLink>{materialized.job_title ? ` "${materialized.job_title}"` : ""}
      </span>
    )
  }

  if (materialized?.kind === "epic") {
    const children = materialized.child_jobs.filter((job) => job.job_id)
    return (
      <>
        <span>
          → Epic <ProposalResultLink path={proposal.materialized_path} prefix={prefix}>#{materialized.epic_id}</ProposalResultLink>{materialized.epic_title ? ` "${materialized.epic_title}"` : ""}
        </span>
        {children.length > 0 ? (
          <span className="basis-full sm:basis-auto">
            Jobs: {children.map((job, index) => (
              <span key={`${job.job_id}-${index}`}>
                {index > 0 ? ", " : ""}
                JOB-{job.job_id}{job.title ? ` "${job.title}"` : ""}
              </span>
            ))}
          </span>
        ) : null}
      </>
    )
  }

  if (proposal.materialized_label && proposal.materialized_path) {
    return (
      <span>
        → <ProposalResultLink path={proposal.materialized_path} prefix={prefix}>{proposal.materialized_label}</ProposalResultLink>
      </span>
    )
  }

  return null
}

function ProposalResultLink({ path, prefix, children }: { path: string | null; prefix: string; children: ReactNode }) {
  if (!path) return <>{children}</>

  return <Link className="font-medium text-blue-700 hover:underline dark:text-blue-300" to={withRoutePrefix(path, prefix)}>{children}</Link>
}

function ProposalMeta({ proposal }: { proposal: ChatProposal }) {
  return (
    <dl className="mt-3 grid gap-2 text-xs text-gray-600 sm:grid-cols-2 dark:text-gray-300">
      <div><dt className="font-medium text-gray-500 dark:text-gray-400">Attached scope</dt><dd>{proposal.scoped_repository_slug || "No repository attached"}</dd></div>
      <div>
        <dt className="font-medium text-gray-500 dark:text-gray-400">Dependencies</dt>
        <dd>{(proposal.dependency_slugs || []).length > 0 ? <PillList values={proposal.dependency_slugs || []} /> : "None"}</dd>
      </div>
      {proposal.target_epic_label ? <div><dt className="font-medium text-gray-500 dark:text-gray-400">Target Epic</dt><dd>{proposal.target_epic_label}</dd></div> : null}
    </dl>
  )
}

function ProposalChildren({ children, parentProposed, mutation, prefix, onEdit }: { children: ChatProposalChild[]; parentProposed: boolean; mutation: UseMutationResult<ChatPayload, Error, ProposalActionInput>; prefix: string; onEdit: (child: ChatProposalChild) => void }) {
  if (children.length === 0) return null
  return (
    <div className="mt-4 divide-y divide-gray-100 rounded border border-gray-200 dark:divide-gray-800 dark:border-gray-700">
      {children.map((child) => (
        <details className="group" key={child.id}>
          <summary className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-800">
            <span className="text-gray-400 group-open:rotate-90 dark:text-gray-500">▸</span>
            <span className="min-w-0 flex-1 truncate font-medium text-gray-900 dark:text-gray-100">{child.title}</span>
            {child.dependencies.length > 0 ? <ChildDependencySummary child={child} prefix={prefix} /> : null}
            <span className={`shrink-0 rounded px-2 py-0.5 text-xs font-medium ${child.proposed ? "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{child.state_label}</span>
            {child.proposed && parentProposed ? <ProposalEditButton label={`Edit ${child.slug}`} onClick={(event) => { event.stopPropagation(); onEdit(child) }} /> : null}
          </summary>
          <div className="border-t border-gray-100 px-8 py-3 text-sm text-gray-700 dark:border-gray-800 dark:text-gray-300">
            <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400"><span className="font-mono">{child.slug}</span><span>{child.repository_slug || "No repository attached"}</span></div>
            <Markdown className="chat-prose mt-2 text-sm text-gray-800 dark:text-gray-100" text={child.body} />
            {child.proposed && parentProposed ? (
              <div className="mt-3">
                <button
                  className="rounded border border-red-200 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-300 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950 dark:disabled:text-gray-600"
                  disabled={mutation.isPending}
                  onClick={() => mutation.mutate({ action: "reject", path: child.app_reject_path })}
                  type="button"
                >
                  Reject child Job
                </button>
              </div>
            ) : null}
          </div>
        </details>
      ))}
    </div>
  )
}

function ChildDependencySummary({ child, prefix }: { child: ChatProposalChild; prefix: string }) {
  const details = child.dependency_details || []
  const collapsedPillClass = "shrink-0 rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300"

  if (details.length === 0) {
    if (child.dependencies.length >= 2) {
      return <span className={collapsedPillClass} title={child.dependencies.join(", ")}>{child.dependencies.length} dependencies</span>
    }
    return <span className="shrink-0 rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">depends on {child.dependencies.join(", ")}</span>
  }

  if (details.length >= 2) {
    return <span className={collapsedPillClass} title={details.map((d) => d.slug).join(", ")}>{details.length} dependencies</span>
  }

  return (
    <span className="flex shrink-0 flex-wrap items-center justify-end gap-1 text-xs">
      <span className="text-gray-500 dark:text-gray-400">depends on</span>
      {details.map((dependency) => (
        <ChildDependencyPill dependency={dependency} key={dependency.slug} prefix={prefix} />
      ))}
    </span>
  )
}

function ChildDependencyPill({ dependency, prefix }: { dependency: ChatProposalChildDependency; prefix: string }) {
  const label = dependency.materialized_label || dependency.slug
  const scopeLabel = dependency.scope === "cross_card" ? "cross-card" : "sibling"
  const className = dependency.scope === "cross_card"
    ? "rounded border border-blue-200 bg-blue-50 px-2 py-0.5 font-mono text-xs text-blue-700 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-200"
    : "rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300"
  const content = <>{label}<span className="ml-1 font-sans text-[10px] uppercase">{scopeLabel}</span></>

  if (dependency.materialized_path) {
    return <Link className={className} to={withRoutePrefix(dependency.materialized_path, prefix)}>{content}</Link>
  }

  return <span className={className}>{content}</span>
}

function Compose({ autoFocus = false, chatId, commandHandlers, payload, prefix, queryKey, showAttachedRepositories = false, onNotice, onMessageSent }: { autoFocus?: boolean; chatId: string; commandHandlers: ChatSystemCommandHandlers; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; showAttachedRepositories?: boolean; onNotice: (message: string | null) => void; onMessageSent?: () => void }) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const { t } = useT("chat")
  const [text, setText] = useState(() => {
    try {
      return window.localStorage.getItem(CHAT_DRAFT_KEY_PREFIX + chatId) || ""
    } catch (_error) {
      return ""
    }
  })
  const [attachments, setAttachments] = useState<ChatComposeAttachment[]>([])
  const [annotatingIndex, setAnnotatingIndex] = useState<number | null>(null)
  const [attachmentError, setAttachmentError] = useState<string | null>(null)
  const [isDragOver, setIsDragOver] = useState(false)
  const [pendingConfirmation, setPendingConfirmation] = useState<PendingSlashCommandConfirmation | null>(null)
  const [activeCommandIndex, setActiveCommandIndex] = useState(0)
  const [clearConfirmationOpen, setClearConfirmationOpen] = useState(false)
  const [reportDialogOpen, setReportDialogOpen] = useState(false)
  const [attachmentPopoverOpen, setAttachmentPopoverOpen] = useState(false)
  // One walkthrough video per message (v1). The chip above the composer
  // narrates its lifecycle: ready -> uploading(pct) -> analyzing -> failed;
  // an analyzed walkthrough clears the chip (its turn appears in the thread).
  const [walkthrough, setWalkthrough] = useState<WalkthroughDraft | null>(null)
  // Reassuring lines the chip rotates through while Gemini analyzes — the wait
  // can run minutes, so a single frozen line reads as stuck. The first entry is
  // the original static copy so nothing regresses if rotation is suppressed
  // (single message / prefers-reduced-motion).
  const walkthroughAnalyzingHints = useMemo(
    () => [
      t("walkthrough_analyzing"),
      t("walkthrough_analyzing_narration"),
      t("walkthrough_analyzing_issues"),
      t("walkthrough_analyzing_screenshots"),
      t("walkthrough_analyzing_finishing")
    ],
    [t]
  )
  const [geminiSheetOpen, setGeminiSheetOpen] = useState(false)
  const pendingVideoRef = useRef<File | null>(null)
  const walkthroughKeyRef = useRef(0)
  const [scratchpadOpen, setScratchpadOpen] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const attachmentPopoverRef = useRef<HTMLDivElement | null>(null)
  const addAttachmentButtonRef = useRef<HTMLButtonElement | null>(null)
  const submitWithEnter = useSubmitChatWithEnter()
  const search = queryKey[2]
  const agentActive = isAgentActive(payload)
  const queuedMessages = payload.queued_messages || []
  const [dismissedSuggestion, setDismissedSuggestion] = useState<string | null>(null)
  const suggestionShownAtRef = useRef(0)
  const commandQuery = slashCommandQuery(text)
  const matchingCommands = useMemo(() => commandQuery == null ? [] : filterSlashCommands(commandQuery), [commandQuery])
  const pendingProposals = useMemo(() => {
    const seenIds = new Set<number>()
    return payload.messages.filter(
      (item): item is typeof item & { proposal: ChatProposal } => {
        if (item.type !== "message" || item.proposal?.proposed !== true) return false
        if (seenIds.has(item.proposal.id)) return false
        seenIds.add(item.proposal.id)
        return true
      }
    )
  }, [payload.messages])
  const [jumpIndex, setJumpIndex] = useState(0)
  const attachedRepositories = payload.attachment_groups.repositories

  useEffect(() => {
    if (text.length > 0) {
      storeWorkspacePreference(CHAT_DRAFT_KEY_PREFIX + chatId, text)
      return
    }

    try {
      window.localStorage.removeItem(CHAT_DRAFT_KEY_PREFIX + chatId)
    } catch (_error) {
      // Local storage can be unavailable in hardened browser modes.
    }
  }, [chatId, text])

  const send = useMutation({
    mutationFn: (messageText: string) => agentActive
      ? enqueueChatMessage(appendSearch(payload.paths.app_enqueue_message_path, search), messageText, attachments)
      : sendChatMessage(appendSearch(payload.paths.app_message_path, search), messageText, attachments),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, currentRecentChat(updated) || updated.chat, { prepend: true })
      setText("")
      try {
        window.localStorage.removeItem(CHAT_DRAFT_KEY_PREFIX + chatId)
      } catch (_error) {
        // Local storage can be unavailable in hardened browser modes.
      }
      setAttachments([])
      setAttachmentError(null)
      setPendingConfirmation(null)
      onNotice(null)
      onMessageSent?.()
    }
  })
  const systemAction = useMutation<ChatPayload | ChatCreatedPayload | ChatBranchPayload | ShareChatPayload, Error, ChatSystemAction>({
    mutationFn: (action) => {
      if (action.kind === "rename") return renameChat(appendSearch(payload.paths.app_rename_path, search), action.title)
      if (action.kind === "clear") return clearChatHistory(appendSearch(payload.paths.app_clear_path, search))
      if (action.kind === "new") return createChat({ repositoryId: payload.chat.repository ? String(payload.chat.repository.id) : "", text: "" })
      if (action.kind === "pin") return updateChatPinned(chatId, action.pinned)
      if (action.kind === "branch") return branchChat(appendSearch(payload.paths.app_branch_path, search))
      if (action.kind === "share") return shareChat(appendSearch(payload.paths.app_share_path, search))
      return attachChatRepository(appendSearch(payload.paths.app_attachments_path, search), action.slug)
    },
    onSuccess: async (updated, action) => {
      if (action.kind === "new") {
        const created = updated as ChatCreatedPayload
        updateRecentChatCache(queryClient, created.chat, { prepend: true })
        refreshRecentChats(queryClient)
        navigate(withRoutePrefix(created.redirect_to, prefix))
        return
      }

      if (action.kind === "branch") {
        const branched = updated as ChatBranchPayload
        refreshRecentChats(queryClient)
        navigate(withRoutePrefix(branched.app_path, prefix))
        return
      }

      if (action.kind === "share") {
        await navigator.clipboard.writeText((updated as ShareChatPayload).share_url)
        setText("")
        onNotice("Share link copied to clipboard")
        return
      }

      const chatPayload = updated as ChatPayload
      queryClient.setQueryData(queryKey, chatPayload)
      updateRecentChatCache(queryClient, chatPayload.chat)
      refreshRecentChats(queryClient)
      setText("")
      setClearConfirmationOpen(false)
      onNotice(action.kind === "pin" ? (action.pinned ? "Chat pinned" : "Chat unpinned") : chatPayload.message || null)
      if (action.kind === "attach") commandHandlers.openAttachments()
    }
  })
  const systemCommandAction = useMutation<{ payload?: ChatPayload; notice: string; jobId?: string }, Error, ChatSystemCommandAction>({
    mutationFn: async (action) => {
      if (action.kind === "bookmark") {
        const updated = await createChatTopicBookmark(appendSearch(payload.paths.app_bookmarks_path, search), action.label)
        return { payload: updated, notice: `Bookmark saved: ${action.label}` }
      }

      if (action.kind === "discard") {
        const updated = await rejectChatProposal(appendSearch(action.path, search))
        return { payload: updated, notice: "Proposal discarded" }
      }

      if (action.kind === "job") {
        const path = `/api/v1/app/jobs/${encodeURIComponent(action.jobId)}/${action.action === "cancel" ? "cancel" : "run_again"}`
        await postJobCommand(path)
        return {
          jobId: action.jobId,
          notice: action.action === "cancel" ? "Job cancelled" : "Job queued for retry"
        }
      }

      const current = await fetchChatWhiteboard(appendSearch(payload.paths.app_whiteboard_path, search))
      let result = await patchChatWhiteboard(appendSearch(payload.paths.app_whiteboard_path, search), {
        elements: [],
        appState: {},
        files: {},
        expected_version: current.version
      })
      if (result.status === 409) {
        result = await patchChatWhiteboard(appendSearch(payload.paths.app_whiteboard_path, search), {
          elements: [],
          appState: {},
          files: {},
          expected_version: result.payload.version
        })
      }
      queryClient.setQueryData(queryKey, (currentPayload: ChatPayload | undefined) => currentPayload ? {
        ...currentPayload,
        whiteboard: {
          version: result.payload.version,
          elements: result.payload.scene_json.elements,
          appState: result.payload.scene_json.appState,
          files: result.payload.scene_json.files
        }
      } : currentPayload)
      return { notice: "Canvas cleared" }
    },
    onSuccess: (result, action) => {
      if (result.payload) {
        queryClient.setQueryData(queryKey, result.payload)
        updateRecentChatCache(queryClient, result.payload.chat)
      }
      if (action.kind === "discard") {
        void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
      }
      if (action.kind === "job" && result.jobId) {
        void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
        void queryClient.invalidateQueries({ queryKey: ["jobs", result.jobId] })
      }
      setText("")
      setPendingConfirmation(null)
      onNotice(result.notice)
    },
    onError: (error) => {
      onNotice(errorMessage(error, "Command failed."))
    }
  })
  const detachRepository = useMutation({
    mutationFn: (path: string) => deleteChatAttachment(appendSearch(path, search)),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const stash = useMutation({
    mutationFn: (content?: string) => createScratchpadItem(chatId, content ?? text),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setText("")
    }
  })
  const commandPaletteOpen = commandQuery != null
    && matchingCommands.length > 0
    && !send.isPending
    && !systemAction.isPending
    && !systemCommandAction.isPending
    && pendingConfirmation == null
  const suggestedNextStep = payload.chat.suggested_next_step || null
  const ghostSuggestion = text.length === 0 && !send.isPending && suggestedNextStep && suggestedNextStep !== dismissedSuggestion
    ? suggestedNextStep
    : null

  function submitMessage() {
    if (send.isPending || systemAction.isPending || systemCommandAction.isPending) return
    if (walkthrough?.status === "ready") {
      // A walkthrough and image/PDF attachments can't share one send: the
      // video goes to Gemini, the attachments to the chat agent — silently
      // splitting them (and leaking the images to the next message) is the
      // review finding. Block explicitly instead.
      if (attachments.length > 0) {
        setAttachmentError(t("walkthrough_no_other_attachments"))
        return
      }
      // Send commits the walkthrough: the video uploads with the typed text
      // riding along as the user's note; the analysis turn carries both.
      void uploadWalkthrough(text)
      return
    }
    // Any media makes the message sendable on its own — a bare attachment (or
    // walkthrough) IS the message, no text required.
    if (text.trim().length === 0 && attachments.length === 0) return
    const attachmentValidationError = attachmentValidationMessage(attachments)
    if (attachmentValidationError) {
      setAttachmentError(attachmentValidationError)
      return
    }
    const commandMatch = findSlashCommand(text)
    if (commandMatch?.command.requiresConfirmation) {
      onNotice(null)
      setPendingConfirmation({ commandName: commandMatch.command.name, text: text.trim() })
      return
    }

    if (commandMatch?.command.kind === "system") {
      onNotice(null)
      setPendingConfirmation(null)
      handleSystemSlashCommand(commandMatch)
      return
    }

    onNotice(null)
    setPendingConfirmation(null)
    send.mutate(slashCommandPrompt(text))
  }

  function jumpToPending() {
    const target = pendingProposals[jumpIndex % pendingProposals.length]
    if (!target) return

    document.getElementById(`chat_message_${target.id}`)?.scrollIntoView({ behavior: "smooth", block: "start" })
    setJumpIndex((index) => index + 1)
  }

  function handleSystemSlashCommand(commandMatch: SlashCommandMatch) {
    const command = commandMatch.command
    const argsText = commandMatch.argsText
    if (command.name === "/rename") {
      if (!argsText) {
        onNotice("Usage: /rename <name>")
        return
      }

      systemAction.mutate({ kind: "rename", title: argsText })
      return
    }

    if (command.name === "/clear") {
      setText("")
      setClearConfirmationOpen(true)
      onNotice(null)
      return
    }

    if (command.name === "/new") {
      systemAction.mutate({ kind: "new" })
      return
    }

    if (command.name === "/branch") {
      setText("")
      onNotice("Branching chat…")
      systemAction.mutate({ kind: "branch" })
      return
    }

    if (command.name === "/bookmarks") {
      commandHandlers.openBookmarks()
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/attach") {
      if (argsText) {
        systemAction.mutate({ kind: "attach", slug: argsText })
      } else {
        commandHandlers.openAttachments()
        setText("")
        onNotice(null)
      }
      return
    }

    if (command.name === "/settings") {
      commandHandlers.openSettings()
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/jobs") {
      const path = argsText ? `/jobs?q=${encodeURIComponent(argsText)}` : "/jobs"
      navigate(withRoutePrefix(path, prefix))
      setText("")
      return
    }

    if (command.name === "/job") {
      const id = numericArg(argsText)
      if (!id) {
        onNotice("Usage: /job <id>")
        return
      }

      navigate(withRoutePrefix(`/jobs/${id}`, prefix))
      setText("")
      return
    }

    if (command.name === "/epic") {
      const id = numericArg(argsText)
      if (!id) {
        onNotice("Usage: /epic <id>")
        return
      }

      navigate(withRoutePrefix(`/epics/${id}`, prefix))
      setText("")
      return
    }

    if (command.name === "/prs") {
      if (!payload.chat.repository) {
        onNotice("Attach a repository to view pull requests.")
        return
      }

      navigate(withRoutePrefix(`/repositories/${payload.chat.repository.id}`, prefix))
      setText("")
      return
    }

    if (command.name === "/issues") {
      if (!payload.chat.repository) {
        onNotice("Attach a repository to view issues.")
        return
      }

      navigate(withRoutePrefix(`/repositories/${payload.chat.repository.id}?tab=github_issues&state=open`, prefix))
      setText("")
      return
    }

    if (command.name === "/proposals") {
      if (!scrollToLastProposalCard()) onNotice("No proposal cards found.")
      setText("")
      return
    }

    if (command.name === "/bookmark") {
      if (!argsText) {
        onNotice("Usage: /bookmark <label>")
        return
      }

      systemCommandAction.mutate({ kind: "bookmark", label: argsText })
      return
    }

    if (command.name === "/discard") {
      const proposal = findProposalBySlug(payload, argsText)
      if (!proposal) {
        onNotice(`Proposal not found: ${argsText}`)
        return
      }

      systemCommandAction.mutate({ kind: "discard", path: proposal.app_reject_path })
      return
    }

    if (command.name === "/cancel" || command.name === "/retry") {
      const id = numericArg(argsText)
      if (!id) {
        onNotice(`Usage: ${command.name} <id>`)
        return
      }

      systemCommandAction.mutate({ kind: "job", action: command.name === "/cancel" ? "cancel" : "retry", jobId: id })
      return
    }

    if (command.name === "/clear-canvas") {
      systemCommandAction.mutate({ kind: "clear-canvas" })
      return
    }

    if (command.name === "/copy") {
      const lastAssistantMessage = lastAssistantRenderedMessage(payload.messages)
      if (!lastAssistantMessage) {
        onNotice("No assistant response to copy")
        return
      }

      void navigator.clipboard.writeText(lastAssistantMessage.text)
      setText("")
      onNotice("Copied to clipboard")
      return
    }

    if (command.name === "/search") {
      const path = argsText ? `/chats/search?q=${encodeURIComponent(argsText)}` : "/chats/search"
      navigate(withRoutePrefix(path, prefix))
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/report") {
      setReportDialogOpen(true)
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/pin") {
      systemAction.mutate({ kind: "pin", pinned: !payload.chat.pinned })
      return
    }

    if (command.name === "/share") {
      systemAction.mutate({ kind: "share" })
      return
    }

    if (command.name === "/scratch") {
      if (argsText) {
        stash.mutate(argsText, { onSuccess: () => onNotice("Stashed to scratch pad") })
      } else {
        setScratchpadOpen(true)
        setText("")
        onNotice(null)
      }
      return
    }

    setText("")
  }

  function confirmPendingSlashCommand() {
    if (!pendingConfirmation || send.isPending || systemCommandAction.isPending) return

    onNotice(null)
    const commandMatch = findSlashCommand(pendingConfirmation.text)
    if (commandMatch?.command.kind === "system") {
      handleSystemSlashCommand(commandMatch)
      return
    }

    send.mutate(pendingConfirmation.text)
  }

  function cancelPendingSlashCommand() {
    setPendingConfirmation(null)
    textareaRef.current?.focus()
  }

  function attachmentValidationMessage(nextAttachments: ChatComposeAttachment[]) {
    if (nextAttachments.some((attachment) => attachment.size > CHAT_ATTACHMENT_MAX_BYTES)) {
      return "Each attachment must be 5 MB or smaller."
    }

    const totalBytes = nextAttachments.reduce((sum, attachment) => sum + attachment.size, 0)
    if (totalBytes > CHAT_ATTACHMENT_TOTAL_MAX_BYTES) {
      return "Attachments must total 20 MB or less."
    }

    return null
  }

  // Route an incoming video (drag, picker, or a finished recording) into the
  // walkthrough draft: gate on Gemini config, duration, and size — gently,
  // with specific copy, before any bytes move.
  //
  // `knownDuration` comes from the recorder's own clock (measureVideoDuration
  // returns null for MediaRecorder webm, whose metadata duration is Infinity),
  // so recorded videos still trip the ≥12-min low-resolution gate.
  // `assumeConfigured` is set by the post-setup handoff: the calling render's
  // payload.gemini_configured is still stale (the refetch hasn't landed), but
  // the key was just saved — re-checking it would loop the setup sheet.
  async function intakeWalkthroughVideo(
    file: File,
    options: { knownDuration?: number | null; assumeConfigured?: boolean } = {}
  ) {
    // Labs flag: every video intake path (drag-in, file picker, recorder)
    // funnels through here, so one check gates them all.
    if (!payload.walkthroughs_enabled) {
      setAttachmentError(t("walkthrough_disabled"))
      return
    }
    if (!options.assumeConfigured && !payload.gemini_configured) {
      pendingVideoRef.current = file
      setGeminiSheetOpen(true)
      return
    }

    // Never clobber an in-flight walkthrough: replacing during upload would
    // orphan the running XHR, and during analysis would lose the server row.
    // Only a settled draft (ready/failed) is replaceable.
    if (walkthrough && (walkthrough.status === "uploading" || walkthrough.status === "analyzing")) {
      setAttachmentError(t("walkthrough_one_at_a_time"))
      return
    }

    if (file.size > MAX_WALKTHROUGH_BYTES) {
      setAttachmentError(t("walkthrough_too_large"))
      return
    }

    const durationSeconds = options.knownDuration ?? (await measureVideoDuration(file))
    if (durationSeconds && durationSeconds > MAX_WALKTHROUGH_DURATION_SECONDS) {
      setAttachmentError(t("walkthrough_too_long", { limit: formatClock(MAX_WALKTHROUGH_DURATION_SECONDS), actual: formatClock(durationSeconds) }))
      return
    }

    setAttachmentError(null)
    walkthroughKeyRef.current += 1
    setWalkthrough({ key: walkthroughKeyRef.current, file, filename: file.name || "walkthrough.webm", durationSeconds, status: "ready", percent: 0 })
  }

  const recorder = useWalkthroughRecorder({
    onFinished: ({ blob, mimeType, durationSeconds }) => {
      const extension = mimeType.includes("mp4") ? "mp4" : "webm"
      const file = new File([blob], `walkthrough-${new Date().toISOString().slice(0, 19).replaceAll(":", "-")}.${extension}`, { type: mimeType })
      // Pass the recorder's measured duration — the webm blob can't be
      // re-measured, so this is the only reliable source for the gate.
      void intakeWalkthroughVideo(file, { knownDuration: durationSeconds })
    }
  })

  function startWalkthroughRecording() {
    setAttachmentPopoverOpen(false)
    if (!payload.walkthroughs_enabled) {
      setAttachmentError(t("walkthrough_disabled"))
      return
    }
    if (!payload.gemini_configured) {
      setGeminiSheetOpen(true)
      return
    }
    void recorder.start()
  }

  // In the desktop shell, drive the FLOATING recording HUD (a separate
  // always-on-top, draggable window) so the controls live outside the Syrus
  // window and stay reachable while the user demonstrates another app. Returns
  // false in a plain browser, where the in-page WalkthroughRecorderHUD is used.
  const recording = recorder.state.phase === "recording"
  const recorderMicLive = recorder.state.phase === "recording" ? recorder.state.micLive : true
  // Hint text depends on the live annotation mode: HOLD (native hook) reads
  // "Hold ⌃ to draw", TAP (fallback) reads "⌘⇧A to draw" — and when hold
  // failed only for the macOS Accessibility permission, the idle hint nudges
  // the user to grant it (the tap shortcut keeps working meanwhile).
  const annotationIdleKind = annotationIdleHintKind(recorder.annotationHold, recorder.annotationReason)
  const annotationHintIdle =
    annotationIdleKind === "hold"
      ? t("walkthrough_annotate_hold_hint", { key: annotationHoldLabel() })
      : annotationIdleKind === "accessibility"
        ? t("walkthrough_annotate_accessibility_hint", { shortcut: annotationShortcutLabel() })
        : t("walkthrough_annotate_hint", { shortcut: annotationShortcutLabel() })
  const annotationHintDrawing = recorder.annotationHold
    ? t("walkthrough_annotate_hold_drawing", { key: annotationHoldLabel() })
    : t("walkthrough_annotate_drawing")
  const nativeRecorderHud = useNativeRecorderHud({
    recording,
    state: {
      clock: formatClock(recorder.elapsed),
      remaining: t("walkthrough_remaining", { clock: formatClock(Math.max(0, MAX_WALKTHROUGH_DURATION_SECONDS - recorder.elapsed)) }),
      remainingWarn: recorder.elapsed >= RECORDER_WARNING_SECONDS,
      noMic: recorderMicLive ? undefined : t("walkthrough_no_mic"),
      hint: recorder.annotationAvailable
        ? (recorder.drawing ? annotationHintDrawing : annotationHintIdle)
        : undefined,
      drawing: recorder.drawing,
      stopLabel: t("walkthrough_stop"),
      discardLabel: t("walkthrough_discard"),
      penLabel: t("walkthrough_hud_pen")
    },
    onStop: () => recorder.stop(),
    onDiscard: () => recorder.stop({ discard: true })
  })

  // Analysis progress arrives over AppUserChannel (video_walkthrough.* app
  // events re-dispatched as a DOM event by applyAppEvent).
  useEffect(() => {
    function onWalkthroughEvent(event: Event) {
      const detail = (event as CustomEvent<{ id: number; state: string; error_message: string | null; chat_session_id: number }>).detail
      if (!detail || detail.chat_session_id !== payload.chat.id) return

      // A walkthrough finishing frees the composer — clear any lingering
      // walkthrough-scoped error (e.g. a one-at-a-time rejection) so it can't
      // keep the send button disabled for the next ordinary message.
      if (detail.state === "analyzed") setAttachmentError(null)

      // A terminal state changes the chat payload's video_walkthroughs list
      // (which powers the Media panel); the app-event only carries the walkthrough
      // id/state, so refetch the payload to refresh the panel + the delivered turn.
      if (detail.state === "analyzed" || detail.state === "failed") {
        void queryClient.invalidateQueries({ queryKey })
      }

      setWalkthrough((current) => {
        if (!current || current.id == null || current.id !== detail.id) return current
        if (detail.state === "analyzed") {
          onNotice(t("walkthrough_analyzed"))
          return null // its turn appears in the thread
        }
        if (detail.state === "failed") {
          return { ...current, status: "failed", error: detail.error_message || t("walkthrough_failed_generic") }
        }
        return { ...current, status: "analyzing" }
      })
    }

    window.addEventListener("syrus:video-walkthrough", onWalkthroughEvent)
    return () => window.removeEventListener("syrus:video-walkthrough", onWalkthroughEvent)
  }, [payload.chat.id, onNotice, t, queryClient, queryKey])

  async function uploadWalkthrough(note: string) {
    if (!walkthrough || walkthrough.status !== "ready") return

    // Every state update from here on is keyed to THIS draft — if the user
    // replaces the walkthrough (only possible once it's back to a settled
    // state), a late resolution from the old upload can't corrupt the new one.
    const activeKey = walkthrough.key
    const keyed = (updater: (current: WalkthroughDraft) => WalkthroughDraft | null) =>
      setWalkthrough((current) => (current && current.key === activeKey ? updater(current) : current))

    // Clear the composer at the START of the upload, not after it resolves:
    // the text has been captured as the note, so leaving it lets a second
    // Enter double-send it and destroys a draft typed during the upload.
    setText("")
    try {
      window.localStorage.removeItem(CHAT_DRAFT_KEY_PREFIX + chatId)
    } catch (_error) {
      // Local storage can be unavailable in hardened browser modes.
    }

    keyed((current) => ({ ...current, status: "uploading", percent: 0 }))
    try {
      const { video_walkthrough } = await uploadVideoWalkthrough({
        chatSessionId: payload.chat.id,
        file: walkthrough.file,
        filename: walkthrough.filename,
        durationSeconds: walkthrough.durationSeconds,
        note: note.trim() || undefined,
        onProgress: (percent) => {
          keyed((current) => (current.status === "uploading" ? { ...current, percent } : current))
        }
      })
      keyed((current) => ({ ...current, status: "analyzing", id: video_walkthrough.id }))
    } catch (error) {
      const message = error instanceof Error ? error.message : t("walkthrough_failed_generic")
      keyed((current) => ({ ...current, status: "failed", error: message }))
    }
  }

  function retryWalkthroughAnalysis() {
    if (!walkthrough?.id) return
    setWalkthrough((current) => (current ? { ...current, status: "analyzing", error: undefined } : current))
    retryVideoWalkthrough(walkthrough.id).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : t("walkthrough_failed_generic")
      setWalkthrough((current) => (current ? { ...current, status: "failed", error: message } : current))
    })
  }

  // Paste-to-attach, ChatGPT/Claude style: an image (or any file) on the
  // clipboard becomes a composer attachment through the SAME funnel as the
  // picker and drag-in — inheriting size validation, the walkthrough video
  // split, and the one-at-a-time guard. Plain text pastes fall through to the
  // browser's default insert.
  function handlePaste(event: ReactClipboardEvent<HTMLTextAreaElement>) {
    const clipboard = event.clipboardData
    if (!clipboard) return

    let files = Array.from(clipboard.files || [])
    if (files.length === 0) {
      // Safari sometimes exposes pasted images only through items[].
      files = Array.from(clipboard.items || [])
        .filter((entry) => entry.kind === "file")
        .map((entry) => entry.getAsFile())
        .filter((file): file is File => file != null)
    }
    if (files.length === 0) return

    event.preventDefault()
    handleAttachmentChange(files)
  }

  function handleAttachmentChange(files: FileList | File[] | null) {
    let selectedFiles = Array.from(files || [])
    if (fileInputRef.current) fileInputRef.current.value = ""
    if (selectedFiles.length === 0) return

    // Videos take the walkthrough path (real upload + Gemini analysis) —
    // never the base64 message-attachment path.
    const video = payload.walkthroughs_enabled ? selectedFiles.find(isWalkthroughVideoFile) : undefined
    if (video) {
      void intakeWalkthroughVideo(video)
      selectedFiles = selectedFiles.filter((file) => !isWalkthroughVideoFile(file))
      if (selectedFiles.length === 0) return
    }

    const nextAttachments = [
      ...attachments,
      ...selectedFiles.map((file) => ({
        name: file.name,
        mimeType: file.type || "application/octet-stream",
        dataUrl: "",
        size: file.size
      }))
    ]
    const validationError = attachmentValidationMessage(nextAttachments)
    if (validationError) {
      setAttachmentError(validationError)
      return
    }

    void Promise.all(selectedFiles.map(readAttachmentFile)).then((newAttachments) => {
      setAttachments((current) => [...current, ...newAttachments])
      setAttachmentError(null)
    }).catch(() => setAttachmentError("Unable to read the selected attachment."))
  }

  function handleDragOver(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
  }

  function handleDragEnter(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
    setIsDragOver(true)
  }

  function handleDragLeave(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return

    setIsDragOver(false)
  }

  function handleDrop(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
    setIsDragOver(false)
    if (event.dataTransfer.files.length === 0) return

    handleAttachmentChange(event.dataTransfer.files)
  }

  function removeAttachment(index: number) {
    setAttachments((current) => current.filter((_, attachmentIndex) => attachmentIndex !== index))
    setAnnotatingIndex((current) => {
      if (current == null) return current
      if (current === index) return null
      return current > index ? current - 1 : current
    })
    setAttachmentError(null)
  }

  function openAttachmentFilePicker() {
    setAttachmentPopoverOpen(false)
    fileInputRef.current?.click()
  }

  function focusAttachmentPopoverItem(direction: 1 | -1) {
    const popover = attachmentPopoverRef.current
    if (!popover) return

    const focusable = Array.from(popover.querySelectorAll<HTMLElement>("button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])"))
      .filter((element) => element.offsetParent !== null || element === document.activeElement)
    if (focusable.length === 0) return

    const activeIndex = focusable.indexOf(document.activeElement as HTMLElement)
    const nextIndex = activeIndex === -1 ? 0 : (activeIndex + direction + focusable.length) % focusable.length
    focusable[nextIndex]?.focus()
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submitMessage()
  }

  function handleAttachmentPopoverKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") {
      event.preventDefault()
      setAttachmentPopoverOpen(false)
      addAttachmentButtonRef.current?.focus()
      return
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      focusAttachmentPopoverItem(1)
      return
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      focusAttachmentPopoverItem(-1)
    }
  }

  function acceptGhostSuggestion(suggestion: string) {
    updateText(suggestion)
    const textarea = textareaRef.current
    if (!textarea) return

    window.requestAnimationFrame(() => {
      textarea.setSelectionRange(suggestion.length, suggestion.length)
    })
  }

  function handleKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    // Only plain Tab (never Shift+Tab or a modifier chord) accepts the
    // ghost suggestion, and only while the focused composer is empty
    // with the ghost rendered (both implied by `ghostSuggestion` on
    // this textarea's own handler). A suggestion that appeared within
    // the grace period does not intercept — the user was mid-Tab
    // navigation, so the keystroke keeps its default focus behavior.
    if (ghostSuggestion && event.key === "Tab" && !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey) {
      if (Date.now() - suggestionShownAtRef.current < GHOST_SUGGESTION_TAB_GRACE_MS) return

      event.preventDefault()
      acceptGhostSuggestion(ghostSuggestion)
      return
    }

    if (ghostSuggestion && event.key === "Escape") {
      event.preventDefault()
      setDismissedSuggestion(ghostSuggestion)
      return
    }

    if (commandPaletteOpen && (event.key === "Tab" || event.key === "Enter")) {
      event.preventDefault()
      completeSlashCommand(matchingCommands[activeCommandIndex] || matchingCommands[0])
      return
    }

    if (commandPaletteOpen && event.key === "ArrowDown") {
      event.preventDefault()
      setActiveCommandIndex((current) => (current + 1) % matchingCommands.length)
      return
    }

    if (commandPaletteOpen && event.key === "ArrowUp") {
      event.preventDefault()
      setActiveCommandIndex((current) => (current - 1 + matchingCommands.length) % matchingCommands.length)
      return
    }

    if (commandPaletteOpen && event.key === "Escape") {
      event.preventDefault()
      setText("")
      return
    }

    if (event.key === "Tab" && !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey && text.trim().length > 0) {
      event.preventDefault()
      stash.mutate(undefined)
      return
    }

    if (!submitWithEnter || event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) return

    event.preventDefault()
    submitMessage()
  }

  function completeSlashCommand(command: SlashCommand) {
    const leadingWhitespace = text.match(/^\s*/)?.[0] || ""
    setText(`${leadingWhitespace}${command.name} `)
    setPendingConfirmation(null)
  }

  function updateText(nextText: string) {
    setText(nextText)
    if (pendingConfirmation && nextText.trim() !== pendingConfirmation.text) {
      setPendingConfirmation(null)
    }
  }

  useEffect(() => {
    setActiveCommandIndex(0)
  }, [commandQuery])

  useEffect(() => {
    if (activeCommandIndex >= matchingCommands.length) setActiveCommandIndex(0)
  }, [activeCommandIndex, matchingCommands.length])

  useEffect(() => {
    setJumpIndex(0)
  }, [pendingProposals.length])

  useEffect(() => {
    if (autoFocus) textareaRef.current?.focus()
  }, [autoFocus, payload.chat.id])

  // An Escape-dismissed suggestion stays dismissed for this chat view
  // only; switching chats starts fresh.
  useEffect(() => {
    setDismissedSuggestion(null)
  }, [payload.chat.id])

  // Track when the current suggestion arrived so Tab interception can
  // ignore suggestions younger than the grace period (see handleKeyDown).
  useEffect(() => {
    if (suggestedNextStep) suggestionShownAtRef.current = Date.now()
  }, [suggestedNextStep])

  useEffect(() => {
    const textarea = textareaRef.current
    if (!textarea) return

    autosizeChatTextarea(textarea)
  }, [text])

  useEffect(() => {
    function handleResize() {
      const textarea = textareaRef.current
      if (textarea) autosizeChatTextarea(textarea)
    }

    window.addEventListener("resize", handleResize)
    return () => window.removeEventListener("resize", handleResize)
  }, [])

  useEffect(() => {
    if (!attachmentPopoverOpen) return

    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node | null
      if (!target) return
      if (attachmentPopoverRef.current?.contains(target)) return
      if (addAttachmentButtonRef.current?.contains(target)) return

      setAttachmentPopoverOpen(false)
    }

    document.addEventListener("pointerdown", handlePointerDown)
    return () => document.removeEventListener("pointerdown", handlePointerDown)
  }, [attachmentPopoverOpen])

  useEffect(() => {
    if (!attachmentPopoverOpen) return

    const firstControl =
      attachmentPopoverRef.current?.querySelector<HTMLElement>("[data-autofocus]") ||
      attachmentPopoverRef.current?.querySelector<HTMLElement>("button:not(:disabled), input:not(:disabled), select:not(:disabled)")
    firstControl?.focus()
  }, [attachmentPopoverOpen])

  return (
    <>
      {pendingProposals.length > 0 ? (
        <div className="flex items-center justify-between rounded border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300">
          <span>
            {pendingProposals.length === 1
              ? "1 pending proposal"
              : `${pendingProposals.length} pending proposals`}
          </span>
          <button
            className="font-medium underline hover:no-underline"
            onClick={jumpToPending}
            type="button"
          >
            {pendingProposals.length > 1 ? `Jump (${(jumpIndex % pendingProposals.length) + 1} of ${pendingProposals.length})` : "Jump ↑"}
          </button>
        </div>
      ) : null}
      {recorder.state.phase === "recording" && nativeRecorderHud && annotationIdleKind === "accessibility" ? (
        // The floating native HUD only fits the terse hint; the actionable
        // System Settings guidance renders here in the page — the ONLY way a
        // desktop user (always on the native HUD) ever sees it.
        <div className="rounded border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300" data-testid="walkthrough-annotate-accessibility-note">
          {t("walkthrough_annotate_accessibility_note")}
        </div>
      ) : null}
      {recorder.state.phase === "recording" && !nativeRecorderHud ? (
        <WalkthroughRecorderHUD
          annotation={
            recorder.annotationAvailable
              ? {
                  // Mode-aware: HOLD reads "Hold ⌃ to draw", TAP reads "⌘⇧A to
                  // draw"; both swap to the drawing variant while the pen is
                  // armed.
                  hint: annotationHintIdle,
                  drawingHint: annotationHintDrawing,
                  drawing: recorder.drawing,
                  surfaceNote: shouldShowAnnotationSurfaceNote(recorder.annotationAvailable, recorder.displaySurface)
                    ? t("walkthrough_annotate_surface_note")
                    : undefined,
                  // In-page guidance for the no-accessibility degrade: name the
                  // System Settings pane that brings hold-to-draw back.
                  accessibilityNote:
                    annotationIdleKind === "accessibility" ? t("walkthrough_annotate_accessibility_note") : undefined
                }
              : undefined
          }
          elapsed={recorder.elapsed}
          labels={{
            recording: t("walkthrough_recording"),
            noMic: t("walkthrough_no_mic"),
            stop: t("walkthrough_stop"),
            discard: t("walkthrough_discard"),
            windowHint: t("walkthrough_window_hint"),
            remaining: (clock) => t("walkthrough_remaining", { clock })
          }}
          micLive={recorder.state.micLive}
          onDiscard={() => recorder.stop({ discard: true })}
          onStop={() => recorder.stop()}
        />
      ) : null}
      {geminiSheetOpen ? (
        <GeminiSetupSheet
          labels={{
            title: t("gemini_setup_title"),
            intro: t("gemini_setup_intro"),
            getKey: t("gemini_setup_get_key"),
            keyPlaceholder: t("gemini_setup_placeholder"),
            validateAndSave: t("gemini_setup_save"),
            validating: t("gemini_setup_validating"),
            stageFormat: t("gemini_stage_format"),
            stageReach: t("gemini_stage_reach"),
            stageVideo: t("gemini_stage_video"),
            saved: t("gemini_setup_saved"),
            keyHelp: t("gemini_setup_key_help")
          }}
          onClose={() => setGeminiSheetOpen(false)}
          onConfigured={() => {
            setGeminiSheetOpen(false)
            void queryClient.invalidateQueries({ queryKey })
            const pending = pendingVideoRef.current
            pendingVideoRef.current = null
            // assumeConfigured: the key was just saved, but this render's
            // payload.gemini_configured is still stale until the refetch
            // lands — without it, intake would re-open the sheet forever.
            if (pending) void intakeWalkthroughVideo(pending, { assumeConfigured: true })
          }}
        />
      ) : null}
      {reportDialogOpen ? (
        <ReportIssueDialog
          body={reportIssueBody(payload, prefix)}
          onClose={() => setReportDialogOpen(false)}
          onFiled={(issueUrl) => {
            onNotice(`Issue filed — ${issueUrl}`)
            setReportDialogOpen(false)
          }}
        />
      ) : null}
      <form
        className={`relative rounded border border-gray-200 bg-white p-3 transition-shadow dark:border-gray-700 dark:bg-gray-900 ${isDragOver ? "ring-2 ring-blue-400 dark:ring-blue-500" : ""}`}
        onDragEnter={handleDragEnter}
        onDragLeave={handleDragLeave}
        onDragOver={handleDragOver}
        onDrop={handleDrop}
        onSubmit={submit}
      >
        {send.isError ? <div className="mb-2 text-sm text-red-700 dark:text-red-300">{errorMessage(send.error, "Message failed.")}</div> : null}
        {systemAction.isError ? <div className="mb-2 text-sm text-red-700 dark:text-red-300">{errorMessage(systemAction.error, "Command failed.")}</div> : null}
        {attachmentError ? <div className="mb-2 text-sm text-red-700 dark:text-red-300">{attachmentError}</div> : null}
        {clearConfirmationOpen ? (
          <div className="mb-2 flex flex-wrap items-center justify-between gap-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
            <span>{t("clear_confirm")}</span>
            <span className="flex gap-2">
              <button className={secondaryButton()} disabled={systemAction.isPending} onClick={() => systemAction.mutate({ kind: "clear" })} type="button">{t("clear")}</button>
              <button className={secondaryButton()} disabled={systemAction.isPending} onClick={() => setClearConfirmationOpen(false)} type="button">{t("cancel")}</button>
            </span>
          </div>
        ) : null}
        {queuedMessages.length > 0 ? <QueuedMessages chatId={chatId} messages={queuedMessages} queryKey={queryKey} /> : null}
        <ScratchpadPanel
          chatId={chatId}
          enqueuePath={payload.paths.app_enqueue_message_path}
          items={payload.scratchpad_items || []}
          open={scratchpadOpen || (agentActive && (payload.scratchpad_items || []).length > 0)}
          queryKey={queryKey}
          reorderPath={payload.paths.app_scratchpad_reorder_path}
          text={text}
          onDismiss={() => setScratchpadOpen(false)}
          onLoadToInput={updateText}
        />
        {pendingConfirmation ? (
          <SlashCommandConfirmation
            commandName={pendingConfirmation.commandName}
            disabled={send.isPending || systemCommandAction.isPending}
            text={pendingConfirmation.text}
            onCancel={cancelPendingSlashCommand}
            onConfirm={confirmPendingSlashCommand}
          />
        ) : null}
        {commandPaletteOpen ? (
          <SlashCommandPalette
            activeIndex={activeCommandIndex}
            commands={matchingCommands}
            context={{ chat: { pinned: payload.chat.pinned } }}
            query={commandQuery}
            onSelect={(command) => completeSlashCommand(command)}
          />
        ) : null}
        {attachments.length > 0 ? (
          <div className="mb-3 flex flex-wrap gap-2">
            {attachments.map((attachment, index) => (
              <div className="flex max-w-full items-center gap-2 rounded border border-gray-200 bg-gray-50 px-2 py-1 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={`${attachment.name}-${index}`}>
                {attachment.mimeType.startsWith("image/") ? (
                  <>
                    <button aria-label={`Annotate ${attachment.name}`} className="group relative rounded focus:outline-none focus:ring-2 focus:ring-blue-500" onClick={() => setAnnotatingIndex(index)} type="button">
                      <img alt="" className="h-8 w-8 rounded object-cover" src={attachment.dataUrl} />
                      <span aria-hidden="true" className="absolute inset-0 flex items-center justify-center rounded bg-black/55 text-white opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100">
                        <PencilIcon className="h-4 w-4" />
                      </span>
                    </button>
                    {annotatingIndex === index ? (
                      <ImageAnnotationModal
                        dataUrl={attachment.dataUrl}
                        name={attachment.name}
                        onClose={() => setAnnotatingIndex(null)}
                        onDone={(annotatedDataUrl) => {
                          setAttachments((current) => current.map((item, attachmentIndex) => attachmentIndex === index ? { ...item, dataUrl: annotatedDataUrl, mimeType: "image/png" } : item))
                          setAnnotatingIndex(null)
                        }}
                      />
                    ) : null}
                  </>
                ) : (
                  <span aria-hidden="true" className="flex h-8 w-8 items-center justify-center rounded border border-gray-200 bg-white text-xs font-semibold text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">PDF</span>
                )}
                <span className="max-w-48 truncate" title={attachment.name}>{attachment.name}</span>
                <button aria-label={`Remove ${attachment.name}`} className="rounded p-1 text-gray-500 hover:bg-gray-200 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-gray-100" onClick={() => removeAttachment(index)} type="button">
                  <CloseIcon className="h-3.5 w-3.5" />
                </button>
              </div>
            ))}
          </div>
        ) : null}
      {walkthrough ? (
        <div className="mb-3 flex w-full items-center gap-3 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900" data-testid="walkthrough-chip">
          <span aria-hidden="true" className="text-base">🎬</span>
          <span className="min-w-0 flex-1 truncate text-gray-800 dark:text-gray-200">
            {walkthrough.filename}
            {walkthrough.durationSeconds ? <span className="ml-1 text-xs text-gray-500">({formatClock(walkthrough.durationSeconds)})</span> : null}
          </span>
          {walkthrough.status === "ready" ? <span className="text-xs text-gray-500">{t("walkthrough_ready")}</span> : null}
          {walkthrough.status === "uploading" ? (
            <span className="flex items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
              {t("walkthrough_uploading", { percent: walkthrough.percent })}
              <span className="h-1.5 w-24 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700">
                <span className="block h-full rounded-full bg-terracotta-600 transition-all" style={{ width: `${walkthrough.percent}%` }} />
              </span>
            </span>
          ) : null}
          {walkthrough.status === "analyzing" ? (
            <span className="flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300">
              <span className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-terracotta-500 border-t-transparent" />
              <AnalyzingHint messages={walkthroughAnalyzingHints} />
            </span>
          ) : null}
          {walkthrough.status === "failed" ? (
            <span className="flex items-center gap-2 text-xs text-red-700 dark:text-red-300">
              <span className="max-w-64 truncate" title={walkthrough.error}>{walkthrough.error}</span>
              {walkthrough.id ? (
                <button className="font-medium underline hover:no-underline" onClick={retryWalkthroughAnalysis} type="button">
                  {t("walkthrough_retry")}
                </button>
              ) : null}
            </span>
          ) : null}
          {walkthrough.status === "ready" || walkthrough.status === "failed" ? (
            <button
              aria-label={t("walkthrough_remove")}
              className="rounded-full p-0.5 text-gray-400 hover:bg-gray-200 hover:text-gray-600 dark:hover:bg-gray-700"
              onClick={() => {
                setWalkthrough(null)
                // Clear any walkthrough-scoped error (e.g. one-at-a-time) so
                // it can't linger and disable the send button for the next
                // ordinary message.
                setAttachmentError(null)
              }}
              type="button"
            >
              <CloseIcon className="h-3.5 w-3.5" />
            </button>
          ) : null}
        </div>
      ) : null}
      {showAttachedRepositories && attachedRepositories.length > 0 ? (
        <div className="mb-3 flex w-full flex-wrap gap-2">
          {attachedRepositories.map((repository) => (
            <span className="flex h-9 max-w-full items-center gap-1 rounded-full border border-blue-200 bg-blue-50 px-2.5 text-sm text-blue-800 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-200" key={repository.id}>
              <span className="truncate" title={repository.label}>{repository.label}</span>
              <button
                aria-label={`Detach repository ${repository.label}`}
                className="rounded-full p-0.5 text-blue-600 hover:bg-blue-100 hover:text-blue-900 disabled:text-blue-300 dark:text-blue-300 dark:hover:bg-blue-900 dark:hover:text-blue-100 dark:disabled:text-blue-700"
                disabled={detachRepository.isPending}
                onClick={() => detachRepository.mutate(repository.app_detach_path)}
                title={`Detach repository ${repository.label}`}
                type="button"
              >
                <CloseIcon className="h-3.5 w-3.5" />
              </button>
            </span>
          ))}
        </div>
      ) : null}
      <div className="flex items-end justify-between gap-3">
        <input
          accept={payload.walkthroughs_enabled ? "image/*,application/pdf,video/webm,video/mp4,video/quicktime" : "image/*,application/pdf"}
          aria-label={t("chat_attachments")}
          className="hidden"
          disabled={send.isPending || systemAction.isPending}
          multiple
          onChange={(event) => handleAttachmentChange(event.target.files)}
          ref={fileInputRef}
          type="file"
        />
        <button
          aria-controls={attachmentPopoverOpen ? "chat-attachment-popover" : undefined}
          aria-expanded={attachmentPopoverOpen}
          aria-label={t("add_attachment")}
          aria-haspopup="dialog"
          className="flex h-9 w-9 shrink-0 items-center justify-center rounded border border-gray-300 bg-white text-xl leading-none text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
          disabled={send.isPending || systemAction.isPending}
          onClick={() => setAttachmentPopoverOpen((open) => !open)}
          ref={addAttachmentButtonRef}
          type="button"
        >
          +
        </button>
        {attachmentPopoverOpen ? (
          <div
            aria-label={t("add_attachment")}
            className="absolute bottom-[4.25rem] left-3 z-20 w-[min(22rem,calc(100%-1.5rem))] overflow-hidden rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950"
            id="chat-attachment-popover"
            onKeyDown={handleAttachmentPopoverKeyDown}
            ref={attachmentPopoverRef}
            role="dialog"
          >
            <button
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
              onClick={openAttachmentFilePicker}
              type="button"
            >
              <UploadIcon className="h-4 w-4 shrink-0 text-gray-400" />
              {t("upload_file")}
            </button>
            {payload.walkthroughs_enabled ? (
              <button
                className="flex w-full items-start gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
                onClick={startWalkthroughRecording}
                title={t("record_walkthrough_title")}
                type="button"
              >
                <span aria-hidden="true" className="mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center">
                  <span className="h-2.5 w-2.5 rounded-full border-2 border-red-500" />
                </span>
                <span className="min-w-0">
                  <span className="block">{t("record_walkthrough")}</span>
                  <span className="mt-0.5 block text-xs text-gray-500 dark:text-gray-400">{t("record_walkthrough_hint")}</span>
                </span>
              </button>
            ) : null}
            <div className="border-t border-gray-100 dark:border-gray-800" />
            <button
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
              onClick={() => {
                setAttachmentPopoverOpen(false)
                setScratchpadOpen((prev) => !prev)
              }}
              type="button"
            >
              <svg aria-hidden="true" className="h-4 w-4 shrink-0 text-gray-400" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
                <rect height="4" rx="1" width="6" x="9" y="3" />
                <path d="M9 12h6M9 16h4" />
              </svg>
              {t("scratchpad_title")}
            </button>
            <div className="border-t border-gray-100 dark:border-gray-800" />
            <AddAttachment payload={payload} prefix={prefix} queryKey={queryKey} onAttached={() => setAttachmentPopoverOpen(false)} onNotice={onNotice} />
          </div>
        ) : null}
        <div className="relative min-w-0 flex-1">
          <textarea
            aria-controls={commandPaletteOpen ? "chat-slash-command-palette" : undefined}
            aria-expanded={commandPaletteOpen}
            aria-haspopup="listbox"
            className="min-h-9 w-full resize-none overflow-y-hidden rounded border border-gray-300 py-2 pl-3 pr-8 text-base leading-6 focus:border-blue-500 focus:ring-blue-500 disabled:bg-gray-50 sm:text-sm sm:leading-5 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500 dark:disabled:bg-gray-800"
            disabled={send.isPending || systemAction.isPending}
            onChange={(event) => {
              updateText(event.target.value)
              if (clearConfirmationOpen) setClearConfirmationOpen(false)
            }}
            onKeyDown={handleKeyDown}
            onPaste={handlePaste}
            placeholder={ghostSuggestion ? "" : payload.switching_provider ? t("switching_to_provider", { provider: providerLabel(payload.chat.chat_provider ?? "") }) : agentActive ? t("queue_followup") : payload.chat.repository ? t("ask_repository") : t("ask_anything")}
            ref={textareaRef}
            required={attachments.length === 0 && walkthrough?.status !== "ready"}
            rows={1}
            value={text}
          />
          {ghostSuggestion ? (
            <div aria-hidden="true" className="pointer-events-none absolute inset-y-0 left-0 right-0 flex items-center gap-2 overflow-hidden px-3 py-2 text-base leading-6 sm:text-sm sm:leading-5" data-testid="chat-suggestion-ghost">
              <span className="truncate text-gray-400 dark:text-gray-500">{ghostSuggestion}</span>
              <span className="inline-flex shrink-0 items-center rounded border border-gray-300 bg-gray-50 px-1 text-[10px] font-medium text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-500">⇥ {t("suggestion_tab_hint")}</span>
            </div>
          ) : null}
          {!agentActive && text.trim().length > 0 ? (
            <button
              aria-label={t("scratchpad_stash")}
              className="absolute right-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded text-gray-400 hover:bg-gray-100 hover:text-gray-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-gray-300 dark:disabled:text-gray-600"
              disabled={stash.isPending}
              onClick={() => stash.mutate(undefined)}
              title={t("scratchpad_stash_tab")}
              type="button"
            >
              ^
            </button>
          ) : null}
          <span aria-live="polite" className="sr-only">{ghostSuggestion ? t("suggestion_available", { suggestion: ghostSuggestion }) : ""}</span>
        </div>
        <div className="flex items-center gap-2">
          <button aria-label={agentActive ? t("enqueue_message") : t("send_message")} className={`${primaryButton()} inline-flex items-center justify-center`} disabled={send.isPending || systemAction.isPending || systemCommandAction.isPending || (text.trim().length === 0 && walkthrough?.status !== "ready" && attachments.length === 0) || pendingConfirmation != null || attachmentError != null} type="submit">
            {agentActive ? <EnqueueIcon className="h-4 w-4" /> : <SendIcon className="h-4 w-4" />}
          </button>
          {agentActive && text.trim().length > 0 ? (
            <button
              aria-label={t("scratchpad_stash")}
              className="inline-flex h-9 items-center justify-center rounded border border-gray-300 bg-white px-2.5 text-gray-600 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
              disabled={stash.isPending}
              onClick={() => stash.mutate(undefined)}
              title={t("scratchpad_stash")}
              type="button"
            >
              <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
                <rect height="4" rx="1" width="6" x="9" y="3" />
                <path d="M9 12h6M9 16h4" />
              </svg>
            </button>
          ) : null}
          {agentActive && !payload.switching_provider ? <StopButton payload={payload} queryKey={queryKey} /> : null}
        </div>
      </div>
      </form>
    </>
  )
}

function ReportIssueDialog({ body, onClose, onFiled }: { body: string; onClose: () => void; onFiled: (issueUrl: string) => void }) {
  const [title, setTitle] = useState("")
  const [issueBody, setIssueBody] = useState(body)
  const report = useMutation({
    mutationFn: () => createReportIssue({ title, body: issueBody }),
    onSuccess: (result) => onFiled(result.issue_url)
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (title.trim().length === 0 || report.isPending) return

    report.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" role="presentation">
      <form aria-label="File a GitHub issue about Syrus" aria-modal="true" className="w-full max-w-lg rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-950" onSubmit={submit} role="dialog">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">File a GitHub issue</h2>
          </div>
          <button aria-label="Close report dialog" className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100" disabled={report.isPending} onClick={onClose} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <label className="mt-4 block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="report-issue-title">Title</label>
        <input
          autoFocus
          className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          disabled={report.isPending}
          id="report-issue-title"
          onChange={(event) => setTitle(event.target.value)}
          required
          type="text"
          value={title}
        />
        <label className="mt-3 block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="report-issue-body">Body</label>
        <textarea
          className="mt-1 h-40 w-full resize-y rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          disabled={report.isPending}
          id="report-issue-body"
          onChange={(event) => setIssueBody(event.target.value)}
          value={issueBody}
        />
        {report.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(report.error, "Issue could not be filed.")}</p> : null}
        <div className="mt-4 flex justify-end gap-2">
          <button className={secondaryButton()} disabled={report.isPending} onClick={onClose} type="button">Cancel</button>
          <button className={primaryButton()} disabled={report.isPending || title.trim().length === 0} type="submit">Submit</button>
        </div>
      </form>
    </div>
  )
}

function reportIssueBody(payload: ChatPayload, prefix: string) {
  const path = withRoutePrefix(payload.chat.chat_path, prefix)
  const url = typeof window === "undefined" ? path : new URL(path, window.location.origin).toString()

  return `Context:\n- Chat: ${chatDisplayTitle(payload.chat)}\n- URL: ${url}\n\n`
}

function readAttachmentFile(file: File): Promise<ChatComposeAttachment> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      resolve({
        name: file.name,
        mimeType: file.type || "application/octet-stream",
        dataUrl: String(reader.result || ""),
        size: file.size
      })
    }
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

function SlashCommandConfirmation({ commandName, disabled, text, onCancel, onConfirm }: { commandName: SlashCommand["name"]; disabled: boolean; text: string; onCancel: () => void; onConfirm: () => void }) {
  return (
    <div className="mb-3 rounded border border-amber-200 bg-amber-50 p-3 dark:border-amber-900 dark:bg-amber-950/40">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-300">Confirm {commandName}</div>
          <div className="mt-1 break-words font-mono text-sm text-gray-900 dark:text-gray-100">{text}</div>
        </div>
        <div className="flex shrink-0 gap-2">
          <button className={secondaryButton()} disabled={disabled} onClick={onCancel} type="button">Cancel</button>
          <button className={primaryButton()} disabled={disabled} onClick={onConfirm} type="button">Confirm</button>
        </div>
      </div>
    </div>
  )
}

function SlashCommandPalette({ activeIndex, commands, context, query, onSelect }: { activeIndex: number; commands: SlashCommand[]; context: { chat: { pinned?: boolean } }; query: string; onSelect: (command: SlashCommand) => void }) {
  return (
    <div
      aria-label="Slash commands"
      className="absolute bottom-full left-3 right-3 z-10 mb-2 max-h-[calc(var(--chat-visual-viewport-height,100dvh)-9rem)] overflow-y-auto rounded border border-gray-200 bg-white shadow-lg overscroll-contain dark:border-gray-700 dark:bg-gray-950"
      id="chat-slash-command-palette"
      role="listbox"
    >
      {commands.map((command, index) => {
        const signature = slashCommandSignature(command)
        const active = index === activeIndex

        return (
          <button
            aria-selected={active}
            className={`flex w-full items-start gap-3 px-3 py-2 text-left text-sm ${active ? "bg-blue-50 dark:bg-blue-950" : "hover:bg-gray-50 dark:hover:bg-gray-900"}`}
            key={command.name}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => onSelect(command)}
            role="option"
            type="button"
          >
            <span className="min-w-0 flex-1">
              <span className="flex flex-wrap items-baseline gap-x-2">
                <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{highlightSlashCommand(command.name, query)}</span>
                {signature.length > 0 ? <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{signature}</span> : null}
              </span>
              <span className="mt-0.5 block text-xs text-gray-500 dark:text-gray-400">{slashCommandDescription(command, context)}</span>
            </span>
            <span className={`shrink-0 rounded px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase ${command.kind === "system" ? "bg-cyan-50 text-cyan-700 dark:bg-cyan-950 dark:text-cyan-200" : "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-200"}`}>{command.kind}</span>
          </button>
        )
      })}
    </div>
  )
}

function highlightSlashCommand(name: string, query: string) {
  if (query.length === 0) return name

  const start = name.slice(1).toLowerCase().indexOf(query)
  if (start < 0) return name

  const from = start + 1
  const to = from + query.length
  return (
    <>
      {name.slice(0, from)}
      <mark className="bg-yellow-200 px-0 dark:bg-yellow-700 dark:text-gray-950">{name.slice(from, to)}</mark>
      {name.slice(to)}
    </>
  )
}

function QueuedMessages({ chatId, messages, queryKey }: { chatId: string; messages: ChatQueuedMessage[]; queryKey: ChatQueryKey }) {
  return (
    <div className="mb-3 space-y-2 border-b border-gray-100 pb-3 dark:border-gray-800">
      <div className="text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">Queued messages</div>
      {messages.map((message, index) => <QueuedMessageRow chatId={chatId} key={message.id} message={message} position={index + 1} queryKey={queryKey} />)}
    </div>
  )
}

function QueuedMessageRow({ chatId, message, position, queryKey }: { chatId: string; message: ChatQueuedMessage; position: number; queryKey: ChatQueryKey }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(message.text)
  const update = useMutation({
    mutationFn: () => updateQueuedChatMessage(appendSearch(message.app_update_path, search), draft),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setEditing(false)
    }
  })
  const remove = useMutation({
    mutationFn: () => deleteQueuedChatMessage(appendSearch(message.app_delete_path, search)),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })
  const stash = useMutation({
    mutationFn: async () => {
      const afterCreate = await createScratchpadItem(chatId, message.text)
      queryClient.setQueryData(queryKey, afterCreate)
      return deleteQueuedChatMessage(appendSearch(message.app_delete_path, search))
    },
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  useEffect(() => {
    if (!editing) setDraft(message.text)
  }, [editing, message.text])

  if (editing) {
    return (
      <div className="rounded border border-blue-200 bg-blue-50 p-2 dark:border-blue-800 dark:bg-blue-950">
        {update.isError ? <div className="mb-2 text-xs text-red-700 dark:text-red-300">{errorMessage(update.error, "Queued message could not be updated.")}</div> : null}
        <textarea
          aria-label={`Edit queued message ${position}`}
          className="min-h-16 w-full resize-y rounded border border-blue-200 bg-white px-2 py-1.5 text-sm focus:border-blue-500 focus:ring-blue-500 dark:border-blue-800 dark:bg-gray-950 dark:text-gray-100"
          onChange={(event) => setDraft(event.target.value)}
          value={draft}
        />
        <div className="mt-2 flex justify-end gap-2">
          <button className="rounded border border-gray-300 bg-white px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" disabled={update.isPending} onClick={() => setEditing(false)} type="button">Cancel</button>
          <button className="rounded bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:bg-blue-300 dark:hover:bg-blue-500 dark:disabled:bg-gray-700" disabled={update.isPending || draft.trim().length === 0} onClick={() => update.mutate()} type="button">Save</button>
        </div>
      </div>
    )
  }

  return (
    <div>
      <div className="flex items-start gap-2 rounded border border-gray-200 bg-gray-50 px-2 py-1.5 dark:border-gray-700 dark:bg-gray-800">
        <span className="mt-0.5 shrink-0 text-xs font-medium text-gray-500 dark:text-gray-400">{position}</span>
        <button className="min-w-0 flex-1 text-left text-sm text-gray-700 hover:text-blue-700 dark:text-gray-200 dark:hover:text-blue-300" onClick={() => setEditing(true)} type="button">
          <span className="line-clamp-2 whitespace-pre-wrap break-words">{message.text}</span>
        </button>
        <button
          aria-label={t("scratchpad_stash")}
          className="rounded p-1 text-gray-400 hover:bg-white hover:text-blue-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-blue-300 dark:disabled:text-gray-700"
          disabled={stash.isPending || remove.isPending}
          onClick={() => stash.mutate()}
          title={t("scratchpad_stash")}
          type="button"
        >
          <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
            <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
            <rect height="4" rx="1" width="6" x="9" y="3" />
            <path d="M9 12h6M9 16h4" />
          </svg>
        </button>
        <button
          aria-label={`Delete queued message ${position}`}
          className="rounded p-1 text-gray-400 hover:bg-white hover:text-red-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-red-300 dark:disabled:text-gray-700"
          disabled={remove.isPending || stash.isPending}
          onClick={() => remove.mutate()}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
      </div>
      {stash.isError ? <div className="mt-0.5 text-xs text-red-700 dark:text-red-300">{errorMessage(stash.error, "Could not move to scratch pad.")}</div> : null}
    </div>
  )
}

function ScratchpadPanel({
  chatId,
  enqueuePath,
  items,
  open,
  queryKey,
  reorderPath,
  text,
  onDismiss,
  onLoadToInput
}: {
  chatId: string
  enqueuePath: string
  items: ChatScratchpadItem[]
  open?: boolean
  queryKey: ChatQueryKey
  reorderPath: string
  text: string
  onDismiss?: () => void
  onLoadToInput: (content: string) => void
}) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [collapsed, setCollapsed] = useState(false)
  const [addFocused, setAddFocused] = useState(false)
  const [addDraft, setAddDraft] = useState("")
  const [dragIndex, setDragIndex] = useState<number | null>(null)
  const [dropIndex, setDropIndex] = useState<number | null>(null)
  const [dismissed, setDismissed] = useState(false)
  const addInputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (open) setDismissed(false)
  }, [open])

  const create = useMutation({
    mutationFn: () => createScratchpadItem(chatId, addDraft),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setAddDraft("")
      setTimeout(() => addInputRef.current?.focus(), 0)
    }
  })

  const reorder = useMutation({
    mutationFn: (ids: number[]) => reorderScratchpadItems(chatId, ids),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  function handleDragStart(index: number) {
    setDragIndex(index)
    setDropIndex(index)
  }

  function handleDragOver(e: DragEvent<HTMLDivElement>, index: number) {
    e.preventDefault()
    setDropIndex(index)
  }

  function handleDrop(index: number) {
    if (dragIndex === null || dragIndex === index) {
      setDragIndex(null)
      setDropIndex(null)
      return
    }
    const newIds = items.map((i) => i.id)
    const [draggedId] = newIds.splice(dragIndex, 1)
    newIds.splice(index, 0, draggedId)
    reorder.mutate(newIds)
    setDragIndex(null)
    setDropIndex(null)
  }

  function handleDragEnd() {
    setDragIndex(null)
    setDropIndex(null)
  }

  function submitAdd() {
    if (addDraft.trim().length === 0 || create.isPending) return
    create.mutate()
  }

  const visible = !dismissed && ((open ?? false) || items.length > 0 || addFocused)
  if (!visible) return null

  return (
    <div className="mb-3 border-b border-gray-100 pb-3 dark:border-gray-800">
      <div className="flex items-center gap-1">
        <button
          className="flex flex-1 items-center gap-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400"
          onClick={() => setCollapsed((c) => !c)}
          type="button"
        >
          {t("scratchpad_title")}
          {items.length > 0 && (
            <span className="rounded-full bg-gray-200 px-1.5 py-0.5 text-xs font-semibold leading-none text-gray-600 dark:bg-gray-700 dark:text-gray-300">
              {items.length}
            </span>
          )}
          <svg
            aria-hidden="true"
            className={`ml-auto h-3.5 w-3.5 transition-transform ${collapsed ? "rotate-90" : "-rotate-90"}`}
            fill="none"
            stroke="currentColor"
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth="2"
            viewBox="0 0 24 24"
          >
            <path d="m9 18 6-6-6-6" />
          </svg>
        </button>
        <button
          aria-label={t("scratchpad_dismiss")}
          className="rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-600 dark:hover:bg-gray-800 dark:hover:text-gray-300"
          onClick={() => { setDismissed(true); onDismiss?.() }}
          type="button"
        >
          <CloseIcon className="h-3.5 w-3.5" />
        </button>
      </div>

      {!collapsed && (
        <>
          {items.length > 0 && (
            <div className="mt-2 space-y-1">
              {items.map((item, index) => (
                <ScratchpadItemRow
                  chatId={chatId}
                  dragTarget={dropIndex === index && dragIndex !== null && dragIndex !== index}
                  enqueuePath={enqueuePath}
                  index={index}
                  isDragging={dragIndex === index}
                  item={item}
                  key={item.id}
                  queryKey={queryKey}
                  text={text}
                  onDragEnd={handleDragEnd}
                  onDragOver={(e) => handleDragOver(e, index)}
                  onDragStart={() => handleDragStart(index)}
                  onDrop={() => handleDrop(index)}
                  onLoadToInput={onLoadToInput}
                />
              ))}
            </div>
          )}

          <div className="mt-2 flex gap-2">
            <input
              ref={addInputRef}
              aria-label={t("scratchpad_add_placeholder")}
              className="min-h-8 flex-1 rounded border border-gray-200 px-2 py-1.5 text-xs placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-600 dark:disabled:bg-gray-800"
              disabled={create.isPending}
              onBlur={() => setAddFocused(false)}
              onChange={(e) => setAddDraft(e.target.value)}
              onFocus={() => setAddFocused(true)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault()
                  submitAdd()
                }
              }}
              placeholder={t("scratchpad_add_placeholder")}
              value={addDraft}
            />
            <button
              className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-700"
              disabled={create.isPending || addDraft.trim().length === 0}
              onClick={submitAdd}
              type="button"
            >
              {t("scratchpad_add")}
            </button>
          </div>
          {create.isError ? (
            <p className="mt-1 text-xs text-red-600 dark:text-red-400" role="alert">
              {errorMessage(create.error, "Could not add item.")}
            </p>
          ) : null}
        </>
      )}
    </div>
  )
}

function ScratchpadItemRow({
  chatId,
  dragTarget,
  enqueuePath,
  isDragging,
  item,
  queryKey,
  text,
  onDragEnd,
  onDragOver,
  onDragStart,
  onDrop,
  onLoadToInput
}: {
  chatId: string
  dragTarget: boolean
  enqueuePath: string
  index: number
  isDragging: boolean
  item: ChatScratchpadItem
  queryKey: ChatQueryKey
  text: string
  onDragEnd: () => void
  onDragOver: (e: DragEvent<HTMLDivElement>) => void
  onDragStart: () => void
  onDrop: () => void
  onLoadToInput: (content: string) => void
}) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(item.content)
  const [loadPending, setLoadPending] = useState(false)
  const [loadError, setLoadError] = useState<string | null>(null)

  const update = useMutation({
    mutationFn: () => updateScratchpadItem(item.app_update_path, draft),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setEditing(false)
    }
  })

  const remove = useMutation({
    mutationFn: () => deleteScratchpadItem(item.app_delete_path),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  const queue = useMutation({
    mutationFn: async () => {
      const afterEnqueue = await enqueueChatMessage(appendSearch(enqueuePath, search), item.content)
      queryClient.setQueryData(queryKey, afterEnqueue)
      return deleteScratchpadItem(item.app_delete_path)
    },
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  useEffect(() => {
    if (!editing) setDraft(item.content)
  }, [editing, item.content])

  async function handleLoad() {
    if (loadPending || remove.isPending) return
    setLoadError(null)
    setLoadPending(true)
    try {
      if (text.trim().length > 0) {
        const stashed = await createScratchpadItem(chatId, text)
        queryClient.setQueryData(queryKey, stashed)
      }
      const deleted = await deleteScratchpadItem(item.app_delete_path)
      queryClient.setQueryData(queryKey, deleted)
      onLoadToInput(item.content)
    } catch (error) {
      setLoadError(errorMessage(errorAsError(error), "Could not load item."))
    } finally {
      setLoadPending(false)
    }
  }

  if (editing) {
    return (
      <div className="rounded border border-blue-200 bg-blue-50 p-2 dark:border-blue-800 dark:bg-blue-950">
        {update.isError ? <div className="mb-2 text-xs text-red-700 dark:text-red-300">{errorMessage(update.error, "Could not update item.")}</div> : null}
        <textarea
          aria-label={t("scratchpad_edit_item")}
          className="min-h-16 w-full resize-y rounded border border-blue-200 bg-white px-2 py-1.5 text-xs focus:border-blue-500 focus:ring-blue-500 dark:border-blue-800 dark:bg-gray-950 dark:text-gray-100"
          onChange={(e) => setDraft(e.target.value)}
          value={draft}
        />
        <div className="mt-2 flex justify-end gap-2">
          <button className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" disabled={update.isPending} onClick={() => setEditing(false)} type="button">{t("scratchpad_cancel")}</button>
          <button className="rounded bg-blue-600 px-2 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:bg-blue-300 dark:hover:bg-blue-500 dark:disabled:bg-gray-700" disabled={update.isPending || draft.trim().length === 0} onClick={() => update.mutate()} type="button">{t("scratchpad_save")}</button>
        </div>
      </div>
    )
  }

  return (
    <div>
      <div
        className={`flex items-start gap-1.5 rounded border px-2 py-1.5 transition-colors ${isDragging ? "opacity-40" : ""} ${dragTarget ? "border-blue-400 bg-blue-50 dark:border-blue-600 dark:bg-blue-950" : "border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800"}`}
        draggable
        onDragEnd={onDragEnd}
        onDragOver={onDragOver}
        onDragStart={(e) => {
          e.dataTransfer.effectAllowed = "move"
          onDragStart()
        }}
        onDrop={(e) => {
          e.preventDefault()
          onDrop()
        }}
      >
        <button
          aria-label={t("scratchpad_drag_item")}
          className="mt-0.5 shrink-0 cursor-grab text-gray-300 hover:text-gray-500 active:cursor-grabbing dark:text-gray-600 dark:hover:text-gray-400"
          type="button"
        >
          <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.5" viewBox="0 0 16 16">
            <line x1="3" x2="13" y1="4" y2="4" />
            <line x1="3" x2="13" y1="8" y2="8" />
            <line x1="3" x2="13" y1="12" y2="12" />
          </svg>
        </button>

        <div className="min-w-0 flex-1">
          <button
            className={`w-full text-left text-xs transition-colors ${loadPending ? "text-gray-400 dark:text-gray-500" : "text-gray-700 hover:text-blue-700 dark:text-gray-200 dark:hover:text-blue-300"}`}
            disabled={loadPending || remove.isPending}
            onClick={() => void handleLoad()}
            title={t("scratchpad_load")}
            type="button"
          >
            <span className="line-clamp-2 whitespace-pre-wrap break-words">{item.content}</span>
          </button>
          {loadError ? <p className="mt-0.5 text-xs text-red-600 dark:text-red-400">{loadError}</p> : null}
        </div>

        <div className="flex shrink-0 items-center gap-0.5">
          <button
            aria-label={t("scratchpad_queue_item")}
            className="rounded p-0.5 text-gray-400 hover:bg-white hover:text-blue-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-blue-300 dark:disabled:text-gray-700"
            disabled={queue.isPending || update.isPending || remove.isPending}
            onClick={() => queue.mutate()}
            title={t("scratchpad_queue_item")}
            type="button"
          >
            <EnqueueIcon className="h-3.5 w-3.5" />
          </button>
          <button
            aria-label={t("scratchpad_edit_item")}
            className="rounded p-0.5 text-gray-400 hover:bg-white hover:text-gray-700 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-gray-200 dark:disabled:text-gray-700"
            disabled={update.isPending || remove.isPending || queue.isPending}
            onClick={() => setEditing(true)}
            type="button"
          >
            <PencilIcon className="h-3.5 w-3.5" />
          </button>
          <button
            aria-label={t("scratchpad_delete_item")}
            className="rounded p-0.5 text-gray-400 hover:bg-white hover:text-red-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-red-300 dark:disabled:text-gray-700"
            disabled={remove.isPending || queue.isPending}
            onClick={() => remove.mutate()}
            type="button"
          >
            <CloseIcon className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>
      {queue.isError ? <div className="mt-0.5 text-xs text-red-700 dark:text-red-300">{errorMessage(queue.error, "Could not move to queue.")}</div> : null}
    </div>
  )
}

function autosizeChatTextarea(textarea: HTMLTextAreaElement) {
  textarea.style.height = "auto"

  const style = window.getComputedStyle(textarea)
  const lineHeight = parsePixelValue(style.lineHeight) || 20
  const verticalPadding = parsePixelValue(style.paddingTop) + parsePixelValue(style.paddingBottom)
  const verticalBorder = parsePixelValue(style.borderTopWidth) + parsePixelValue(style.borderBottomWidth)
  const minHeight = lineHeight + verticalPadding + verticalBorder
  const maxHeight = (lineHeight * CHAT_COMPOSE_MAX_ROWS) + verticalPadding + verticalBorder
  const nextHeight = Math.min(Math.max(textarea.scrollHeight, minHeight), maxHeight)

  textarea.style.height = `${nextHeight}px`
  textarea.style.overflowY = textarea.scrollHeight > maxHeight ? "auto" : "hidden"
}

function parsePixelValue(value: string) {
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function useSubmitChatWithEnter() {
  const [enabled, setEnabled] = useState(isDesktopChatViewport)

  useEffect(() => {
    const update = () => setEnabled(isDesktopChatViewport())
    update()
    window.addEventListener("resize", update)
    return () => window.removeEventListener("resize", update)
  }, [])

  return enabled
}

function isDesktopChatViewport() {
  return typeof window !== "undefined" && window.innerWidth >= CHAT_ENTER_SUBMIT_MIN_WIDTH
}

function useMediaQuery(query: string, defaultMatches: boolean) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches

    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const updateMatches = () => setMatches(media.matches)
    updateMatches()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", updateMatches)
      return () => media.removeEventListener("change", updateMatches)
    }

    media.addListener(updateMatches)
    return () => media.removeListener(updateMatches)
  }, [query])

  return matches
}

function StopButton({ payload, queryKey }: { payload: ChatPayload; queryKey: ChatQueryKey }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const stop = useMutation({
    mutationFn: () => stopChat(appendSearch(payload.paths.app_stop_path, search)),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })
  return (
    <button aria-label="Stop agent" className="inline-flex h-9 items-center justify-center rounded border border-red-200 bg-white px-3 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-400 dark:border-red-800 dark:bg-gray-900 dark:text-red-300 dark:hover:bg-red-950 dark:disabled:text-gray-600" disabled={Boolean(payload.chat.stop_requested_at) || stop.isPending} onClick={() => stop.mutate()} type="button">
      <StopIcon className={`h-4 w-4 ${payload.chat.stop_requested_at || stop.isPending ? "opacity-50" : ""}`} />
    </button>
  )
}

type WorkspaceTab = "whiteboard" | "context" | "media" | "files" | "diff" | "jobs"
type MobileChatTab = "chat" | WorkspaceTab

function ChatWorkspace({
  chatId,
  payload,
  prefix,
  queryKey,
  onNotice,
  whiteboardFullscreen,
  onWhiteboardFullscreenChange,
  settingsOpen,
  onSettingsOpenChange
}: {
  chatId: string
  payload: ChatPayload
  prefix: string
  queryKey: ChatQueryKey
  onNotice: (message: string | null) => void
  whiteboardFullscreen: boolean
  onWhiteboardFullscreenChange: (fullscreen: boolean) => void
  settingsOpen: boolean
  onSettingsOpenChange: (open: boolean) => void
}) {
  const [activeTab, setActiveTab] = useState<WorkspaceTab>(() => storedWorkspaceTab() || defaultWorkspaceTab(payload))
  const [activeMobileTab, setActiveMobileTab] = useState<MobileChatTab>("chat")
  const [workspaceWidth, setWorkspaceWidth] = useState(storedWorkspaceWidth)
  const [panelCollapsed, setPanelCollapsed] = useState(storedWorkspaceCollapsed)
  const [bookmarkTarget, setBookmarkTarget] = useState<BookmarkTarget | null>(null)
  const [bookmarkPickerOpen, setBookmarkPickerOpen] = useState(false)
  const bookmarkRequestIdRef = useRef(0)
  const handledMessageDeepLinkRef = useRef<string | null>(null)
  const navigate = useNavigate()
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { t } = useT("chat")
  const expanded = activeTab === "whiteboard" && whiteboardFullscreen

  useEffect(() => {
    storeWorkspacePreference(CHAT_WORKSPACE_TAB_KEY, activeTab)
  }, [activeTab])

  useEffect(() => {
    storeWorkspacePreference(CHAT_WORKSPACE_WIDTH_KEY, String(workspaceWidth))
  }, [workspaceWidth])

  useEffect(() => {
    storeWorkspacePreference(CHAT_WORKSPACE_COLLAPSED_KEY, String(panelCollapsed))
  }, [panelCollapsed])

  function beginResize(event: ReactMouseEvent<HTMLButtonElement>) {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = workspaceWidth

    function resize(moveEvent: MouseEvent) {
      setWorkspaceWidth(clampWorkspaceWidth(startWidth - (moveEvent.clientX - startX)))
    }

    function stopResize() {
      window.removeEventListener("mousemove", resize)
      window.removeEventListener("mouseup", stopResize)
    }

    window.addEventListener("mousemove", resize)
    window.addEventListener("mouseup", stopResize)
  }

  function selectTab(tab: WorkspaceTab) {
    if (tab !== "whiteboard") onWhiteboardFullscreenChange(false)
    setActiveTab(tab)
  }

  function selectMobileTab(tab: MobileChatTab) {
    setActiveMobileTab(tab)
    if (tab === "chat") {
      onWhiteboardFullscreenChange(false)
      return
    }

    selectTab(tab)
  }

  function selectBookmark(messageId: number) {
    onWhiteboardFullscreenChange(false)
    setActiveMobileTab("chat")
    bookmarkRequestIdRef.current += 1
    setBookmarkTarget({ messageId, requestId: bookmarkRequestIdRef.current })
  }

  useEffect(() => {
    const searchParams = new URLSearchParams(queryKey[2])
    const messageId = Number.parseInt(searchParams.get("message_id") || "", 10)
    if (!Number.isFinite(messageId) || messageId <= 0) return

    const deepLinkKey = `${payload.chat.id}:${messageId}`
    if (handledMessageDeepLinkRef.current === deepLinkKey) return

    handledMessageDeepLinkRef.current = deepLinkKey
    selectBookmark(messageId)
    searchParams.delete("message_id")
    const nextSearch = searchParams.toString()
    navigate({ search: nextSearch ? `?${nextSearch}` : "" }, { replace: true })
  }, [navigate, payload.chat.id, queryKey])

  const commandHandlers: ChatSystemCommandHandlers = {
    openBookmarks: () => {
      onWhiteboardFullscreenChange(false)
      setBookmarkPickerOpen(true)
    },
    openAttachments: () => {
      onWhiteboardFullscreenChange(false)
      setActiveTab("context")
      setActiveMobileTab("context")
    },
    openSettings: () => onSettingsOpenChange(true)
  }

  if (!isDesktop && !expanded) {
    return (
      <div className="flex min-h-0 flex-1 flex-col bg-white dark:bg-gray-950">
        <nav aria-label="Chat mobile tabs" className="flex shrink-0 overflow-x-auto border-b border-gray-200 px-2 pt-2 text-sm font-medium dark:border-gray-700">
          {(["chat", "whiteboard", "context", "media", ...(codingFilesTabVisible(payload) ? (["files"] as MobileChatTab[]) : []), ...(payload.local_tunnel_connected ? (["diff"] as MobileChatTab[]) : []), ...(jobsTabVisible(payload) ? (["jobs"] as MobileChatTab[]) : [])] as MobileChatTab[]).map((tab) => (
            <button
              className={workspaceTabClass(activeMobileTab === tab)}
              key={tab}
              onClick={() => selectMobileTab(tab)}
              type="button"
            >
              {mobileChatTabLabel(tab)}
            </button>
          ))}
        </nav>
        <div className="flex min-h-0 w-full flex-1">
          {activeMobileTab === "chat" ? (
            <ChatColumn bookmarkTarget={bookmarkTarget} chatId={chatId} commandHandlers={commandHandlers} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
          ) : (
            <ChatWorkspacePanel
              activeTab={activeTab}
              fullscreen={false}
              showTabs={false}
              onSelectTab={selectTab}
              onToggleWhiteboardFullscreen={() => onWhiteboardFullscreenChange(true)}
              payload={payload}
              prefix={prefix}
              queryKey={queryKey}
              onNotice={onNotice}
              onBookmarkSelect={selectBookmark}
            />
          )}
        </div>
        {settingsOpen ? <ChatSettingsDialog payload={payload} prefix={prefix} queryKey={queryKey} onClose={() => onSettingsOpenChange(false)} /> : null}
        {bookmarkPickerOpen ? <BookmarkPickerModal bookmarks={payload.bookmarks} onClose={() => setBookmarkPickerOpen(false)} onSelect={selectBookmark} /> : null}
      </div>
    )
  }

  return (
    <div
      className={expanded ? "flex min-h-0 flex-1 flex-col" : "flex min-h-0 flex-1 flex-col gap-4 lg:grid lg:gap-0"}
      style={
        expanded
          ? undefined
          : {
              gridTemplateColumns: panelCollapsed
                ? "minmax(0,1fr) 0 2.5rem"
                : `minmax(0,1fr) 0.5rem minmax(${CHAT_WORKSPACE_MIN_WIDTH}px,${workspaceWidth}px)`,
              transition: "grid-template-columns 150ms ease"
            }
      }
    >
      {expanded ? null : <ChatColumn bookmarkTarget={bookmarkTarget} chatId={chatId} commandHandlers={commandHandlers} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />}
      {expanded || panelCollapsed ? null : (
        <button
          aria-label={t("resize_workspace")}
          className="hidden cursor-col-resize rounded bg-transparent transition hover:bg-blue-100 focus:bg-blue-100 focus:outline-none lg:block dark:hover:bg-blue-950 dark:focus:bg-blue-950"
          onMouseDown={beginResize}
          type="button"
        />
      )}
      {!expanded && panelCollapsed ? (
        <div className="hidden lg:flex lg:flex-col lg:items-start lg:pt-3">
          <button
            aria-label={t("open_workspace")}
            className="rounded p-1.5 text-gray-400 transition hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
            onClick={() => setPanelCollapsed(false)}
            title={t("open_panel")}
            type="button"
          >
            <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
              <rect height="18" rx="2" ry="2" width="18" x="3" y="3" />
              <line x1="15" x2="15" y1="3" y2="21" />
              <polyline points="12 9 15 12 12 15" />
            </svg>
          </button>
        </div>
      ) : null}
      {expanded || !panelCollapsed ? (
        <ChatWorkspacePanel
          activeTab={activeTab}
          fullscreen={expanded}
          onSelectTab={selectTab}
          onToggleCollapse={expanded ? undefined : () => setPanelCollapsed(true)}
          onToggleWhiteboardFullscreen={() => onWhiteboardFullscreenChange(!expanded)}
          payload={payload}
          prefix={prefix}
          queryKey={queryKey}
          onNotice={onNotice}
          onBookmarkSelect={selectBookmark}
        />
      ) : null}
      {settingsOpen ? <ChatSettingsDialog payload={payload} prefix={prefix} queryKey={queryKey} onClose={() => onSettingsOpenChange(false)} /> : null}
      {bookmarkPickerOpen ? <BookmarkPickerModal bookmarks={payload.bookmarks} onClose={() => setBookmarkPickerOpen(false)} onSelect={selectBookmark} /> : null}
    </div>
  )
}

function BookmarkPickerModal({ bookmarks, onClose, onSelect }: { bookmarks: ChatBookmark[]; onClose: () => void; onSelect: (messageId: number) => void }) {
  const { t } = useT("chat")
  function selectBookmark(bookmark: ChatBookmark) {
    onSelect(bookmark.anchor_message_id ?? bookmark.chat_message_id)
    onClose()
  }

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" onClick={onClose} role="presentation">
      <section aria-labelledby="bookmark-picker-title" aria-modal="true" className="w-full max-w-md rounded border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-900" onClick={(event) => event.stopPropagation()} role="dialog">
        <header className="flex items-center justify-between border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="bookmark-picker-title">{t("bookmarks")}</h2>
          <button
            aria-label={t("close_bookmarks")}
            className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </header>
        <div className="max-h-[min(24rem,calc(100dvh-10rem))] overflow-y-auto p-2">
          {bookmarks.length === 0 ? (
            <div className="px-2 py-6 text-center text-sm text-gray-500 dark:text-gray-400">{t("no_bookmarks")}</div>
          ) : (
            <div className="space-y-1">
              {bookmarks.map((bookmark) => (
                <button
                  className="flex w-full items-center gap-3 rounded px-3 py-2 text-left text-sm text-gray-800 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-100 dark:hover:bg-gray-800"
                  key={bookmark.id}
                  onClick={() => selectBookmark(bookmark)}
                  type="button"
                >
                  <span aria-hidden="true" className="h-1.5 w-1.5 shrink-0 rounded-full bg-gray-400 dark:bg-gray-500" />
                  <span className="min-w-0 break-words">{bookmark.label}</span>
                </button>
              ))}
            </div>
          )}
        </div>
      </section>
    </div>
  )
}

function CodingCheckoutBanner({ payload, queryKey, onNotice }: { payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const cancelPath = payload.paths.app_cancel_coding_checkout_path
  const cancel = useMutation({
    mutationFn: () => cancelCodingCheckout(cancelPath!),
    onSuccess: (updated) => {
      queryClient.setQueryData<ChatPayload>(queryKey, updated)
      onNotice(t("coding_checkout_cancelled_notice"))
    },
    onError: () => {
      onNotice(t("coding_checkout_cancel_error"))
    }
  })

  if (!payload.coding_mode_enabled || !payload.chat.coding_checkout_uncommitted || !cancelPath) return null

  return (
    <div className="flex items-center justify-between rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
      <span>{t("coding_checkout_uncommitted_banner")}</span>
      <button
        className="shrink-0 font-medium underline hover:no-underline disabled:cursor-not-allowed disabled:no-underline disabled:opacity-50"
        disabled={cancel.isPending}
        onClick={() => cancel.mutate()}
        type="button"
      >
        {t("cancel_coding_checkout")}
      </button>
    </div>
  )
}

function ChatColumn({ bookmarkTarget, chatId, commandHandlers, payload, prefix, queryKey, onNotice }: { bookmarkTarget: BookmarkTarget | null; chatId: string; commandHandlers: ChatSystemCommandHandlers; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const [hasSentFirstMessage, setHasSentFirstMessage] = useState(false)
  const { t } = useT("chat")
  const landing = payload.messages.length === 0 && payload.pending_actions.length === 0 && !hasSentFirstMessage

  useEffect(() => {
    setHasSentFirstMessage(false)
  }, [payload.chat.id])

  return (
    <section className={`flex min-h-0 min-w-0 flex-1 flex-col transition-all duration-500 ${landing ? "items-center justify-center gap-6 px-4" : "gap-3"}`}>
      {landing ? (
        <h1 className="text-center text-3xl font-semibold tracking-normal text-gray-950 sm:text-4xl dark:text-gray-100">{t("landing_prompt")}</h1>
      ) : null}
      {payload.local_mode_enabled && payload.chat.mode === "local" ? (
        <LocalDaemonBanner payload={payload} />
      ) : null}
      <div className={`relative min-h-0 overflow-hidden rounded border border-gray-200 bg-white transition-all duration-500 ease-out dark:border-gray-700 dark:bg-gray-950 ${landing ? "h-0 w-full max-w-2xl opacity-0" : "flex-1 opacity-100"}`}>
        <MessageStream bookmarkTarget={bookmarkTarget} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
        <UsageOverlay payload={payload} />
      </div>
      <div className={landing ? "w-full max-w-sm sm:max-w-2xl" : "space-y-3"}>
        {!landing ? <CodingCheckoutBanner payload={payload} queryKey={queryKey} onNotice={onNotice} /> : null}
        <Compose key={chatId} autoFocus={landing} chatId={chatId} commandHandlers={commandHandlers} payload={payload} prefix={prefix} queryKey={queryKey} showAttachedRepositories={landing} onNotice={onNotice} onMessageSent={() => setHasSentFirstMessage(true)} />
      </div>
    </section>
  )
}

function LocalDaemonBanner({ payload }: { payload: ChatPayload }) {
  const { t } = useT("chat")
  const [copied, setCopied] = useState(false)
  const copyTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => () => { if (copyTimeoutRef.current) clearTimeout(copyTimeoutRef.current) }, [])

  function copyCommand() {
    void navigator.clipboard.writeText(t("local_daemon_command")).then(() => {
      setCopied(true)
      copyTimeoutRef.current = setTimeout(() => setCopied(false), 2000)
    })
  }

  const daemonState = payload.chat.local_daemon_state ?? null

  if (daemonState === "connected") return null

  if (daemonState === "disconnected") {
    return (
      <section className="rounded border border-amber-200 bg-white p-4 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
        <div className="font-semibold">{t("local_daemon_disconnected_title")}</div>
        <p className="mt-1">{t("local_daemon_disconnected_body")}</p>
      </section>
    )
  }

  return (
    <section className="rounded border border-gray-200 bg-gray-50 p-4 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">
      <div className="font-semibold">{t("local_daemon_not_connected_title")}</div>
      <p className="mt-1">{t("local_daemon_not_connected_body")}</p>
      <div className="mt-3 flex items-center gap-2">
        <code className="rounded bg-gray-100 px-2 py-1 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">{t("local_daemon_command")}</code>
        <button
          className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-600 transition hover:bg-gray-50 hover:text-gray-800 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700 dark:hover:text-gray-100"
          onClick={copyCommand}
          type="button"
        >
          {copied ? t("local_daemon_copied") : t("local_daemon_copy")}
        </button>
      </div>
    </section>
  )
}

function AgentQuestions({ questions, queryKey, onNotice }: { questions: ChatAgentQuestion[]; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  return (
    <section aria-label="Agent questions" className="w-full max-w-3xl space-y-3 rounded border border-blue-200 bg-blue-50 p-3 dark:border-blue-800 dark:bg-blue-950/60">
      {questions.map((question) => <AgentQuestionPrompt key={question.id} question={question} queryKey={queryKey} onNotice={onNotice} />)}
    </section>
  )
}

function AgentQuestionPrompt({ question, queryKey, onNotice }: { question: ChatAgentQuestion; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [answer, setAnswer] = useState("")
  const submit = useMutation({
    mutationFn: (value: string) => answerAgentQuestion(appendSearch(question.app_answer_path, search), value),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setAnswer("")
      onNotice(updated.message || null)
    }
  })
  const options = question.options?.filter((option) => option.trim().length > 0) || []

  function submitText(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const value = answer.trim()
    if (value.length === 0 || submit.isPending) return

    submit.mutate(value)
  }

  function declineAnswer() {
    if (submit.isPending) return

    submit.mutate("I decline to answer.")
  }

  return (
    <div className="space-y-3 rounded border border-blue-200 bg-white p-3 text-sm dark:border-blue-800 dark:bg-gray-950">
      <div className="font-medium text-gray-900 dark:text-gray-100">{question.question}</div>
      {submit.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(submit.error, "Answer could not be submitted.")}</div> : null}
      {options.length > 0 ? (
        <div className="flex flex-col gap-2">
          {options.map((option) => (
            <button className={`${secondaryButton()} flex w-full justify-start text-left`} disabled={submit.isPending} key={option} onClick={() => submit.mutate(option)} type="button">
              {option}
            </button>
          ))}
        </div>
      ) : null}
      <form className="flex flex-col gap-2 sm:flex-row" onSubmit={submitText}>
        <input
          aria-label="Custom answer"
          className="min-h-9 flex-1 rounded border border-gray-300 px-3 py-2 text-base focus:border-blue-500 focus:ring-blue-500 sm:text-sm dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100"
          disabled={submit.isPending}
          onChange={(event) => setAnswer(event.target.value)}
          placeholder="Custom response"
          value={answer}
        />
        <button className={primaryButton()} disabled={submit.isPending || answer.trim().length === 0} type="submit">Submit</button>
      </form>
      <button className={`${secondaryButton()} flex w-full justify-start text-left`} disabled={submit.isPending} onClick={declineAnswer} type="button">
        Decline to answer
      </button>
    </div>
  )
}

function ChatWorkspacePanel({
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
  return (
    <aside aria-label="Chat workspace" className={`flex min-h-0 min-w-0 flex-1 flex-col rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900 ${fullscreen ? "" : "h-full w-full"}`}>
      {fullscreen || !showTabs ? null : (
        <nav aria-label="Chat workspace tabs" className="flex items-center border-b border-gray-200 px-3 pt-3 text-sm font-medium dark:border-gray-700">
          {(["whiteboard", "context", "media", ...(codingFilesTabVisible(payload) ? (["files"] as WorkspaceTab[]) : []), ...(payload.local_tunnel_connected ? (["diff"] as WorkspaceTab[]) : []), ...(jobsTabVisible(payload) ? (["jobs"] as WorkspaceTab[]) : [])] as WorkspaceTab[]).map((tab) => (
            <button
              className={workspaceTabClass(activeTab === tab)}
              key={tab}
              onClick={() => onSelectTab(tab)}
              type="button"
            >
              {workspaceTabLabel(tab)}
            </button>
          ))}
          {onToggleCollapse ? (
            <button
              aria-label="Close workspace panel"
              className="ml-auto self-center rounded p-1.5 text-gray-400 transition hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onToggleCollapse}
              title="Close panel"
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

function renderUnifiedDiff(diff: string): ReactNode[] {
  const nodes: ReactNode[] = []
  diff.split("\n").forEach((line, index) => {
    let className: string
    if (line.startsWith("+++") || line.startsWith("---")) {
      className = "text-gray-500 dark:text-gray-400"
    } else if (line.startsWith("@@")) {
      className = "text-blue-600 dark:text-blue-400"
    } else if (line.startsWith("+")) {
      className = "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
    } else if (line.startsWith("-")) {
      className = "bg-red-50 text-red-800 dark:bg-red-950 dark:text-red-300"
    } else if (line.startsWith("diff ") || line.startsWith("index ")) {
      className = "font-semibold text-gray-700 dark:text-gray-300"
    } else {
      className = "text-gray-700 dark:text-gray-300"
    }
    nodes.push(
      <div className={`block whitespace-pre ${className}`} key={index}>
        {line || " "}
      </div>
    )
  })
  return nodes
}

function LocalDiffPanel() {
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
            Staged
          </button>
        </div>
        <button
          aria-label="Refresh diff"
          className="rounded p-1 text-gray-400 transition hover:bg-gray-100 hover:text-gray-700 disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
          disabled={loading}
          onClick={() => refresh(mode)}
          title="Refresh"
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
        <p className="text-sm text-gray-500 dark:text-gray-400">Loading diff…</p>
      ) : error ? (
        <p className="text-sm text-red-600 dark:text-red-400">
          {error === "not_connected" ? "Daemon not connected." : `Error: ${error}`}
        </p>
      ) : isEmpty ? (
        <p className="text-sm text-gray-500 dark:text-gray-400">
          {mode === "staged" ? "No staged changes." : "No uncommitted changes."}
        </p>
      ) : (
        <div className="overflow-x-auto rounded border border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-950">
          <code className="block p-3 font-mono text-xs leading-5">
            {renderUnifiedDiff(diff!)}
          </code>
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
      onNotice(`Loaded ${fullSnapshot.name || "snapshot"} onto canvas`)
    } catch (error) {
      setSnapshotError(errorMessage(errorAsError(error), "Snapshot could not be loaded."))
    } finally {
      setLoadingSnapshotId(null)
    }
  }

  if (images.length === 0 && snapshotItems.length === 0 && walkthroughs.length === 0 && !snapshots.isPending && !snapshots.isError) {
    return <PanelMessage>No media shared yet.</PanelMessage>
  }

  return (
    <div className="space-y-5">
      {snapshots.isPending ? <PanelMessage>Loading snapshots...</PanelMessage> : null}
      {snapshots.isError ? <PanelMessage tone="error">{errorMessage(snapshots.error, "Unable to load snapshots.")}</PanelMessage> : null}
      {snapshotError ? <PanelMessage tone="error">{snapshotError}</PanelMessage> : null}
      {whiteboardLocked ? <div className="rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">Canvas is busy. Wait for drawing to finish before loading a snapshot.</div> : null}

      {snapshotItems.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Whiteboard Snapshots</h2>
          <div className="space-y-2">
            {snapshotItems.map((snapshot) => (
              <article className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-950" key={snapshot.id}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium text-gray-900 dark:text-gray-100" title={snapshot.name || "Snapshot"}>{truncateSnapshotName(snapshot.name || "Snapshot")}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                      <span className="rounded bg-gray-100 px-1.5 py-0.5 font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{snapshotKindLabel(snapshot.snapshot_kind)}</span>
                      <span>{snapshot.element_count} {snapshot.element_count === 1 ? "element" : "elements"}</span>
                      <span>{formatRelativeTime(snapshot.created_at)}</span>
                    </div>
                  </div>
                  <button
                    className={`${secondaryButton()} shrink-0 px-2 py-1 text-xs`}
                    disabled={whiteboardLocked || loadingSnapshotId != null}
                    onClick={() => void loadSnapshot(snapshot)}
                    type="button"
                  >
                    {loadingSnapshotId === snapshot.id ? "Loading..." : "Load"}
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
                      <span>{formatRelativeTime(walkthrough.created_at)}</span>
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
          <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Image Attachments</h2>
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
                      Download
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

function snapshotKindLabel(kind: WhiteboardSnapshot["snapshot_kind"]) {
  if (kind === "auto_clear") return "Before clear"
  if (kind === "auto_before_load") return "Before load"
  return "Saved"
}

function truncateSnapshotName(name: string) {
  return name.length > 40 ? `${name.slice(0, 39)}...` : name
}

function formatRelativeTime(value: string) {
  const timestamp = Date.parse(value)
  if (Number.isNaN(timestamp)) return ""

  const seconds = Math.round((timestamp - Date.now()) / 1000)
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
    ["second", 1]
  ]
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "always" })
  const [unit, unitSeconds] = units.find(([, unitSeconds]) => Math.abs(seconds) >= unitSeconds) || ["second", 1]
  return formatter.format(Math.round(seconds / unitSeconds), unit)
}

function ChatSettingsDialog({ payload, prefix, queryKey, onClose }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onClose: () => void }) {
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

  const modeOptions: Array<{ value: ChatMode | ""; label: string }> = [
    { value: "", label: t("mode_default") },
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
          <button aria-label="Close chat settings" className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <div className="space-y-3 text-sm">
          {payload.coding_mode_enabled ? (
            <label className="block">
              <span className="mb-1 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mode_label")}</span>
              <select
                aria-label={t("mode_label")}
                className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-gray-100 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:disabled:bg-gray-800"
                disabled={mode.isPending}
                onChange={(event) => mode.mutate(event.target.value as ChatMode)}
                value={payload.chat.mode || "planning"}
              >
                <option value="planning">{t("mode_planning")}</option>
                <option value="coding">{t("mode_coding")}</option>
              </select>
              <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("mode_hint")}</span>
            </label>
          ) : null}
          {mode.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(mode.error, t("mode_update_error"))}</div> : null}
          {showProviderSelector ? (
            <label className="block">
              <span className="mb-1 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Provider</span>
              <select
                aria-label="Chat provider"
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
              <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">Effective: {payload.chat.effective_chat_provider_label || "Default"}</span>
            </label>
          ) : null}
          {provider.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(provider.error, "Provider could not be updated.")}</div> : null}
          <label className="block">
            <span className="mb-1 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mode_label")}</span>
            <div className="flex rounded border border-gray-300 bg-white dark:border-gray-700 dark:bg-gray-950" role="group" aria-label={t("mode_label")}>
              {modeOptions.map(({ value, label }) => (
                <button
                  className={[
                    "flex-1 px-3 py-2 text-sm first:rounded-l last:rounded-r focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-terracotta-500",
                    (payload.chat.mode ?? "") === value
                      ? "bg-terracotta-600 font-medium text-white"
                      : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800",
                    mode.isPending ? "cursor-not-allowed opacity-50" : ""
                  ].join(" ")}
                  disabled={mode.isPending}
                  key={value || "default"}
                  onClick={() => mode.mutate(value)}
                  type="button"
                >
                  {label}
                </button>
              ))}
            </div>
          </label>
          {mode.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(mode.error, t("mode_update_error"))}</div> : null}
          {payload.chat.repository?.repository_path ? (
            <Link className="block rounded border border-gray-200 px-3 py-2 text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:text-gray-200 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200" onClick={onClose} to={withRoutePrefix(`${payload.chat.repository.repository_path}/edit`, prefix)}>
              Repository settings
            </Link>
          ) : null}
          <Link className="block rounded border border-gray-200 px-3 py-2 text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:text-gray-200 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200" onClick={onClose} to={withRoutePrefix("/credentials", prefix)}>
            Chat credentials
          </Link>
        </div>
      </section>
    </div>
  )
}

function providerLabel(provider: string) {
  if (provider === "claude") return "Claude"
  if (provider === "codex") return "Codex"
  return provider
}

type WhiteboardBoundaryState = {
  failed: boolean
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
      return (
        <section>
          <div className="mb-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Whiteboard</div>
          <div className="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
            Whiteboard unavailable.
          </div>
        </section>
      )
    }

    return this.props.children
  }
}

function WhiteboardPanel({ fullscreen, onToggleFullscreen, payload }: { fullscreen: boolean; onToggleFullscreen: () => void; payload: ChatPayload }) {
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
        <div className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Whiteboard</div>
        <div className="flex items-center gap-2">
          <button
            aria-pressed={fullscreen}
            className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
            onClick={onToggleFullscreen}
            type="button"
          >
            {fullscreen ? "Exit fullscreen" : "Fullscreen"}
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
            {loadError || "Loading canvas..."}
          </div>
        )}
        {scene.elements.length === 0 ? (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center px-6 text-center text-sm text-gray-400 dark:text-gray-500">
            Empty canvas. Start sketching, or ask the agent to draw something.
          </div>
        ) : null}
      </div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {saveError || `${scene.elements.length} canvas ${scene.elements.length === 1 ? "element" : "elements"}`}
      </div>
    </section>
  )
}

function whiteboardElements(payload: ChatPayload): ChatWhiteboardElement[] {
  return whiteboardScene(payload).elements
}

function whiteboardScene(payload: ChatPayload): ChatWhiteboardScene {
  return {
    elements: Array.isArray(payload.whiteboard.elements) ? payload.whiteboard.elements : [],
    appState: cleanWhiteboardAppState(payload.whiteboard.appState),
    files: isPlainObject(payload.whiteboard.files) ? payload.whiteboard.files as ChatWhiteboardScene["files"] : {}
  }
}

function cloneWhiteboardScene(scene: ChatWhiteboardScene): ChatWhiteboardScene {
  return {
    elements: JSON.parse(JSON.stringify(scene.elements)) as ChatWhiteboardElement[],
    appState: cleanWhiteboardAppState(scene.appState),
    files: cleanWhiteboardFiles(scene.files)
  }
}

function withFreshElementIds(elements: ChatWhiteboardElement[]) {
  const copied = JSON.parse(JSON.stringify(elements)) as ChatWhiteboardElement[]
  const idMap = new Map<string, string>()

  copied.forEach((element) => {
    const id = typeof element.id === "string" ? element.id : null
    if (id) idMap.set(id, newElementId())
  })

  return copied.map((element) => replaceElementIdReferences(element, idMap) as ChatWhiteboardElement)
}

function replaceElementIdReferences(value: unknown, idMap: Map<string, string>): unknown {
  if (typeof value === "string") return idMap.get(value) || value
  if (Array.isArray(value)) return value.map((item) => replaceElementIdReferences(item, idMap))
  if (!isPlainObject(value)) return value

  return Object.fromEntries(
    Object.entries(value).map(([key, child]) => [key, replaceElementIdReferences(child, idMap)])
  )
}

function newElementId() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID().replace(/-/g, "")

  return `snapshot${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`
}

function signatureForScene(scene: ChatWhiteboardScene) {
  return JSON.stringify(scene)
}

export const VALID_EXCALIDRAW_TYPES = new Set([
  "selection", "rectangle", "diamond", "ellipse", "embeddable", "iframe",
  "image", "frame", "magicframe", "text", "line", "arrow", "freedraw"
])

export function asExcalidrawElements(elements: readonly ChatWhiteboardElement[]) {
  return elements.filter(
    el => VALID_EXCALIDRAW_TYPES.has((el as { type?: string }).type ?? "")
  ) as unknown as readonly ExcalidrawElement[]
}

function asExcalidrawFiles(files: ChatWhiteboardScene["files"]) {
  return Object.values(files) as Parameters<ExcalidrawApi["addFiles"]>[0]
}

function cleanWhiteboardAppState(value: unknown): ChatWhiteboardScene["appState"] {
  const appState = safeJsonObject(value)
  delete appState.activeTool
  delete appState.selectedElementIds
  delete appState.selectedGroupIds
  delete appState.collaborators
  delete appState.editingElement
  delete appState.resizingElement
  delete appState.draggingElement
  delete appState.multiElement
  delete appState.suggestedBindings
  delete appState.startBoundElement
  return appState
}

function cleanWhiteboardFiles(value: unknown): ChatWhiteboardScene["files"] {
  const files = safeJsonObject(value)
  return Object.fromEntries(
    Object.entries(files).filter(([, file]) => isPlainObject(file))
  ) as ChatWhiteboardScene["files"]
}

function safeJsonObject(value: unknown): Record<string, unknown> {
  if (!isPlainObject(value)) return {}

  try {
    const parsed = JSON.parse(JSON.stringify(value)) as unknown
    return isPlainObject(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
}

function Attachments({ payload, queryKey, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Attachments</h2>
      </div>
      <div className="space-y-4">
        <AttachmentGroup label="Repos" rows={payload.attachment_groups.repositories} queryKey={queryKey} onNotice={onNotice} />
        <AttachmentGroup label="Epics" rows={payload.attachment_groups.epics} queryKey={queryKey} onNotice={onNotice} />
        <AttachmentGroup label="Jobs" rows={payload.attachment_groups.jobs} queryKey={queryKey} onNotice={onNotice} />
        <AttachmentGroup label="Documents" rows={payload.attachment_groups.documents} queryKey={queryKey} onNotice={onNotice} />
      </div>
      <section>
        <div className="mb-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">In-scope documents</div>
        {payload.documents_in_scope.length > 0 ? (
          <div className="space-y-1">
            {payload.documents_in_scope.map((document) => (
              <div className="rounded border border-gray-200 px-2 py-1.5 text-xs dark:border-gray-700" key={document.id}>
                <div className="font-medium text-gray-800 dark:text-gray-100">{document.title}</div>
                <div className="font-mono text-[0.7rem] text-gray-500 dark:text-gray-400">{document.repository_slug}</div>
              </div>
            ))}
          </div>
        ) : <div className="text-xs text-gray-400 dark:text-gray-500">No documents in scope.</div>}
      </section>
    </>
  )
}

function AttachmentGroup({ label, rows, queryKey, onNotice }: { label: string; rows: ChatAttachmentRow[]; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [pendingDetachId, setPendingDetachId] = useState<string | null>(null)
  const detach = useMutation({
    mutationFn: (path: string) => deleteChatAttachment(appendSearch(path, search)),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  return (
    <section>
      <div className="mb-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</div>
      {rows.length > 0 ? (
        <div className="space-y-1">
          {rows.map((row) => {
            const rowId = String(row.id)
            const pending = pendingDetachId === rowId
            return (
              <div className="flex items-center gap-2" key={row.id}>
                <button
                  className={`block w-full rounded border px-2 py-1.5 text-left text-xs disabled:text-gray-300 dark:disabled:text-gray-600 ${pending ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-300" : "border-gray-200 bg-gray-50 text-gray-700 hover:border-red-200 hover:bg-red-50 hover:text-red-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300 dark:hover:border-red-800 dark:hover:bg-red-950 dark:hover:text-red-300"}`}
                  disabled={detach.isPending}
                  onClick={() => {
                    if (pending) {
                      setPendingDetachId(null)
                      detach.mutate(row.app_detach_path)
                    } else {
                      setPendingDetachId(rowId)
                    }
                  }}
                  title={`Detach ${row.label}`}
                  type="button"
                >
                  {pending ? `Detach ${row.label}?` : row.label}
                </button>
                {pending ? (
                  <button
                    className="shrink-0 rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-600 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
                    disabled={detach.isPending}
                    onClick={() => setPendingDetachId(null)}
                    type="button"
                  >
                    Cancel
                  </button>
                ) : null}
              </div>
            )
          })}
        </div>
      ) : <div className="text-xs text-gray-400 dark:text-gray-500">None</div>}
      {detach.isError ? <div className="mt-1 text-xs text-red-700 dark:text-red-300">{errorMessage(detach.error, "Detach failed.")}</div> : null}
    </section>
  )
}

function AddAttachment({ payload, prefix, queryKey, onAttached, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onAttached?: () => void; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const location = useLocation()
  const navigate = useNavigate()
  const params = new URLSearchParams(location.search)
  const [type, setType] = useState(params.get("attachment_type") || "Repository")
  const [query, setQuery] = useState(params.get("attachment_query") || "")
  const searchInputRef = useRef<HTMLInputElement | null>(null)
  const submitTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const add = useMutation({
    mutationFn: (record: ChatAttachmentResult) => addChatAttachment(appendSearch(payload.paths.app_attachments_path, location.search), record),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
      onAttached?.()
    }
  })

  useEffect(() => {
    const next = new URLSearchParams(location.search)
    setType(next.get("attachment_type") || "Repository")
    setQuery(next.get("attachment_query") || "")
  }, [location.search])

  useEffect(() => {
    return () => {
      if (submitTimer.current) clearTimeout(submitTimer.current)
    }
  }, [])

  useEffect(() => {
    searchInputRef.current?.focus()
  }, [])

  function submitSearch() {
    navigateToSearch(type, query)
  }

  function scheduleSubmit(nextQuery: string) {
    if (submitTimer.current) clearTimeout(submitTimer.current)
    submitTimer.current = setTimeout(() => {
      navigateToSearch(type, nextQuery)
    }, 200)
  }

  function submitWithType(nextType: string) {
    if (submitTimer.current) clearTimeout(submitTimer.current)
    navigateToSearch(nextType, query)
  }

  function navigateToSearch(nextType: string, nextQuery: string) {
    const next = new URLSearchParams()
    next.set("attachment_type", nextType)
    if (nextQuery.trim()) next.set("attachment_query", nextQuery.trim())
    navigate(withRoutePrefix(`${payload.chat.chat_path}?${next.toString()}`, prefix))
  }

  return (
    <div>
      <div>
        <div className="flex gap-1 p-2">
          {(["Repository", "Epic", "Job", "Document"] as const).map((nextType) => (
            <button
              className={`rounded px-2 py-1 text-xs font-medium transition-colors ${
                type === nextType
                  ? "bg-blue-600 text-white dark:bg-blue-500"
                  : "text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"
              }`}
              key={nextType}
              onClick={() => {
                setType(nextType)
                submitWithType(nextType)
              }}
              type="button"
            >
              {nextType === "Repository" ? "Repo" : nextType === "Document" ? "Doc" : nextType}
            </button>
          ))}
        </div>
        <div className="px-2 pb-2">
          <input
            autoFocus
            className="w-full rounded border border-gray-200 bg-white px-2 py-1.5 text-sm placeholder:text-gray-400 focus:border-blue-500 focus:outline-none dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500"
            data-autofocus
            name="attachment_query"
            onChange={(event) => {
              setQuery(event.target.value)
              scheduleSubmit(event.target.value)
            }}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault()
                submitSearch()
              }
            }}
            placeholder="Search by name or id..."
            ref={searchInputRef}
            type="search"
            value={query}
          />
        </div>
      </div>
      <div className="space-y-0 border-t border-gray-100 dark:border-gray-800">
        {payload.attachment_results.length > 0 ? payload.attachment_results.map((record) => (
          <button
            className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-blue-50 hover:text-blue-700 disabled:text-gray-300 dark:text-gray-300 dark:hover:bg-blue-950 dark:hover:text-blue-200 dark:disabled:text-gray-600"
            disabled={add.isPending}
            key={`${record.type}-${record.id}`}
            onClick={() => add.mutate(record)}
            type="button"
          >
            {record.label}
          </button>
        )) : <div className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">No matches.</div>}
        {add.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(add.error, "Attachment failed.")}</div> : null}
      </div>
    </div>
  )
}

function UsageOverlay({ payload }: { payload: ChatPayload }) {
  return (
    <p className="pointer-events-none absolute left-0 right-0 top-0 border-b border-gray-100 bg-white/95 px-4 py-1.5 text-xs text-gray-500 dark:border-gray-800 dark:bg-gray-950/95 dark:text-gray-400">
      Tokens: {formatTokenCount(payload.chat.cumulative_input_tokens)} in / {formatTokenCount(payload.chat.cumulative_output_tokens)} out · {formatCurrency(payload.chat.cumulative_cost_usd)}
    </p>
  )
}

function PillList({ values }: { values: string[] }) {
  return <div className="flex flex-wrap gap-1">{values.map((value) => <span className="rounded bg-gray-100 px-2 py-0.5 font-mono dark:bg-gray-800" key={value}>{value}</span>)}</div>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-800 dark:bg-green-950 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function primaryButton() {
  return "flex h-9 items-center justify-center rounded bg-blue-600 px-3 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-60 dark:bg-blue-500 dark:hover:bg-blue-400"
}

function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
}

function codingFilesTabVisible(payload: ChatPayload): boolean {
  return Boolean(
    payload.coding_mode_enabled &&
    payload.chat.mode === "coding" &&
    payload.chat.coding_checkout_branch
  )
}

function jobsTabVisible(payload: ChatPayload): boolean {
  return (payload.chat.confirmed_proposal_count ?? 0) > 0
}

type FileTreeNode = {
  name: string
  path: string
  type: "file" | "directory"
  children: FileTreeNode[]
}

function buildFileTree(files: string[]): FileTreeNode[] {
  const nodeMap = new Map<string, FileTreeNode>()

  for (const filePath of files) {
    const parts = filePath.split("/")
    for (let i = 1; i < parts.length; i++) {
      const dirPath = parts.slice(0, i).join("/")
      if (!nodeMap.has(dirPath)) {
        nodeMap.set(dirPath, { name: parts[i - 1], path: dirPath, type: "directory", children: [] })
      }
    }
    nodeMap.set(filePath, { name: parts[parts.length - 1], path: filePath, type: "file", children: [] })
  }

  for (const [path, node] of nodeMap) {
    const parts = path.split("/")
    if (parts.length > 1) {
      const parentPath = parts.slice(0, -1).join("/")
      nodeMap.get(parentPath)?.children.push(node)
    }
  }

  function sortNodes(nodes: FileTreeNode[]): FileTreeNode[] {
    return [...nodes]
      .sort((a, b) => (a.type !== b.type ? (a.type === "directory" ? -1 : 1) : a.name.localeCompare(b.name)))
      .map((n) => ({ ...n, children: sortNodes(n.children) }))
  }

  const roots: FileTreeNode[] = []
  for (const [path, node] of nodeMap) {
    if (!path.includes("/")) roots.push(node)
  }
  return sortNodes(roots)
}

function diffLineClass(line: string): string {
  if (line.startsWith("+++") || line.startsWith("---")) {
    return "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"
  }
  if (line.startsWith("@@")) {
    return "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300"
  }
  if (line.startsWith("+")) {
    return "bg-green-50 text-green-800 dark:bg-green-950 dark:text-green-200"
  }
  if (line.startsWith("-")) {
    return "bg-red-50 text-red-800 dark:bg-red-950 dark:text-red-200"
  }
  return "text-gray-800 dark:text-gray-200"
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
  const [openDirs, setOpenDirs] = useState<Set<string>>(new Set())

  const filesPath = payload.paths.app_coding_files_path
  const fileContentBasePath = payload.paths.app_coding_file_path
  const diffPath = payload.paths.app_coding_diff_path
  const agentBusy = payload.agent_busy
  const refetchInterval = agentBusy ? 3000 : 15000

  const fileTree = useQuery({
    queryKey: ["coding_files", filesPath],
    queryFn: () => fetchCodingFileTree(filesPath!),
    enabled: !!filesPath,
    refetchInterval
  })

  const fileContent = useQuery({
    queryKey: ["coding_file_content", fileContentBasePath, selectedFile],
    queryFn: () => fetchCodingFileContent(fileContentBasePath!, selectedFile!),
    enabled: !!fileContentBasePath && !!selectedFile && view === "files",
    refetchInterval
  })

  const diffResult = useQuery({
    queryKey: ["coding_diff", diffPath, diffMode],
    queryFn: () => fetchCodingDiff(diffPath!, diffMode),
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
        {view === "diff" ? (
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
              <pre className="min-w-0 overflow-x-auto p-3 font-mono text-xs leading-relaxed text-gray-800 dark:text-gray-200">
                <code>{fileContent.data?.content ?? ""}</code>
              </pre>
            )}
          </div>
        </div>
      ) : (
        <div className="min-h-0 flex-1 overflow-auto">
          {diffResult.isPending ? (
            <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("diff_loading")}</p>
          ) : diffResult.isError ? (
            <p className="px-4 py-3 text-xs text-red-600 dark:text-red-400">{t("diff_error")}</p>
          ) : !diffResult.data?.diff ? (
            <p className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400">{t("diff_empty")}</p>
          ) : (
            <pre className="min-w-max font-mono text-xs leading-relaxed">
              {diffResult.data.diff.split("\n").map((line, i) => (
                <div className={`px-3 py-px ${diffLineClass(line)}`} key={i}>{line || " "}</div>
              ))}
            </pre>
          )}
        </div>
      )}
    </div>
  )
}

function workspaceTabClass(active: boolean) {
  return `border-b-2 px-3 py-2 ${active ? "border-blue-600 text-blue-700 dark:border-blue-400 dark:text-blue-300" : "border-transparent text-gray-600 hover:border-gray-300 hover:text-gray-900 dark:text-gray-400 dark:hover:border-gray-600 dark:hover:text-gray-100"}`
}

function workspaceTabLabel(tab: WorkspaceTab) {
  if (tab === "whiteboard") return "Whiteboard"
  if (tab === "context") return "Context"
  if (tab === "media") return "Media"
  if (tab === "files") return "Files"
  if (tab === "diff") return "Local Diff"
  if (tab === "jobs") return "Jobs"

  return "Chats"
}

function mobileChatTabLabel(tab: MobileChatTab) {
  return tab === "chat" ? "Chat" : workspaceTabLabel(tab)
}

function defaultWorkspaceTab(payload: ChatPayload): WorkspaceTab {
  return whiteboardElements(payload).length > 0 ? "whiteboard" : "context"
}

function storedWorkspaceTab(): WorkspaceTab | null {
  try {
    const value = window.localStorage.getItem(CHAT_WORKSPACE_TAB_KEY)
    return value === "whiteboard" || value === "context" || value === "media" || value === "files" || value === "diff" || value === "jobs" ? value : null
  } catch (_error) {
    return null
  }
}

export function storedWorkspaceCollapsed(): boolean {
  try {
    const value = window.localStorage.getItem(CHAT_WORKSPACE_COLLAPSED_KEY)
    return value === null ? true : value === "true"
  } catch (_error) {
    return true
  }
}

function storedWorkspaceWidth() {
  try {
    return clampWorkspaceWidth(Number.parseInt(window.localStorage.getItem(CHAT_WORKSPACE_WIDTH_KEY) || "", 10) || CHAT_WORKSPACE_DEFAULT_WIDTH)
  } catch (_error) {
    return CHAT_WORKSPACE_DEFAULT_WIDTH
  }
}

function storeWorkspacePreference(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value)
  } catch (_error) {
    // Local storage can be unavailable in hardened browser modes; the
    // workspace still works with in-memory state.
  }
}

function clampWorkspaceWidth(width: number) {
  return Math.min(Math.max(width, CHAT_WORKSPACE_MIN_WIDTH), CHAT_WORKSPACE_MAX_WIDTH)
}

function chatDisplayTitle(chat: Pick<ChatNavRecord, "id" | "title" | "title_pending" | "repository">) {
  if (chat.title_pending) return "Naming chat..."

  return chat.title || chat.repository?.slug || `Chat #${chat.id}`
}

function currentRecentChat(payload: ChatPayload) {
  return payload.recent_chats.find((chat) => chat.id === payload.chat.id)
}

function formatTokenCount(value: number) {
  if (value < 1000) return new Intl.NumberFormat("en-US").format(value)

  const thousands = value / 1000
  const compact = Number.isInteger(thousands) ? String(thousands) : thousands.toFixed(1).replace(/\.0$/, "")
  return `${compact}k`
}

function formatCurrency(value: number, digits = 4) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value)
}

function renderChatMessages(messages: ChatMessageItem[]): ChatRenderItem[] {
  const items: ChatRenderItem[] = []
  let currentGroup: ChatToolGroupItem | null = null

  for (const message of messages) {
    if (groupableToolUse(message)) {
      const toolName = message.tool_name || ""
      const call = {
        message_id: message.id,
        detail: toolDetail(toolName, contentInput(message.content)),
        result_body: "",
        result_error: false,
        result_summary: ""
      }
      const tool = toolLabel(toolName)
      if (currentGroup !== null && currentGroup.tool === tool) {
        currentGroup.calls.push(call)
      } else {
        currentGroup = { type: "tool_group", tool, calls: [call] }
        items.push(currentGroup)
      }
    } else if (groupableToolResult(message)) {
      const lastCall = currentGroup?.calls.at(-1)
      if (lastCall && lastCall.result_body === "") {
        const content = contentRecord(message.content)
        lastCall.result_body = shortenWorkspacePaths(content ? fullResultBody(content.result) : String(message.content ?? message.text))
        lastCall.result_error = content?.is_error === true
        lastCall.result_summary = toolResultSummary(currentGroup?.tool || "", lastCall.result_body)
      } else {
        currentGroup = null
        const item = renderMessage(message)
        if (item) items.push(item)
      }
    } else {
      currentGroup = null
      const item = renderMessage(message)
      if (item) items.push(item)
    }
  }

  return items
}

function lastAssistantRenderedMessage(messages: ChatMessageItem[]) {
  const items = renderChatMessages(messages)
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index]
    if (item.type === "message" && item.role === "assistant") return item
  }

  return null
}

function buildMessageStreamItems(items: ChatRenderItem[], pendingActions: ChatPendingAction[]): ChatStreamItem[] {
  if (pendingActions.length === 0) return items

  const actionsByMessageId = new Map<number, ChatPendingAction[]>()
  const unanchoredActions: ChatPendingAction[] = []
  const renderedMessageIds = new Set<number>()
  const result: ChatStreamItem[] = []

  for (const action of pendingActions) {
    const messageId = action.chat_message_id
    if (messageId == null) {
      unanchoredActions.push(action)
      continue
    }

    const actions = actionsByMessageId.get(messageId) || []
    actions.push(action)
    actionsByMessageId.set(messageId, actions)
  }

  for (const item of items) {
    result.push(item)

    const messageIds = streamItemMessageIds(item)
    for (const messageId of messageIds) {
      renderedMessageIds.add(messageId)
      const actions = actionsByMessageId.get(messageId) || []
      for (const action of actions) {
        result.push({ type: "pending_action", pendingAction: action })
      }
    }
  }

  for (const [messageId, actions] of actionsByMessageId) {
    if (renderedMessageIds.has(messageId)) continue
    unanchoredActions.push(...actions)
  }

  for (const action of unanchoredActions) {
    result.push({ type: "pending_action", pendingAction: action })
  }

  return result
}

function injectTemporalMarkers(items: ChatStreamItem[]): ChatStreamItem[] {
  const result: ChatStreamItem[] = []
  let lastMessageDate: Date | null = null

  for (const item of items) {
    if (item.type === "message" && temporalAnchorRole(item.role) && item.created_at) {
      const messageDate = new Date(item.created_at)
      if (!Number.isNaN(messageDate.getTime())) {
        if (lastMessageDate === null || !sameLocalDay(messageDate, lastMessageDate)) {
          result.push({
            type: "day_divider",
            date: item.created_at,
            label: dayDividerLabel(messageDate)
          })
        }

        if (lastMessageDate === null || messageDate.getTime() - lastMessageDate.getTime() >= 5 * 60 * 1000) {
          result.push({
            type: "timestamp",
            time: messageDate.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }),
            fullDatetime: messageDate.toLocaleString()
          })
        }

        lastMessageDate = messageDate
      }
    }

    result.push(item)
  }

  return result
}

function temporalAnchorRole(role: ChatMessageItem["role"]) {
  return role === "user" || role === "assistant"
}

function sameLocalDay(left: Date, right: Date) {
  return left.getFullYear() === right.getFullYear() && left.getMonth() === right.getMonth() && left.getDate() === right.getDate()
}

function dayDividerLabel(date: Date) {
  const today = startOfLocalDay(new Date())
  const candidate = startOfLocalDay(date)
  const dayDelta = Math.round((today.getTime() - candidate.getTime()) / (24 * 60 * 60 * 1000))

  if (dayDelta === 0) return "Today"
  if (dayDelta === 1) return "Yesterday"

  return date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" })
}

function startOfLocalDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function streamItemMessageIds(item: ChatRenderItem) {
  if (item.type === "message") return [item.id]
  return item.calls.map((call) => call.message_id)
}

function pendingActionCardData(action: ChatPendingAction): ChatPendingActionInline {
  return {
    id: action.id,
    action: action.action || action.action_type,
    state: action.state,
    label: action.label,
    detail: action.detail,
    app_confirm_path: action.app_confirm_path,
    app_reject_path: action.app_reject_path
  }
}

function renderMessage(message: ChatMessageItem): ChatRenderItem | null {
  if (message.role === "system") {
    const system = systemMessage(message)
    if (system === null) return null

    return { ...message, system }
  }

  if (message.role === "tool_use" || message.role === "tool_result") {
    return { ...message, tool: structuredTool(message) }
  }

  return message
}

function groupableToolUse(message: ChatMessageItem) {
  return message.role === "tool_use" && Boolean(message.tool_name) && !message.proposal
}

function groupableToolResult(message: ChatMessageItem) {
  return message.role === "tool_result" && !message.proposal
}

function structuredTool(message: ChatMessageItem): ChatStructuredTool {
  const content = contentRecord(message.content)
  const name = message.tool_name || stringValue(content?.name) || message.role
  const proposal = message.proposal

  return {
    name,
    payload: content || { content: message.content ?? message.text },
    proposal_id: proposal?.id || null,
    proposal_state_label: proposal?.state === "proposed" ? "pending" : proposal?.state || null
  }
}

function systemMessage(message: ChatMessageItem): ChatSystemMessage | null {
  const text = message.text || stringValue(contentRecord(message.content)?.text) || ""
  const mcpHealth = mcpHealthFromContent(message.content)
  if (mcpHealth.length > 0) return structuredMcpMessage(mcpHealth)

  const result = text.match(/^\[(?:codex )?result\]\s+(.+)$/)
  if (result) return systemResultMessage(parseSystemFields(result[1]))

  const mcp = text.match(/^\[mcp_servers\]\s+(.+)$/)
  if (mcp) return systemMcpMessage(mcp[1])

  const codexError = text.match(/^\[codex error\]\s+(.+)$/)
  if (codexError) return { tone: "error", label: "Error", body: codexError[1] }

  if (text.startsWith("Claude authentication failed.")) {
    return {
      tone: "error",
      label: "Claude auth",
      body: text,
      cta: { label: "Open Credentials", path: "/credentials" }
    }
  }

  return { tone: "neutral", label: "System", body: text }
}

function structuredMcpMessage(servers: ChatMcpHealth[]): ChatSystemMessage | null {
  const unavailable = servers.filter((server) => server.unavailable_tools.length > 0)

  if (unavailable.length > 0) {
    return {
      tone: "warning",
      label: "MCP unavailable",
      body: `MCP unavailable: ${serverStatusList(unavailable)}. Tools unavailable: ${toolSummary(unavailable, "unavailable_tools")}. Retry the turn or check the chat sidecar logs before asking the agent to persist proposals, schedules, bookmarks, or whiteboard edits.`
    }
  }

  return null
}

function serverStatusList(servers: ChatMcpHealth[]) {
  return servers.map((server) => `${server.name} ${server.status || "unknown"}`).join(", ")
}

function toolSummary(servers: ChatMcpHealth[], key: "available_tools" | "pending_tools" | "unavailable_tools") {
  const names = Array.from(new Set(servers.flatMap((server) => server[key] || [])))
  if (names.length === 0) return "none reported"
  if (names.length <= 4) return names.join(", ")

  return `${names.slice(0, 4).join(", ")} +${names.length - 4} more`
}

function mcpHealthFromContent(content: unknown): ChatMcpHealth[] {
  const raw = contentRecord(content)?.mcp_health
  if (!Array.isArray(raw)) return []

  return raw.map((item) => {
    const record = contentRecord(item)
    if (!record) return null

    return {
      name: stringValue(record.name),
      status: stringValue(record.status) || "unknown",
      available_tools: stringArray(record.available_tools),
      pending_tools: stringArray(record.pending_tools),
      unavailable_tools: stringArray(record.unavailable_tools)
    }
  }).filter((item): item is ChatMcpHealth => item != null && item.name.length > 0)
}

function stringArray(value: unknown) {
  return Array.isArray(value) ? value.map(stringValue).filter(Boolean) : []
}

function systemResultMessage(fields: Record<string, string>): ChatSystemMessage {
  const error = fields.is_error === "true"
  const subtype = fields.subtype || ""
  const body = [systemResultTitle(error, subtype)]
  if (fields.turns) body.push(`${Number.parseInt(fields.turns, 10)} ${Number.parseInt(fields.turns, 10) === 1 ? "turn" : "turns"}`)
  if (fields.duration_ms) body.push(systemDurationLabel(fields.duration_ms))
  if (fields.total_cost_usd) body.push(formatCurrency(Number.parseFloat(fields.total_cost_usd), 2))

  return { tone: error ? "error" : "success", label: error ? "Failed" : "Done", body: body.join(" · ") }
}

function systemResultTitle(error: boolean, subtype: string) {
  if (error) return `Agent run failed${subtype && subtype !== "success" ? `: ${humanize(subtype)}` : ""}`
  if (subtype === "success") return "Agent run succeeded"

  return subtype ? `Agent run finished: ${humanize(subtype)}` : "Agent run finished"
}

function systemMcpMessage(payload: string): ChatSystemMessage {
  const servers = payload.split(/\s*,\s*/).map((entry) => {
    const [name, status] = entry.split("=", 2)
    return name ? [name, status || "unknown"] : null
  }).filter((entry): entry is [string, string] => entry != null)
  const ready = new Set(["connected", "running", "ready"])
  const transient = new Set(["pending"])
  const pending = servers.filter(([, status]) => transient.has(status))
  const failing = servers.filter(([, status]) => !ready.has(status) && !transient.has(status))

  if (servers.length === 0) return { tone: "neutral", label: "MCP", body: "MCP server status unavailable" }
  if (failing.length > 0) return { tone: "warning", label: "MCP", body: `MCP issue: ${failing.map(([name, status]) => `${name} ${status}`).join(", ")}` }
  if (pending.length > 0) return { tone: "neutral", label: "MCP", body: `MCP starting: ${pending.map(([name]) => name).join(", ")}` }

  return { tone: "success", label: "Connected", body: `MCP connected: ${servers.map(([name]) => name).join(", ")}` }
}

function parseSystemFields(payload: string) {
  return Object.fromEntries(Array.from(payload.matchAll(/(\w+)=([^,\s]+)/g), (match) => [match[1], match[2]]))
}

function systemDurationLabel(durationMs: string) {
  const seconds = Number.parseFloat(durationMs) / 1000
  if (seconds < 60) return `${Math.round(seconds * 10) / 10}s`

  const minutes = seconds / 60
  if (minutes < 10) return `${Math.round(minutes * 10) / 10}m`

  return `${Math.round(minutes)}m`
}

function toolLabel(name: string) {
  return name.startsWith("mcp__") ? name.split("__", 3).at(-1) || name : name
}

function PencilIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  )
}

function UploadIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M12 3v12" />
      <path d="m7 8 5-5 5 5" />
      <path d="M5 21h14" />
    </svg>
  )
}

const WORKSPACE_ROOT_PATTERN = /(?:\/[^\s'"`,:;\])}]+)+\/\.syrus\/(?:chat-workspaces\/\d+\/repositories\/[^/\s'"`,:;\])}]+\/[^/\s'"`,:;\])}]+|workflows\/\d+)\/?/g
const COUNTED_RESULT_TOOLS = new Set(["Read", "Glob", "Grep"])
const RESULT_SUMMARY_LINE_THRESHOLD = 8

function toolDetail(name: string, input: Record<string, unknown>) {
  let detail = ""

  switch (name) {
    case "Bash":
      detail = firstLine(stringValue(input.command))
      break
    case "Read":
    case "Edit":
    case "Write":
      detail = stringValue(input.file_path)
      break
    case "NotebookEdit":
      detail = stringValue(input.notebook_path)
      break
    case "Glob":
      detail = stringValue(input.pattern)
      break
    case "Grep": {
      const base = stringValue(input.pattern)
      const path = stringValue(input.path)
      detail = path ? `${base} in ${path}` : base
      break
    }
    case "WebFetch":
      detail = stringValue(input.url)
      break
    case "WebSearch":
      detail = stringValue(input.query)
      break
    case "TodoWrite":
      detail = `${Array.isArray(input.todos) ? input.todos.length : 0} item(s)`
      break
    case "Task":
    case "Agent":
      detail = stringValue(input.description) || firstLine(stringValue(input.prompt))
      break
    case "ToolSearch":
      detail = stringValue(input.query)
      break
    default:
      if (name.startsWith("mcp__")) {
        const candidate = Object.values(input).find((value) => typeof value === "string" && value.length > 0)
        detail = firstLine(stringValue(candidate))
        break
      }

      detail = firstLine(JSON.stringify(input))
  }

  return shortenWorkspacePaths(detail)
}

function shortenWorkspacePaths(value: string) {
  return value.replace(WORKSPACE_ROOT_PATTERN, (match) => match.endsWith("/") ? "" : ".")
}

function toolResultSummary(name: string, body: string) {
  if (!COUNTED_RESULT_TOOLS.has(name)) return ""

  const lines = body.split(/\r?\n/).filter((line) => line.trim().length > 0)
  if (lines.length <= RESULT_SUMMARY_LINE_THRESHOLD) return ""

  const noun = name === "Glob" ? "path" : name === "Grep" ? "match" : "line"
  return `${lines.length} ${noun}${lines.length === 1 ? "" : "s"}`
}

function fullResultBody(content: unknown): string {
  if (typeof content === "string") return shortenWorkspacePaths(content)
  if (Array.isArray(content)) {
    return content.map((item) => {
      const record = contentRecord(item)
      if (record?.type === "text") return shortenWorkspacePaths(stringValue(record.text))
      if (record?.type === "tool_reference") return `-> ${stringValue(record.tool_name)}`
      return ""
    }).filter(Boolean).join("\n")
  }
  if (content == null) return "(empty)"

  return String(content)
}

function contentInput(content: unknown) {
  return contentRecord(contentRecord(content)?.input) || {}
}

function contentRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null
}

function firstLine(value: string) {
  return value.split(/\r?\n/, 1)[0].trim()
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : value == null ? "" : String(value)
}

function humanize(value: string) {
  const normalized = value.replace(/_id$/, "").replace(/_/g, " ").toLowerCase()
  return normalized ? normalized[0].toUpperCase() + normalized.slice(1) : ""
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function numericArg(value: string) {
  const match = value.trim().match(/^\d+$/)
  return match ? match[0] : null
}

function findProposalBySlug(payload: ChatPayload, slug: string): { app_reject_path: string } | null {
  const normalized = slug.trim().toLowerCase()
  if (!normalized) return null

  for (const message of payload.messages) {
    const proposal = message.proposal
    if (!proposal) continue
    if (proposal.slug.toLowerCase() === normalized) return proposal

    const child = proposal.children?.find((item) => item.slug.toLowerCase() === normalized)
    if (child) return child
  }

  return null
}

function scrollToLastProposalCard() {
  const messages = Array.from(document.querySelectorAll<HTMLElement>('[id^="chat_message_"]'))
  const target = messages.filter((message) => message.querySelector("[data-proposal-card]")).at(-1)
  if (!target) return false

  target.scrollIntoView({ behavior: "smooth", block: "start" })
  return true
}

function isPlainAnchorClick(event: ReactMouseEvent<HTMLAnchorElement>) {
  return event.button === 0 && !event.defaultPrevented && !event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey
}

function mergeChatMessages(...groups: ChatMessageItem[][]) {
  const seen = new Set<string>()
  const messages: ChatMessageItem[] = []

  for (const item of groups.flat()) {
    const key = String(item.id)
    if (seen.has(key)) continue

    seen.add(key)
    messages.push(item)
  }

  return messages
}

function renderItemKey(item: ChatStreamItem) {
  if (item.type === "timestamp") return `timestamp-${item.fullDatetime}`
  if (item.type === "day_divider") return `day-divider-${item.date}`
  if (item.type === "pending_action") return `pending-action-${item.pendingAction.id}`
  if (item.type === "message") return `message-${item.id}`

  return `tool-${item.calls.map((call) => call.message_id).join("-")}`
}

function chatStreamItemsSignature(items: ChatStreamItem[]) {
  return items.map((item) => {
    if (item.type === "timestamp") return `${renderItemKey(item)}:${item.time}`
    if (item.type === "day_divider") return `${renderItemKey(item)}:${item.label}`
    if (item.type === "pending_action") return `${renderItemKey(item)}:${item.pendingAction.state}:${item.pendingAction.label.length}:${item.pendingAction.detail?.length || 0}`
    if (item.type === "message") return `${renderItemKey(item)}:${item.text.length}`

    return `${renderItemKey(item)}:${item.calls.map((call) => `${call.message_id}:${call.result_body.length}`).join(",")}`
  }).join("|")
}

function oldestMessageId(messages: ChatMessageItem[]) {
  const ids = messages.map((message) => message.id)
  return ids.length > 0 ? Math.min(...ids) : null
}

function maxMessageId(messages: ChatMessageItem[]) {
  const ids = messages.map((message) => message.id)
  return ids.length > 0 ? Math.max(...ids) : null
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}

function errorAsError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error))
}
