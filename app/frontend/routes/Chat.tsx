import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { PageHeading, SectionHeading } from "../components/Heading"
import type { Step } from "react-joyride"
import type { CSSProperties, KeyboardEvent, MouseEvent as ReactMouseEvent, MutableRefObject, ReactNode, UIEvent } from "react"
import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { ProviderAvailabilityWarning } from "../components/ProviderAvailabilityWarning"
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
  attachChatRepository,
  branchChat,
  clearChatHistory,
  confirmChatProposal,
  confirmPendingAction,
  createChat,
  createChatBookmark,
  createChatTopicBookmark,
  createLocalDaemonSession,
  createScratchpadItem,
  deleteScratchpadItem,
  deleteQueuedChatMessage,
  deleteChatAttachment,
  enqueueChatMessage,
  reorderScratchpadItems,
  updateScratchpadItem,
  fetchChat,
  fetchChatBookmarks,
  fetchChatMessages,
  fetchSharedChat,
  markChatRead,
  rejectChatProposal,
  rejectPendingAction,
  renameChat,
  searchChatEpics,
  searchChatJobs,
  searchChatProposals,
  sendChatMessage,
  shareChat,
  stopChat,
  cancelCodingCheckout,
  updateChatProposal,
  updateChatPinned,
  updateQueuedChatMessage,
  type ChatAttachmentResult,
  type ChatMode,
  type ChatAttachmentRow,
  type ChatBranchPayload,
  type ChatBookmark,
  type ChatMessageAttachmentInput,
  type ChatCreatedPayload,
  type ChatMcpHealth,
  type ChatNavRecord,
  type ChatEpicDependencySearchResult,
  type ChatJobDependencySearchResult,
  type ChatMediaImage,
  type ChatMediaPayload,
  type ChatMediaSnapshot,
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
  type ChatToolGroupItem,
  type ShareChatPayload,
  type SharedChatPayload,
} from "../api/chats"
import { fetchBootstrap, readInitialBootstrap } from "../api/bootstrap"
import { CloseIcon } from "../components/CloseIcon"
import { GearIcon } from "../components/GearIcon"
import { PinIcon } from "../components/PinIcon"
import { newestPins, useChatPins, useHasPins } from "./chat/pins"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { errorMessage } from "../lib/errorMessage"
import { type ChatQueryKey, CHAT_WORKSPACE_COLLAPSED_KEY, CHAT_WORKSPACE_MIN_WIDTH, CHAT_WORKSPACE_TAB_KEY, CHAT_WORKSPACE_WIDTH_KEY } from "./chat/constants"
import { findChatMessageAnchor, isMessageStreamAtBottom, isMessageStreamNearTop, messageIdFromHash, messageStreamNeedsOlderMessages, scrollChatMessageIntoView, scrollMessageStreamToBottom } from "./chat/messageStream"
import { appendSearch, visualViewportHeight, chatDisplayTitle, currentRecentChat, formatCurrency, formatTokenCount, isSupervisorChat, withRoutePrefix } from "./chat/utils"
import { PendingActionCard } from "./chat/ProposalCards"
import { AgentQuestions } from "./chat/AgentQuestions"
import { GroupChatParticipants } from "./chat/GroupChatParticipants"
import { ChatMessage, shouldAnimateMessageEntrance, ToolGroup } from "./chat/MessageCards"
import { AgentActivityIndicator, DayDivider, MessageTimestamp, SwitchingProviderIndicator, SystemMessagesToggle } from "./chat/streamChrome"
import { Compose } from "./chat/Compose"
import { ThemePreviewModal } from "./chat/ThemePreviewModal"
import { routePrefix } from "../lib/routing"
import type { ChatSystemCommandHandlers } from "./chat/composeTypes"
import { chatStreamItemsSignature, maxMessageId, mergeChatMessages, mergeMessageTail, oldestMessageId, renderItemKey } from "./chat/messageStreamItems"
import { buildMessageStreamItems, injectTemporalMarkers, pendingActionCardData, renderChatMessages } from "./chat/streamBuilders"
import type { MobileChatTab, WorkspaceTab } from "./chat/workspaceTabs"
import { countIncomingVisibleMessages, isAgentActive, isLowPrioritySystemMessage, retryTextByMessageId } from "./chat/messageDisplay"
import { availableWorkspaceTabs, clampWorkspaceWidth, defaultWorkspaceTab, mobileChatTabLabel, storeWorkspacePreference, storedWorkspaceCollapsed, storedWorkspaceTab, storedWorkspaceWidth, workspaceTabClass } from "./chat/workspaceTabs"
import { SyrusTour } from "../components/SyrusTour"
import { useTour } from "../hooks/useTour"
import { useChatControlsRefetchOnReconnect } from "../hooks/useChatControlsRefetchOnReconnect"

const ChatWorkspacePanel = lazy(() => import("./chat/WorkspacePanels").then((module) => ({ default: module.ChatWorkspacePanel })))
const ChatSettingsDialog = lazy(() => import("./chat/WorkspacePanels").then((module) => ({ default: module.ChatSettingsDialog })))

function UsageOverlay({ payload }: { payload: ChatPayload }) {
  return (
    <p className="pointer-events-none absolute left-0 right-0 top-0 border-b border-gray-100 bg-white/95 px-4 py-1.5 text-xs text-gray-500 dark:border-gray-800 dark:bg-gray-950/95 dark:text-gray-400">
      Tokens: {formatTokenCount(payload.chat.cumulative_input_tokens)} in / {formatTokenCount(payload.chat.cumulative_output_tokens)} out · {formatCurrency(payload.chat.cumulative_cost_usd)}
    </p>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-800 dark:bg-green-950 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

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
    queryFn: async () => {
      const fetched = await fetchChat(id, location.search)
      const cached = queryClient.getQueryData<ChatPayload>(queryKey)
      if (!cached || !Array.isArray(cached.messages)) return fetched

      return { ...fetched, messages: mergeMessageTail(cached.messages, fetched.messages) }
    },
    enabled: id.length > 0,
    refetchInterval: 30_000,
    placeholderData: (previousData, previousQuery) => (
      previousQuery?.queryKey[0] === "chats" && previousQuery.queryKey[1] === id ? previousData : undefined
    )
  })

  useChatControlsRefetchOnReconnect(id)

  usePageTitle(chat.isSuccess ? chatDisplayTitle(chat.data.chat) : undefined)

  useEffect(() => {
    if (!id) return

    void markChatRead(id).then(() => {
      refreshRecentChats(queryClient)
    }).catch(() => undefined)
  }, [id, queryClient])

  return (
    <main
      aria-label={t("aria_chat")}
      className="relative mx-auto flex h-full max-w-[96rem] flex-col gap-2 overflow-hidden p-2 sm:gap-6 sm:p-6 lg:[height:100%]"
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
  usePageTitle(chat.isSuccess ? (chat.data.chat.title || undefined) : undefined)

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
        <PageHeading className="break-words">{payload.chat.title || t("shared_chat_fallback_title")}</PageHeading>
        <span className="rounded border border-brand/30 bg-brand/10 px-3 py-1 text-sm font-medium text-brand">{t("view_only")}</span>
      </header>
      <section className="min-h-0 flex-1 overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-950">
        <ReadOnlyMessageStream payload={payload} />
      </section>
    </div>
  )
}

function ReadOnlyMessageStream({ payload }: { payload: SharedChatPayload }) {
  const simpleMode = useSimpleMode()
  const items = useMemo(() => renderChatMessages(payload.messages, { simpleMode }), [payload.messages, simpleMode])
  const placeholderPayload = useMemo(() => sharedChatRenderPayload(payload), [payload])
  const pendingActionIds = useMemo(() => new Set<number>(), [])
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
        <ToolGroup item={item} key={renderItemKey(item)} simpleMode={simpleMode} />
      ) : (
        <ChatMessage item={item} key={renderItemKey(item)} payload={placeholderPayload} pendingActionIds={pendingActionIds} prefix="" queryKey={chatQueryKey(payload.chat.id, "")} readOnly onNotice={() => undefined} />
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
    preview_panels: [],
    workspace_tabs: [],
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
      app_scheduled_messages_path: "",
      app_stop_path: "",
      app_daemon_connection_path: "",
      app_switch_provider_path: "",
      app_bookmarks_path: "",
      app_attachments_path: "",
      app_video_walkthroughs_path: "",
      app_whiteboard_path: "",
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

export function chatQueryKey(id: string | number, search: string): ChatQueryKey {
  return ["chats", String(id), search] as const
}

type BookmarkTarget = {
  messageId: number
  requestId: number
}

function ChatView({ chatId, payload, prefix, queryKey }: { chatId: string; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey }) {
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { t } = useT("chat")

  const title = chatDisplayTitle(payload.chat)

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-2 lg:gap-6">
      {!isDesktop ? null : (
        <header className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className={`flex min-w-0 items-center gap-2 break-words text-3xl font-semibold ${payload.chat.title_pending ? "animate-pulse text-gray-400 dark:text-gray-500" : "text-gray-900 dark:text-gray-100"}`}>
              <span className="min-w-0 break-words">{title}</span>
              <ProviderAvailabilityWarning availability={payload.chat.provider_availability} className="mt-1" />
            </h1>
            {payload.local_mode_enabled && payload.chat.mode === "local" && payload.chat.local_daemon_state === "connected" ? (
              <div className="mt-1 flex items-center gap-1.5 text-sm text-emerald-700 dark:text-emerald-400">
                <span aria-hidden="true" className="h-2 w-2 rounded-full bg-emerald-500" />
                <span>{t("local_daemon_connected", { repo: payload.chat.local_daemon_repo ?? "", branch: payload.chat.local_daemon_branch ?? "" })}</span>
              </div>
            ) : null}
            {payload.chat.conversation_kind === "group" ? (
              <GroupChatParticipants payload={payload} prefix={prefix} queryKey={queryKey} onNotice={setNotice} />
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
          settingsOpen={settingsOpen}
          onSettingsOpenChange={setSettingsOpen}
        />
      )}

      <ThemePreviewModal chatId={chatId} prefix={prefix} />
    </div>
  )
}

type OlderMessageRequester = (options: { preserveScroll: boolean }) => boolean

function MessageStream({ bookmarkTarget, olderMessageRequesterRef, onCanLoadOlderChange, payload, prefix, queryKey, onNotice }: { bookmarkTarget: BookmarkTarget | null; olderMessageRequesterRef?: MutableRefObject<OlderMessageRequester | null>; onCanLoadOlderChange?: (canLoad: boolean) => void; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const location = useLocation()
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const simpleMode = useSimpleMode()
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
  const displayedMessages = useMemo(() => mergeChatMessages(olderMessages, payload.messages), [olderMessages, payload.messages])
  const displayedItems = useMemo(() => renderChatMessages(displayedMessages, { simpleMode }), [displayedMessages, simpleMode])
  const agentQuestions = payload.agent_questions || []
  const hiddenSystemMessageCount = useMemo(() => displayedItems.filter(isLowPrioritySystemMessage).length, [displayedItems])
  const visibleItems = useMemo(() => showSystemMessages ? displayedItems : displayedItems.filter((item) => !isLowPrioritySystemMessage(item)), [displayedItems, showSystemMessages])
  const pendingActionIds = useMemo(() => new Set(payload.pending_actions.map((action) => action.id)), [payload.pending_actions])
  const streamItems = useMemo(() => injectTemporalMarkers(buildMessageStreamItems(visibleItems, payload.pending_actions)), [visibleItems, payload.pending_actions])
  const agentActive = isAgentActive(payload)
  const oldestId = oldestMessageId(displayedMessages)
  const payloadMessageIdsSignature = payload.messages.map((message) => message.id).join("|")
  const visibleItemsSignature = chatStreamItemsSignature(streamItems)
  const retryTextMap = useMemo(() => retryTextByMessageId(displayedMessages), [displayedMessages])
  const loadOlder = useMutation({
    mutationFn: (before: number) => fetchChatMessages(payload.paths.app_messages_path, before),
    onSuccess: (page) => {
      setOlderMessages((current) => mergeChatMessages(page.messages, current))
      setHasMoreOlder(page.has_more_older)
    }
  })
  const retryTurn = useMutation({
    mutationFn: (messageText: string) => agentActive
      ? enqueueChatMessage(appendSearch(payload.paths.app_enqueue_message_path, search), messageText)
      : sendChatMessage(appendSearch(payload.paths.app_message_path, search), messageText),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, currentRecentChat(updated) || updated.chat, { prepend: true })
      onNotice(null)
    },
    onError: (error) => onNotice(errorMessage(error, "Retry failed."))
  })

  const scrollToBottom = useCallback(() => {
    scrollMessageStreamToBottom(streamRef.current, { smooth: true })
    atBottomRef.current = true
    setNewMessageCount(0)
  }, [])

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

  useEffect(() => {
    if (!olderMessageRequesterRef) return

    olderMessageRequesterRef.current = requestOlderMessages
    return () => {
      if (olderMessageRequesterRef.current === requestOlderMessages) olderMessageRequesterRef.current = null
    }
  }, [olderMessageRequesterRef, requestOlderMessages])

  useEffect(() => {
    onCanLoadOlderChange?.(hasMoreOlder && oldestId != null && !loadOlder.isPending)
  }, [hasMoreOlder, loadOlder.isPending, oldestId, onCanLoadOlderChange])

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
          <div>{isSupervisorChat(payload) ? t("empty_supervisor") : payload.chat.repository ? t("empty_with_repo") : t("empty_without_repo")}</div>
          {payload.switching_provider ? <SwitchingProviderIndicator provider={payload.chat.chat_provider ?? ""} /> : agentActive ? <AgentActivityIndicator running={payload.agent_busy} /> : null}
        </div>
        {agentQuestions.length > 0 ? <AgentQuestions questions={agentQuestions} queryKey={queryKey} onNotice={onNotice} /> : null}
      </div>
    )
  }

  return (
    <div className="relative h-full min-h-0">
      {
        // pb-* used to be a static guess sized for the composer's default
        // height. `--chat-composer-height` (set by ChatColumn from Compose's
        // ResizeObserver) tracks its actual rendered height, so typed lines,
        // attachment rows, etc. that grow the composer keep pushing this
        // padding down instead of letting the composer paint over history
        // that scrolling can't reveal. max() with the old static values
        // keeps the default (pre-measurement, or composer shorter than
        // assumed) case unchanged.
      }
      <div className="h-full min-h-0 space-y-4 overflow-y-auto overscroll-contain p-2 pt-12 pb-[max(7rem,calc(var(--chat-composer-height,0px)+1.5rem))] sm:p-4 sm:pt-12 sm:pb-[max(8rem,calc(var(--chat-composer-height,0px)+2rem))]" data-testid="chat-message-stream" onScroll={handleScroll} ref={streamRef}>
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
          <ToolGroup item={item} key={renderItemKey(item)} simpleMode={simpleMode} />
        ) : (
          <ChatMessage
            animateIn={shouldAnimateMessageEntrance(item.id, entranceBaselineMessageIdRef.current)}
            item={item}
            key={renderItemKey(item)}
            payload={payload}
            pendingActionIds={pendingActionIds}
            prefix={prefix}
            queryKey={queryKey}
            retryText={retryTextMap.get(item.id) ?? null}
            retrying={retryTurn.isPending}
            onNotice={onNotice}
            onRetry={(text) => retryTurn.mutate(text)}
          />
        ))}
        {agentQuestions.length > 0 ? <AgentQuestions questions={agentQuestions} queryKey={queryKey} onNotice={onNotice} /> : null}
        {payload.switching_provider ? <SwitchingProviderIndicator provider={payload.chat.chat_provider ?? ""} /> : agentActive ? <AgentActivityIndicator running={payload.agent_busy} /> : null}
      </div>
      {newMessageCount > 0 ? (
        <button
          className="absolute left-1/2 -translate-x-1/2 rounded-full bg-gray-900 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-gray-800 bottom-[max(6rem,calc(var(--chat-composer-height,0px)+1rem))] sm:bottom-[max(7rem,calc(var(--chat-composer-height,0px)+1rem))] dark:bg-gray-100 dark:text-gray-950 dark:hover:bg-gray-200"
          onClick={scrollToBottom}
          type="button"
        >
          {t("new_messages_button", { count: newMessageCount })}
        </button>
      ) : null}
    </div>
  )
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

function useSimpleMode() {
  const initialBootstrap = readInitialBootstrap()
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: false,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  return bootstrap.data?.app?.mode === "simple"
}


function ChatWorkspace({
  chatId,
  payload,
  prefix,
  queryKey,
  onNotice,
  settingsOpen,
  onSettingsOpenChange
}: {
  chatId: string
  payload: ChatPayload
  prefix: string
  queryKey: ChatQueryKey
  onNotice: (message: string | null) => void
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
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const { t } = useT("chat")
  const simpleMode = useSimpleMode()
  const hasPins = useHasPins(payload.chat.id, queryKey[2])
  const availableTabs = availableWorkspaceTabs(payload, simpleMode, hasPins)

  useEffect(() => {
    if (!availableTabs.includes(activeTab)) setActiveTab(defaultWorkspaceTab(payload, simpleMode))
    if (activeMobileTab !== "chat" && !availableTabs.includes(activeMobileTab)) setActiveMobileTab("chat")
  }, [activeMobileTab, activeTab, availableTabs, payload, simpleMode])

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
    setActiveTab(tab)
  }

  function selectMobileTab(tab: MobileChatTab) {
    setActiveMobileTab(tab)
    if (tab === "chat") return

    selectTab(tab)
  }

  function openPinnedMessages() {
    setPanelCollapsed(false)
    setActiveMobileTab("pinned")
    selectTab("pinned")
  }

  function selectBookmark(messageId: number) {
    setActiveMobileTab("chat")
    bookmarkRequestIdRef.current += 1
    setBookmarkTarget({ messageId, requestId: bookmarkRequestIdRef.current })
  }

  const commandHandlers: ChatSystemCommandHandlers = {
    openBookmarks: () => {
      setBookmarkPickerOpen(true)
    },
    openAttachments: () => {
      if (simpleMode) return
      setActiveTab("context")
      setActiveMobileTab("context")
    },
    openSettings: () => onSettingsOpenChange(true)
  }

  if (!isDesktop) {
    return (
      <div className="flex min-h-0 flex-1 flex-col bg-white dark:bg-gray-950">
        <nav aria-label={t("aria_mobile_tabs")} className="flex min-h-[44px] shrink-0 overflow-x-auto border-b border-gray-200 px-[max(0.5rem,env(safe-area-inset-left))] pt-2 text-sm font-medium dark:border-gray-700">
          {(["chat", ...availableTabs] as MobileChatTab[]).map((tab) => (
            <button
              className={workspaceTabClass(activeMobileTab === tab)}
              key={tab}
              onClick={() => selectMobileTab(tab)}
              type="button"
            >
              {mobileChatTabLabel(tab, t, payload.preview_panels, payload.workspace_tabs)}
            </button>
          ))}
        </nav>
        <div className="flex min-h-0 w-full flex-1">
          {activeMobileTab === "chat" ? (
            <ChatColumn bookmarkTarget={bookmarkTarget} chatId={chatId} commandHandlers={commandHandlers} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} onOpenPinnedMessages={openPinnedMessages} onSelectMessage={selectBookmark} />
          ) : (
            <Suspense fallback={<PanelMessage>{t("loading_chat")}</PanelMessage>}>
              <ChatWorkspacePanel
                activeTab={activeTab}
                showTabs={false}
                onSelectTab={selectTab}
                payload={payload}
                prefix={prefix}
                queryKey={queryKey}
                onNotice={onNotice}
                onBookmarkSelect={selectBookmark}
                simpleMode={simpleMode}
              />
            </Suspense>
          )}
        </div>
        {settingsOpen ? (
          <Suspense fallback={null}>
            <ChatSettingsDialog payload={payload} prefix={prefix} queryKey={queryKey} onClose={() => onSettingsOpenChange(false)} />
          </Suspense>
        ) : null}
        {bookmarkPickerOpen ? <BookmarkPickerModal payload={payload} queryKey={queryKey} onClose={() => setBookmarkPickerOpen(false)} onSelect={selectBookmark} /> : null}
      </div>
    )
  }

  return (
    <div
      className="flex min-h-0 flex-1 flex-col gap-4 lg:grid lg:gap-0"
      style={{
        gridTemplateColumns: panelCollapsed
          ? "minmax(0,1fr) 0 2.5rem"
          : `minmax(0,1fr) 0.5rem minmax(${CHAT_WORKSPACE_MIN_WIDTH}px,${workspaceWidth}px)`,
        transition: "grid-template-columns 150ms ease"
      }}
    >
      <ChatColumn bookmarkTarget={bookmarkTarget} chatId={chatId} commandHandlers={commandHandlers} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} onOpenPinnedMessages={openPinnedMessages} onSelectMessage={selectBookmark} />
      {panelCollapsed ? null : (
        <button
          aria-label={t("resize_workspace")}
          className="hidden cursor-col-resize rounded bg-transparent transition hover:bg-brand/10 focus:bg-brand/10 focus:outline-none lg:block"
          onMouseDown={beginResize}
          type="button"
        />
      )}
      {panelCollapsed ? (
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
      {!panelCollapsed ? (
        <Suspense fallback={<PanelMessage>{t("loading_chat")}</PanelMessage>}>
          <ChatWorkspacePanel
            activeTab={activeTab}
            onSelectTab={selectTab}
            onToggleCollapse={() => setPanelCollapsed(true)}
            payload={payload}
            prefix={prefix}
            queryKey={queryKey}
            onNotice={onNotice}
            onBookmarkSelect={selectBookmark}
            simpleMode={simpleMode}
          />
        </Suspense>
      ) : null}
      {settingsOpen ? (
        <Suspense fallback={null}>
          <ChatSettingsDialog payload={payload} prefix={prefix} queryKey={queryKey} onClose={() => onSettingsOpenChange(false)} />
        </Suspense>
      ) : null}
      {bookmarkPickerOpen ? <BookmarkPickerModal payload={payload} queryKey={queryKey} onClose={() => setBookmarkPickerOpen(false)} onSelect={selectBookmark} /> : null}
    </div>
  )
}

function BookmarkPickerModal({ payload, queryKey, onClose, onSelect }: { payload: ChatPayload; queryKey: ChatQueryKey; onClose: () => void; onSelect: (messageId: number) => void }) {
  const { t } = useT("chat")
  const bookmarksPath = payload.paths.app_bookmarks_index_path || payload.paths.app_bookmarks_path
  const bookmarksQuery = useQuery({
    queryKey: ["chat-bookmarks", String(payload.chat.id), queryKey[2]],
    queryFn: ({ signal }) => fetchChatBookmarks(appendSearch(bookmarksPath, queryKey[2]), { signal }),
    initialData: payload.bookmarks.length > 0 ? { bookmarks: payload.bookmarks } : undefined
  })
  const bookmarks = bookmarksQuery.data?.bookmarks ?? []

  function selectBookmark(bookmark: ChatBookmark) {
    onSelect(bookmark.anchor_message_id ?? bookmark.chat_message_id)
    onClose()
  }

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" onClick={onClose} role="presentation">
      <section aria-labelledby="bookmark-picker-title" aria-modal="true" className="w-full max-w-md rounded border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-900" onClick={(event) => event.stopPropagation()} role="dialog">
        <header className="flex items-center justify-between border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <SectionHeading id="bookmark-picker-title">{t("bookmarks")}</SectionHeading>
          <button
            aria-label={t("close_bookmarks")}
            className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </header>
        <div className="max-h-[min(24rem,calc(100dvh-10rem))] overflow-y-auto p-2">
          {bookmarksQuery.isPending ? (
            <div className="px-2 py-6 text-center text-sm text-gray-500 dark:text-gray-400">{t("loading_bookmarks")}</div>
          ) : bookmarks.length === 0 ? (
            <div className="px-2 py-6 text-center text-sm text-gray-500 dark:text-gray-400">{t("no_bookmarks")}</div>
          ) : (
            <div className="space-y-1">
              {bookmarks.map((bookmark) => (
                <button
                  className="flex w-full items-center gap-3 rounded px-3 py-2 text-left text-sm text-gray-800 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-100 dark:hover:bg-gray-800"
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

export function ChatTour() {
  const { run, handleJoyrideCallback } = useTour("chat")
  const { t } = useT("tours")

  const steps: Step[] = [
    {
      target: '[data-tour="chat-compose"]',
      title: t("chat.step_compose_title"),
      content: t("chat.step_compose_content"),
      placement: "top",
    },
    {
      target: '[data-tour="chat-message-list-top"]',
      title: t("chat.step_messages_title"),
      content: t("chat.step_messages_content"),
      placement: "bottom",
    },
    {
      target: '[data-tour="chat-compose"]',
      title: t("chat.step_slash_title"),
      content: t("chat.step_slash_content"),
      placement: "top",
    },
  ]

  return <SyrusTour steps={steps} run={run} onEvent={(data) => handleJoyrideCallback(data)} />
}

function ChatColumn({ bookmarkTarget, chatId, commandHandlers, payload, prefix, queryKey, onNotice, onOpenPinnedMessages, onSelectMessage }: { bookmarkTarget: BookmarkTarget | null; chatId: string; commandHandlers: ChatSystemCommandHandlers; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void; onOpenPinnedMessages: () => void; onSelectMessage: (messageId: number) => void }) {
  const [hasSentFirstMessage, setHasSentFirstMessage] = useState(false)
  const olderMessageRequesterRef = useRef<OlderMessageRequester | null>(null)
  const [canLoadEarlierMessages, setCanLoadEarlierMessages] = useState(payload.has_more_older)
  // Reported by Compose's own ResizeObserver on its floating form element —
  // exposed as a CSS variable so the message stream's bottom padding and the
  // "new messages" pill (both siblings, not descendants, of Compose) can
  // track the composer's actual rendered height instead of a static guess.
  const [composerHeight, setComposerHeight] = useState<number | null>(null)
  const { t } = useT("chat")
  const landing = payload.messages.length === 0 && payload.pending_actions.length === 0 && !hasSentFirstMessage

  useEffect(() => {
    setHasSentFirstMessage(false)
    setCanLoadEarlierMessages(payload.has_more_older)
  }, [payload.chat.id, payload.has_more_older])

  // Deliberately scoped to chat.id alone (not has_more_older, which this
  // same effect above tracks too): has_more_older can flip mid-session
  // (e.g. after "Load earlier messages") with no composer resize alongside
  // it, so resetting composerHeight on that dep would wipe the tracked
  // height with nothing left to re-measure it — reintroducing the covered
  // history bug this state exists to fix. A real chat switch remounts
  // Compose (key={chatId}), whose own effect re-measures immediately.
  useEffect(() => {
    setComposerHeight(null)
  }, [payload.chat.id])

  const loadEarlierMessagesFromCompose = useCallback(() => olderMessageRequesterRef.current?.({ preserveScroll: false }) ?? false, [])

  return (
    <section
      className={`relative flex min-h-0 min-w-0 flex-1 flex-col transition-all duration-500 ${landing ? "items-center justify-center gap-6 px-4" : "gap-2 sm:gap-3"}`}
      style={composerHeight != null ? { "--chat-composer-height": `${composerHeight}px` } as CSSProperties : undefined}
    >
      <ChatTour />
      {landing ? (
        <h1 className="text-center text-3xl font-semibold tracking-normal text-gray-950 sm:text-4xl dark:text-gray-100">{t("landing_prompt")}</h1>
      ) : null}
      {payload.local_mode_enabled && payload.chat.mode === "local" ? (
        <LocalDaemonBanner payload={payload} />
      ) : null}
      {!landing ? <PinnedMessagesBar payload={payload} queryKey={queryKey} onSelectMessage={onSelectMessage} onViewAll={onOpenPinnedMessages} /> : null}
      <div className={`relative min-h-0 overflow-hidden rounded border border-gray-200 bg-white transition-all duration-500 ease-out dark:border-gray-700 dark:bg-gray-950 ${landing ? "h-0 w-full max-w-2xl opacity-0" : "flex-1 opacity-100"}`} data-tour="chat-message-list">
        <div data-tour="chat-message-list-top" className="absolute inset-x-0 top-0 h-0" />
        <MessageStream bookmarkTarget={bookmarkTarget} olderMessageRequesterRef={olderMessageRequesterRef} payload={payload} prefix={prefix} queryKey={queryKey} onCanLoadOlderChange={setCanLoadEarlierMessages} onNotice={onNotice} />
        <UsageOverlay payload={payload} />
      </div>
      <div className={landing ? "w-full max-w-sm sm:max-w-2xl" : "shrink-0"}>
        {!landing ? <CodingCheckoutBanner payload={payload} queryKey={queryKey} onNotice={onNotice} /> : null}
        <Compose key={chatId} autoFocus={landing} canLoadEarlierMessages={canLoadEarlierMessages} chatId={chatId} commandHandlers={commandHandlers} floating={!landing} onComposerHeightChange={setComposerHeight} onLoadEarlierMessages={loadEarlierMessagesFromCompose} payload={payload} prefix={prefix} queryKey={queryKey} showAttachedRepositories={landing} onNotice={onNotice} onMessageSent={() => setHasSentFirstMessage(true)} />
      </div>
    </section>
  )
}

// Up to the 3 most-recently-pinned messages, newest first, as truncated
// single-line previews. Clicking one reuses the bookmark scroll-to-anchor
// handler (selectBookmark) since navigating to a message is identical for
// bookmarks and pins. "View all" (rendered only when there are more than 3
// pins) opens the full Pinned tab in the workspace panel.
function PinnedMessagesBar({ payload, queryKey, onSelectMessage, onViewAll }: { payload: ChatPayload; queryKey: ChatQueryKey; onSelectMessage: (messageId: number) => void; onViewAll: () => void }) {
  const { t } = useT("chat")
  const search = queryKey[2]
  const pinsQuery = useChatPins(payload.chat.id, search)
  const pins = pinsQuery.data?.pins ?? []

  if (pins.length === 0) return null

  const visible = newestPins(pins, 3)
  const remaining = pins.length - visible.length

  return (
    <div aria-label={t("aria_pinned_messages")} className="flex flex-col gap-0.5 rounded border border-gray-200 bg-gray-50 p-1.5 dark:border-gray-700 dark:bg-gray-900" data-testid="pinned-messages-bar">
      {visible.map((pin) => (
        <button
          className="flex min-w-0 items-center gap-2 rounded px-1.5 py-1 text-left text-xs text-gray-700 hover:bg-white hover:shadow-sm dark:text-gray-300 dark:hover:bg-gray-800"
          key={pin.id}
          onClick={() => onSelectMessage(pin.chat_message_id)}
          type="button"
        >
          <PinIcon className="h-3 w-3 shrink-0 text-brand" />
          <span className="min-w-0 flex-1 truncate">{pin.text || t("pinned_message_empty")}</span>
        </button>
      ))}
      {remaining > 0 ? (
        <button
          className="rounded px-1.5 py-0.5 text-left text-xs font-medium text-brand hover:underline"
          onClick={onViewAll}
          type="button"
        >
          {t("pinned_messages_more", { count: remaining })}
        </button>
      ) : null}
    </div>
  )
}

function LocalDaemonBanner({ payload }: { payload: ChatPayload }) {
  const { t } = useT("chat")
  const { copied, copy } = useCopyToClipboard(2000)

  const daemonState = payload.chat.local_daemon_state ?? null
  const chatId = payload.chat.id

  // Only the "not connected yet" banner needs a pairing session — a
  // previously-connected daemon that dropped ("disconnected") already has
  // one, and a connected daemon doesn't need the command at all.
  const sessionQuery = useQuery({
    queryKey: ["local-daemon-session", chatId],
    queryFn: () => createLocalDaemonSession(chatId),
    enabled: daemonState === null,
    staleTime: Infinity
  })
  const session = sessionQuery.data?.daemon_session
  const command = session?.auth_token
    ? t("local_daemon_command", { chatSessionId: session.chat_session_id, authToken: session.auth_token })
    : null

  function copyCommand() {
    if (!command) return
    copy(command)
  }

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
        <code className="rounded bg-gray-100 px-2 py-1 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">{command ?? t("local_daemon_command_loading")}</code>
        <button
          className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-600 transition hover:bg-gray-50 hover:text-gray-800 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700 dark:hover:text-gray-100 disabled:cursor-not-allowed disabled:opacity-50"
          disabled={!command}
          onClick={copyCommand}
          type="button"
        >
          {copied ? t("local_daemon_copied") : t("local_daemon_copy")}
        </button>
      </div>
      {sessionQuery.isError ? <p className="mt-2 text-red-600 dark:text-red-400">{t("local_daemon_session_error")}</p> : null}
    </section>
  )
}

