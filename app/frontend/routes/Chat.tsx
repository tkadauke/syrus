import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Markdown } from "../lib/Markdown"
import type { Step } from "react-joyride"
import type { CSSProperties, FormEvent, KeyboardEvent, MouseEvent as ReactMouseEvent, UIEvent } from "react"
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import { NoticeToast } from "../components/NoticeToast"
import { refreshRecentChats } from "../lib/chatCache"
import { answerAgentQuestion, fetchChat, fetchChatMessages, fetchSharedChat, markChatRead, cancelCodingCheckout, type ChatAgentQuestion, type ChatBookmark, type ChatMessageItem, type ChatPayload, type SharedChatPayload } from "../api/chats"
import { fetchBootstrap, readInitialBootstrap } from "../api/bootstrap"
import { CloseIcon } from "../components/CloseIcon"
import { GearIcon } from "../components/GearIcon"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"
import { type ChatQueryKey, CHAT_WORKSPACE_COLLAPSED_KEY, CHAT_WORKSPACE_MIN_WIDTH, CHAT_WORKSPACE_TAB_KEY, CHAT_WORKSPACE_WIDTH_KEY } from "./chat/constants"
import { findChatMessageAnchor, isMessageStreamAtBottom, isMessageStreamNearTop, messageIdFromHash, messageStreamNeedsOlderMessages, scrollChatMessageIntoView, scrollMessageStreamToBottom } from "./chat/messageStream"
import { appendSearch, visualViewportHeight, chatDisplayTitle, codingFilesTabVisible, jobsTabVisible, primaryButton, secondaryButton, withRoutePrefix } from "./chat/utils"
import { PendingActionCard } from "./chat/ProposalCards"
import { ChatMessage, shouldAnimateMessageEntrance, ToolGroup } from "./chat/MessageCards"
import { AgentActivityIndicator, DayDivider, MessageTimestamp, SwitchingProviderIndicator, SystemMessagesToggle } from "./chat/streamChrome"
import { Compose } from "./chat/Compose"
import { routePrefix, ChatSettingsDialog, ChatWorkspacePanel, PanelMessage, UsageOverlay } from "./chat/WorkspacePanels"
import type { ChatSystemCommandHandlers } from "./chat/composeTypes"
import { chatStreamItemsSignature, maxMessageId, mergeChatMessages, oldestMessageId, renderItemKey } from "./chat/messageStreamItems"
import { buildMessageStreamItems, injectTemporalMarkers, pendingActionCardData, renderChatMessages } from "./chat/streamBuilders"
import type { MobileChatTab, WorkspaceTab } from "./chat/workspaceTabs"
import { countIncomingVisibleMessages, isAgentActive, isLowPrioritySystemMessage } from "./chat/messageDisplay"
import { clampWorkspaceWidth, defaultWorkspaceTab, mobileChatTabLabel, storeWorkspacePreference, storedWorkspaceCollapsed, storedWorkspaceTab, storedWorkspaceWidth, workspaceTabClass } from "./chat/workspaceTabs"
import { SyrusTour } from "../components/SyrusTour"
import { useTour } from "../hooks/useTour"



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
      className="mx-auto flex h-full max-w-[96rem] flex-col gap-2 overflow-hidden p-3 sm:gap-6 sm:p-6"
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

export function chatQueryKey(id: string | number, search: string): ChatQueryKey {
  return ["chats", String(id), search] as const
}

type BookmarkTarget = {
  messageId: number
  requestId: number
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
        <nav aria-label={t("aria_mobile_tabs")} className="flex shrink-0 overflow-x-auto border-b border-gray-200 px-2 pt-2 text-sm font-medium dark:border-gray-700">
          {(["chat", "whiteboard", "context", "media", ...(codingFilesTabVisible(payload) ? (["files"] as MobileChatTab[]) : []), ...(payload.local_tunnel_connected ? (["diff"] as MobileChatTab[]) : []), ...(jobsTabVisible(payload) ? (["jobs"] as MobileChatTab[]) : [])] as MobileChatTab[]).map((tab) => (
            <button
              className={workspaceTabClass(activeMobileTab === tab)}
              key={tab}
              onClick={() => selectMobileTab(tab)}
              type="button"
            >
              {mobileChatTabLabel(tab, t)}
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
      target: '[data-tour="chat-message-list"]',
      title: t("chat.step_messages_title"),
      content: t("chat.step_messages_content"),
      placement: "top",
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

function ChatColumn({ bookmarkTarget, chatId, commandHandlers, payload, prefix, queryKey, onNotice }: { bookmarkTarget: BookmarkTarget | null; chatId: string; commandHandlers: ChatSystemCommandHandlers; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const [hasSentFirstMessage, setHasSentFirstMessage] = useState(false)
  const { t } = useT("chat")
  const landing = payload.messages.length === 0 && payload.pending_actions.length === 0 && !hasSentFirstMessage

  useEffect(() => {
    setHasSentFirstMessage(false)
  }, [payload.chat.id])

  return (
    <section className={`flex min-h-0 min-w-0 flex-1 flex-col transition-all duration-500 ${landing ? "items-center justify-center gap-6 px-4" : "gap-3"}`}>
      <ChatTour />
      {landing ? (
        <h1 className="text-center text-3xl font-semibold tracking-normal text-gray-950 sm:text-4xl dark:text-gray-100">{t("landing_prompt")}</h1>
      ) : null}
      {payload.local_mode_enabled && payload.chat.mode === "local" ? (
        <LocalDaemonBanner payload={payload} />
      ) : null}
      <div className={`relative min-h-0 overflow-hidden rounded border border-gray-200 bg-white transition-all duration-500 ease-out dark:border-gray-700 dark:bg-gray-950 ${landing ? "h-0 w-full max-w-2xl opacity-0" : "flex-1 opacity-100"}`} data-tour="chat-message-list">
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
  const { t } = useT("chat")
  return (
    <section aria-label={t("aria_agent_questions")} className="w-full max-w-3xl space-y-3 rounded border border-blue-200 bg-blue-50 p-3 dark:border-blue-800 dark:bg-blue-950/60">
      {questions.map((question) => <AgentQuestionPrompt key={question.id} question={question} queryKey={queryKey} onNotice={onNotice} />)}
    </section>
  )
}

function AgentQuestionPrompt({ question, queryKey, onNotice }: { question: ChatAgentQuestion; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
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
      <Markdown className="font-medium text-gray-900 dark:text-gray-100" text={question.question} />
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
          aria-label={t("aria_custom_answer")}
          className="min-h-9 flex-1 rounded border border-gray-300 px-3 py-2 text-base focus:border-blue-500 focus:ring-blue-500 sm:text-sm dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100"
          disabled={submit.isPending}
          onChange={(event) => setAnswer(event.target.value)}
          placeholder={t("ph_custom_response")}
          value={answer}
        />
        <button className={primaryButton()} disabled={submit.isPending || answer.trim().length === 0} type="submit">{t("submit")}</button>
      </form>
      <button className={`${secondaryButton()} flex w-full justify-start text-left`} disabled={submit.isPending} onClick={declineAnswer} type="button">
        {t("decline_to_answer")}
      </button>
    </div>
  )
}

