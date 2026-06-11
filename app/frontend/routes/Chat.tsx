import { useMutation, useQuery, useQueryClient, type UseMutationResult } from "@tanstack/react-query"
import type { CSSProperties, ErrorInfo, FormEvent, KeyboardEvent, MouseEvent as ReactMouseEvent, ReactNode, UIEvent } from "react"
import { Component, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types"
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import {
  addChatAttachment,
  cancelPendingAction,
  confirmChatProposal,
  confirmPendingAction,
  createChatBookmark,
  deleteChatAttachment,
  fetchChat,
  fetchChatMessages,
  fetchChatWhiteboard,
  patchChatWhiteboard,
  rejectChatProposal,
  sendChatMessage,
  stopChat,
  type ChatAttachmentResult,
  type ChatAttachmentRow,
  type ChatMcpHealth,
  type ChatNavRecord,
  type ChatMessageItem,
  type ChatPendingAction,
  type ChatPayload,
  type ChatProposal,
  type ChatProposalChild,
  type ChatRenderItem,
  type ChatStructuredTool,
  type ChatSystemMessage,
  type ChatWhiteboardElement,
  type ChatWhiteboardScene,
  type ChatToolGroupItem
} from "../api/chats"
import { Markdown } from "../lib/Markdown"

const WHITEBOARD_SAVE_DEBOUNCE_MS = 500
const CHAT_ENTER_SUBMIT_MIN_WIDTH = 1024
const CHAT_BOTTOM_THRESHOLD_PX = 48
const CHAT_TOP_LOAD_THRESHOLD_PX = 96
const CHAT_INITIAL_FILL_MARGIN_PX = 80
const CHAT_COMPOSE_MAX_ROWS = 5
const CHAT_WORKSPACE_WIDTH_KEY = "syrus.chat.workspace.width"
const CHAT_WORKSPACE_TAB_KEY = "syrus.chat.workspace.tab"
const CHAT_WORKSPACE_DEFAULT_WIDTH = 520
const CHAT_WORKSPACE_MIN_WIDTH = 360
const CHAT_WORKSPACE_MAX_WIDTH = 760

type ExcalidrawComponent = typeof import("@excalidraw/excalidraw")["Excalidraw"]
type ExcalidrawApi = Pick<ExcalidrawImperativeAPI, "addFiles" | "updateScene">

export function ChatRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const queryKey = chatQueryKey(id, location.search)
  const prefix = routePrefix(location.pathname)
  const viewportStyle = useChatVisualViewportStyle()
  const chat = useQuery({
    queryKey,
    queryFn: () => fetchChat(id, location.search),
    enabled: id.length > 0
  })

  return (
    <main
      aria-label="Chat"
      className="mx-auto flex h-[calc(var(--chat-visual-viewport-height,100dvh)-4rem)] max-w-[96rem] flex-col gap-6 overflow-hidden p-3 sm:p-6"
      style={viewportStyle}
    >
      {chat.isPending ? <PanelMessage>Loading chat...</PanelMessage> : null}
      {chat.isError ? <PanelMessage tone="error">{errorMessage(chat.error, "Unable to load chat.")}</PanelMessage> : null}
      {chat.isSuccess ? <ChatView payload={chat.data} prefix={prefix} queryKey={queryKey} /> : null}
    </main>
  )
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
type BookmarkTarget = {
  messageId: number
  requestId: number
}

function chatQueryKey(id: string | number, search: string): ChatQueryKey {
  return ["chats", String(id), search] as const
}

function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

function ChatView({ payload, prefix, queryKey }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey }) {
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [whiteboardFullscreen, setWhiteboardFullscreen] = useState(false)
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  const title = payload.chat.title || payload.chat.repository?.slug || "New chat"

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
            <h1 className="break-words text-3xl font-semibold text-gray-900">{title}</h1>
          </div>
        </header>
      )}

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {whiteboardFullscreen ? null : <PendingActions payload={payload} queryKey={queryKey} onNotice={setNotice} />}

      {!payload.chat_available ? (
        <section className="rounded border border-amber-200 bg-white p-6 text-sm text-amber-900">
          <div className="font-semibold">Claude credentials are required.</div>
          <p className="mt-1">Chat uses Claude. Add a Claude OAuth token in <Link className="underline hover:no-underline" to={withRoutePrefix(payload.paths.credentials_path, prefix)}>Credentials</Link> to enable chat.</p>
        </section>
      ) : (
        <ChatWorkspace
          payload={payload}
          prefix={prefix}
          queryKey={queryKey}
          onNotice={setNotice}
          whiteboardFullscreen={whiteboardFullscreen}
          onWhiteboardFullscreenChange={setWhiteboardFullscreen}
        />
      )}
    </div>
  )
}

function PendingActions({ payload, queryKey, onNotice }: { payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const action = useMutation({
    mutationFn: (input: { kind: "confirm" | "cancel"; path: string }) => {
      const path = appendSearch(input.path, search)
      return input.kind === "confirm" ? confirmPendingAction(path) : cancelPendingAction(path)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  if (payload.pending_actions.length === 0) return null

  return (
    <section className="space-y-3 rounded border border-amber-200 bg-amber-50 p-4">
      <h2 className="text-sm font-semibold text-amber-900">Pending actions</h2>
      {payload.pending_actions.map((pendingAction) => (
        <PendingActionRow action={pendingAction} disabled={action.isPending} key={pendingAction.id} onCancel={() => action.mutate({ kind: "cancel", path: pendingAction.app_cancel_path })} onConfirm={() => action.mutate({ kind: "confirm", path: pendingAction.app_confirm_path })} />
      ))}
      {action.isError ? <div className="text-xs text-red-700">{errorMessage(action.error, "Pending action failed.")}</div> : null}
    </section>
  )
}

function PendingActionRow({ action, disabled, onCancel, onConfirm }: { action: ChatPendingAction; disabled: boolean; onCancel: () => void; onConfirm: () => void }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded border border-amber-200 bg-white px-3 py-2 text-sm">
      <div className="font-medium text-gray-900">{action.label}</div>
      <div className="flex gap-2">
        <button className={primaryButton()} disabled={disabled} onClick={onConfirm} type="button">Confirm</button>
        <button className={secondaryButton()} disabled={disabled} onClick={onCancel} type="button">Cancel</button>
      </div>
    </div>
  )
}

function MessageStream({ bookmarkTarget, payload, prefix, queryKey, onNotice }: { bookmarkTarget: BookmarkTarget | null; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const streamRef = useRef<HTMLDivElement | null>(null)
  const atBottomRef = useRef(true)
  const streamChatIdRef = useRef(payload.chat.id)
  const maxPayloadMessageIdRef = useRef(maxMessageId(payload.messages))
  const bookmarkLoadBeforeRef = useRef<number | null>(null)
  const preserveScrollAfterOlderLoadRef = useRef<{ scrollHeight: number; scrollTop: number } | null>(null)
  const [newMessageCount, setNewMessageCount] = useState(0)
  const [olderMessages, setOlderMessages] = useState<ChatMessageItem[]>([])
  const [showSystemMessages, setShowSystemMessages] = useState(false)
  const [hasMoreOlder, setHasMoreOlder] = useState(payload.has_more_older)
  const [activeBookmarkTarget, setActiveBookmarkTarget] = useState<BookmarkTarget | null>(null)
  const displayedMessages = mergeChatMessages(olderMessages, payload.messages)
  const displayedItems = renderChatMessages(displayedMessages)
  const hiddenSystemMessageCount = displayedItems.filter(isLowPrioritySystemMessage).length
  const visibleItems = showSystemMessages ? displayedItems : displayedItems.filter((item) => !isLowPrioritySystemMessage(item))
  const agentActive = isAgentActive(payload)
  const oldestId = oldestMessageId(displayedMessages)
  const payloadMessageIdsSignature = payload.messages.map((message) => message.id).join("|")
  const visibleItemsSignature = chatRenderItemsSignature(visibleItems)
  const loadOlder = useMutation({
    mutationFn: (before: number) => fetchChatMessages(payload.paths.app_messages_path, before),
    onSuccess: (page) => {
      setOlderMessages((current) => mergeChatMessages(page.messages, current))
      setHasMoreOlder(page.has_more_older)
    }
  })

  const scrollToBottom = useCallback(() => {
    scrollMessageStreamToBottom(streamRef.current)
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

  if (displayedItems.length === 0) {
    return (
      <div className="flex h-full min-h-0 flex-col items-center justify-center gap-3 overflow-y-auto p-4 text-sm text-gray-500" data-testid="chat-message-stream">
        <div>{payload.chat.repository ? "Start a chat with this repository." : "Attach a repository to start chatting."}</div>
        {agentActive ? <AgentActivityIndicator running={payload.agent_busy} /> : null}
      </div>
    )
  }

  return (
    <div className="relative h-full min-h-0">
      <div className="h-full min-h-0 space-y-4 overflow-y-auto p-3 pt-12 sm:p-4 sm:pt-12" data-testid="chat-message-stream" onScroll={handleScroll} ref={streamRef}>
        {loadOlder.isPending ? <div className="text-center text-xs text-gray-400">Loading older messages...</div> : null}
        {loadOlder.isError ? <div className="text-center text-xs text-red-700">{errorMessage(loadOlder.error, "Unable to load older messages.")}</div> : null}
        {hiddenSystemMessageCount > 0 ? (
          <SystemMessagesToggle count={hiddenSystemMessageCount} expanded={showSystemMessages} onToggle={() => setShowSystemMessages((value) => !value)} />
        ) : null}
        {visibleItems.map((item) => item.type === "tool_group" ? (
          <ToolGroup item={item} key={renderItemKey(item)} />
        ) : (
          <ChatMessage item={item} key={renderItemKey(item)} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
        ))}
        {agentActive ? <AgentActivityIndicator running={payload.agent_busy} /> : null}
      </div>
      {newMessageCount > 0 ? (
        <button
          className="absolute bottom-4 left-1/2 -translate-x-1/2 rounded-full bg-gray-900 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-gray-800"
          onClick={scrollToBottom}
          type="button"
        >
          {newMessageCount} new {newMessageCount === 1 ? "message" : "messages"}
        </button>
      ) : null}
    </div>
  )
}

function SystemMessagesToggle({ count, expanded, onToggle }: { count: number; expanded: boolean; onToggle: () => void }) {
  return (
    <div className="flex justify-center">
      <button className="rounded-full border border-gray-200 bg-white px-3 py-1 text-xs font-medium text-gray-600 shadow-sm hover:bg-gray-50" onClick={onToggle} type="button">
        {expanded ? "Hide system messages" : `Show ${count} hidden system ${count === 1 ? "message" : "messages"}`}
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

const STARTING_PHRASE = { latin: "Accingitur", english: "girding itself" } as const

function AgentActivityIndicator({ running }: { running: boolean }) {
  const workingPhrase = useMemo(
    () => WORKING_PHRASES[Math.floor(Math.random() * WORKING_PHRASES.length)],
    []
  )
  const phrase = running ? workingPhrase : STARTING_PHRASE

  return (
    <div aria-label={phrase.english} aria-live="polite" className="flex justify-start" role="status">
      <div className="inline-flex items-center gap-2 rounded-full border border-blue-100 bg-blue-50 px-3 py-1.5 text-xs font-medium text-blue-700 shadow-sm">
        <span aria-hidden="true" className="inline-flex items-center gap-1">
          {[0, 1, 2].map((index) => (
            <span
              className="h-1.5 w-1.5 animate-bounce rounded-full bg-blue-500"
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

function ChatMessage({ item, payload, prefix, queryKey, onNotice }: { item: Extract<ChatRenderItem, { type: "message" }>; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  if (item.role === "user") {
    return (
      <article className="group/message relative flex justify-end pt-6" id={`chat_message_${item.id}`}>
        <span className="absolute -top-4" id={`message-${item.id}`} />
        <BookmarkControl item={item} payload={payload} queryKey={queryKey} onNotice={onNotice} />
        <Markdown className="chat-prose chat-prose-invert max-w-[min(42rem,85%)] rounded bg-blue-600 px-4 py-2 text-white" text={item.text} />
      </article>
    )
  }

  if (item.role === "assistant") {
    return (
      <article className="group/message relative pt-6" id={`chat_message_${item.id}`}>
        <span className="absolute -top-4" id={`message-${item.id}`} />
        <BookmarkControl item={item} payload={payload} queryKey={queryKey} onNotice={onNotice} />
        {item.proposal ? <ProposalCard proposal={item.proposal} prefix={prefix} queryKey={queryKey} onNotice={onNotice} /> : (
          <div className="max-w-3xl rounded border border-gray-200 bg-white px-4 py-3">
            <Markdown className="chat-prose text-gray-800" text={item.text} />
          </div>
        )}
      </article>
    )
  }

  if (item.role === "system") {
    return <SystemMessage item={item.system || { tone: "neutral", label: "System", body: item.text }} />
  }

  return <StructuredTool tool={item.tool} fallback={item.text} />
}

function isLowPrioritySystemMessage(item: ChatRenderItem) {
  return item.type === "message" && item.role === "system" && ["neutral", "success"].includes(item.system?.tone || "neutral")
}

function isAgentActive(payload: ChatPayload) {
  return payload.agent_busy || payload.turn_in_flight
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

function scrollMessageStreamToBottom(element: HTMLElement | null) {
  if (!element) return
  element.scrollTop = element.scrollHeight
}

function findChatMessageAnchor(stream: HTMLElement, messageId: number) {
  return stream.querySelector<HTMLElement>(`#message-${messageId}`)
}

function scrollChatMessageIntoView(element: HTMLElement) {
  if (typeof element.scrollIntoView === "function") {
    element.scrollIntoView({ block: "start", behavior: "smooth" })
  }
}

function countIncomingVisibleMessages(messages: ChatMessageItem[], previousMaxMessageId: number, showSystemMessages: boolean) {
  return messages.filter((message) => {
    if (message.id <= previousMaxMessageId) return false
    return showSystemMessages || !isLowPrioritySystemMessage(renderMessage(message))
  }).length
}

function BookmarkControl({ item, payload, queryKey, onNotice }: { item: Extract<ChatRenderItem, { type: "message" }>; payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [open, setOpen] = useState(false)
  const [label, setLabel] = useState("")
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

  if (!item.bookmarkable) return null

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    bookmark.mutate()
  }

  return (
    <div className={`absolute right-0 top-0 z-10 ${open ? "block" : "hidden group-hover/message:block"}`} ref={menuRef}>
      <button className="rounded border border-gray-200 bg-white px-2 py-1 text-xs font-medium text-gray-600 shadow-sm hover:bg-gray-50" onClick={() => setOpen((value) => !value)} type="button">
        Bookmark
      </button>
      {open ? (
        <form className="absolute right-0 top-8 w-64 space-y-3 rounded border border-gray-200 bg-white p-3 shadow-lg" onSubmit={submit}>
          <label className="block text-xs font-medium text-gray-600">
            Label
            <input className="mt-1 w-full rounded border border-gray-300 px-2 py-1.5 text-sm" maxLength={120} onChange={(event) => setLabel(event.target.value)} required type="text" value={label} />
          </label>
          {bookmark.isError ? <div className="text-xs text-red-700">{errorMessage(bookmark.error, "Bookmark failed.")}</div> : null}
          <div className="flex justify-end gap-2">
            <button className={secondaryButton()} disabled={bookmark.isPending} onClick={() => setOpen(false)} type="button">Cancel</button>
            <button className={primaryButton()} disabled={bookmark.isPending} type="submit">Save</button>
          </div>
        </form>
      ) : null}
    </div>
  )
}

function ToolGroup({ item }: { item: ChatToolGroupItem }) {
  const details = item.calls.map((call) => [call.detail, call.result_summary].filter(Boolean).join(" · ")).filter(Boolean).join(", ")
  return (
    <details className="group/tool">
      <summary className="flex min-w-0 cursor-pointer items-baseline gap-2 py-0.5 text-sm text-gray-700 hover:text-gray-900">
        <span className="text-gray-400 group-open/tool:rotate-90">▸</span>
        <span className="font-mono font-medium text-gray-900">{item.tool}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-gray-600">{details}</span>
        {item.calls.length > 1 ? <span className="ml-auto rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-500">{item.calls.length}</span> : null}
      </summary>
      <div className="ml-5 mt-1 space-y-2 border-l border-gray-200 pl-3 text-xs">
        {item.calls.map((call) => (
          <div key={call.message_id}>
            <div className="break-words font-mono text-gray-700">{item.tool}{call.detail ? `(${call.detail})` : ""}</div>
            {call.result_summary ? <div className="mt-1 font-mono text-gray-500">{call.result_summary}</div> : null}
            {call.result_body ? <HighlightedToolResult code={call.result_body} detail={call.detail} error={call.result_error} tool={item.tool} /> : null}
          </div>
        ))}
      </div>
    </details>
  )
}

function HighlightedToolResult({ code, detail, error, tool }: { code: string; detail: string; error: boolean; tool: string }) {
  const language = inferToolResultLanguage(tool, detail)
  const className = `mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 ${error ? "text-red-600" : ""}`

  if (!language || error) return <pre className={className}>{code}</pre>

  return <pre className={className}>{highlightCode(code, language)}</pre>
}

function StructuredTool({ tool, fallback }: { tool?: ChatStructuredTool; fallback: string }) {
  const name = tool?.name || "tool"
  return (
    <details className="text-xs open:rounded open:border open:border-gray-200 open:bg-gray-50">
      <summary className="flex cursor-pointer items-baseline gap-2 py-0.5 text-sm text-gray-700 hover:text-gray-900 group-open/tool:px-3 group-open/tool:py-2">
        <span className="text-gray-400">▸</span>
        <span className="font-mono font-medium text-gray-900">{name}</span>
        {tool?.proposal_id ? <span className="text-gray-600">Proposal #{tool.proposal_id} {tool.proposal_state_label ? `created (${tool.proposal_state_label})` : ""}</span> : null}
      </summary>
      <pre className="overflow-x-auto px-3 pb-3 font-mono text-gray-700 whitespace-pre-wrap break-words">{JSON.stringify(tool?.payload || fallback, null, 2)}</pre>
    </details>
  )
}

function SystemMessage({ item }: { item: ChatSystemMessage }) {
  const colors = {
    success: "border-emerald-200 bg-emerald-50 text-emerald-900",
    warning: "border-amber-200 bg-amber-50 text-amber-900",
    error: "border-red-200 bg-red-50 text-red-900",
    neutral: "border-gray-200 bg-gray-50 text-gray-600"
  }
  return (
    <div className="flex justify-center">
      <div className={`inline-flex max-w-full items-center gap-2 rounded-full border px-3 py-1 text-xs ${colors[item.tone]}`}>
        <span className="shrink-0 rounded bg-white/70 px-1.5 py-0.5 font-medium uppercase tracking-wide">{item.label}</span>
        <span className="min-w-0 break-words">{item.body}</span>
      </div>
    </div>
  )
}

function ProposalCard({ proposal, prefix, queryKey, onNotice }: { proposal: ChatProposal; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const proposalAction = useMutation({
    mutationFn: (input: { action: "confirm" | "reject"; path: string }) => {
      const path = appendSearch(input.path, search)
      return input.action === "confirm" ? confirmChatProposal(path) : rejectChatProposal(path)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  if (proposal.materialized_label && proposal.materialized_path) {
    return (
      <div className="flex items-center gap-2">
        <span className="text-sm text-gray-500">Confirmed proposal</span>
        <Link className="inline-flex items-center rounded-full border border-blue-200 bg-blue-50 px-3 py-1 text-sm font-medium text-blue-700 hover:bg-blue-100" to={withRoutePrefix(proposal.materialized_path, prefix)}>{proposal.materialized_label}</Link>
      </div>
    )
  }

  return (
    <article className={`max-w-4xl rounded border bg-white px-4 py-3 ${proposal.resolved ? "border-gray-200 opacity-70 grayscale" : "border-blue-200"}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-base font-semibold text-gray-900">{proposal.title}</h3>
            <span className="rounded bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-700">{proposal.epic_bundle ? "Epic" : proposal.kind_label}</span>
            <span className={`rounded px-2 py-0.5 text-xs font-medium ${proposal.proposed ? "bg-blue-50 text-blue-700" : "bg-gray-100 text-gray-600"}`}>{proposal.state_label}</span>
            {proposal.epic_bundle ? <span className="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600">{proposal.active_children_count || 0} child Jobs</span> : null}
          </div>
          <p className="mt-1 font-mono text-xs text-gray-500">{proposal.slug}</p>
        </div>
      </div>
      <Markdown className="chat-prose mt-3 text-sm text-gray-800" text={proposal.body} />
      {proposal.epic_bundle ? <ProposalChildren children={proposal.children || []} mutation={proposalAction} /> : <ProposalMeta proposal={proposal} />}
      {proposal.proposed ? (
        <div className="mt-4 flex flex-wrap gap-2">
          <button
            className={primaryButton()}
            disabled={proposalAction.isPending}
            onClick={() => proposalAction.mutate({ action: "confirm", path: proposal.app_confirm_path })}
            type="button"
          >
            {proposal.epic_bundle ? "Confirm Epic and Jobs" : "Confirm"}
          </button>
          <button
            className="rounded border border-red-200 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-300"
            disabled={proposalAction.isPending}
            onClick={() => proposalAction.mutate({ action: "reject", path: proposal.app_reject_path })}
            type="button"
          >
            Reject
          </button>
          {proposalAction.isError ? <div className="basis-full text-xs text-red-700">{errorMessage(proposalAction.error, "Proposal command failed.")}</div> : null}
        </div>
      ) : null}
    </article>
  )
}

function ProposalMeta({ proposal }: { proposal: ChatProposal }) {
  return (
    <dl className="mt-3 grid gap-2 text-xs text-gray-600 sm:grid-cols-2">
      <div><dt className="font-medium text-gray-500">Attached scope</dt><dd>{proposal.scoped_repository_slug || "No repository attached"}</dd></div>
      <div>
        <dt className="font-medium text-gray-500">Dependencies</dt>
        <dd>{proposal.dependencies.length > 0 ? <PillList values={proposal.dependencies} /> : "None"}</dd>
      </div>
      {proposal.target_epic_label ? <div><dt className="font-medium text-gray-500">Target Epic</dt><dd>{proposal.target_epic_label}</dd></div> : null}
    </dl>
  )
}

function ProposalChildren({ children, mutation }: { children: ChatProposalChild[]; mutation: UseMutationResult<ChatPayload, Error, { action: "confirm" | "reject"; path: string }> }) {
  if (children.length === 0) return null
  return (
    <div className="mt-4 divide-y divide-gray-100 rounded border border-gray-200">
      {children.map((child) => (
        <details className="group" key={child.id}>
          <summary className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm hover:bg-gray-50">
            <span className="text-gray-400 group-open:rotate-90">▸</span>
            <span className="min-w-0 flex-1 truncate font-medium text-gray-900">{child.title}</span>
            {child.dependencies.length > 0 ? <span className="shrink-0 rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600">depends on {child.dependencies.join(", ")}</span> : null}
            <span className={`shrink-0 rounded px-2 py-0.5 text-xs font-medium ${child.proposed ? "bg-blue-50 text-blue-700" : "bg-gray-100 text-gray-600"}`}>{child.state_label}</span>
          </summary>
          <div className="border-t border-gray-100 px-8 py-3 text-sm text-gray-700">
            <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500"><span className="font-mono">{child.slug}</span><span>{child.repository_slug || "No repository attached"}</span></div>
            <Markdown className="chat-prose mt-2 text-sm text-gray-800" text={child.body} />
            {child.proposed ? (
              <div className="mt-3">
                <button
                  className="rounded border border-red-200 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-300"
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

function Compose({ payload, queryKey, onNotice }: { payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [text, setText] = useState("")
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const submitWithEnter = useSubmitChatWithEnter()
  const search = queryKey[2]
  const agentActive = isAgentActive(payload)
  const send = useMutation({
    mutationFn: () => sendChatMessage(appendSearch(payload.paths.app_message_path, search), text),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setText("")
      onNotice(null)
    }
  })

  function submitMessage() {
    if (agentActive || send.isPending || text.length === 0) return
    onNotice(null)
    send.mutate()
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submitMessage()
  }

  function handleKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (!submitWithEnter || event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) return

    event.preventDefault()
    submitMessage()
  }

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

  return (
    <form className="rounded border border-gray-200 bg-white p-3" onSubmit={submit}>
      {send.isError ? <div className="mb-2 text-sm text-red-700">{errorMessage(send.error, "Message failed.")}</div> : null}
      <div className="flex items-end gap-3">
        <textarea
          className="min-h-9 flex-1 resize-none overflow-y-hidden rounded border border-gray-300 px-3 py-2 text-base leading-6 focus:border-blue-500 focus:ring-blue-500 disabled:bg-gray-50 sm:text-sm sm:leading-5"
          disabled={agentActive || send.isPending}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={payload.chat.repository ? "Ask about this repository..." : "Attach a repository to start chatting..."}
          ref={textareaRef}
          required
          rows={1}
          value={text}
        />
        {agentActive ? null : <button className={primaryButton()} disabled={send.isPending} type="submit">Send</button>}
        {agentActive ? <StopButton payload={payload} queryKey={queryKey} /> : null}
      </div>
    </form>
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
    <button className="rounded border border-red-200 bg-white px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-400" disabled={Boolean(payload.chat.stop_requested_at) || stop.isPending} onClick={() => stop.mutate()} type="button">
      {payload.chat.stop_requested_at || stop.isPending ? "Stopping..." : "Stop"}
    </button>
  )
}

type WorkspaceTab = "whiteboard" | "context" | "chats"
type MobileChatTab = "chat" | WorkspaceTab

function ChatWorkspace({
  payload,
  prefix,
  queryKey,
  onNotice,
  whiteboardFullscreen,
  onWhiteboardFullscreenChange
}: {
  payload: ChatPayload
  prefix: string
  queryKey: ChatQueryKey
  onNotice: (message: string | null) => void
  whiteboardFullscreen: boolean
  onWhiteboardFullscreenChange: (fullscreen: boolean) => void
}) {
  const [activeTab, setActiveTab] = useState<WorkspaceTab>(() => storedWorkspaceTab() || defaultWorkspaceTab(payload))
  const [activeMobileTab, setActiveMobileTab] = useState<MobileChatTab>("chat")
  const [workspaceWidth, setWorkspaceWidth] = useState(storedWorkspaceWidth)
  const [bookmarkTarget, setBookmarkTarget] = useState<BookmarkTarget | null>(null)
  const bookmarkRequestIdRef = useRef(0)
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const expanded = activeTab === "whiteboard" && whiteboardFullscreen

  useEffect(() => {
    storeWorkspacePreference(CHAT_WORKSPACE_TAB_KEY, activeTab)
  }, [activeTab])

  useEffect(() => {
    storeWorkspacePreference(CHAT_WORKSPACE_WIDTH_KEY, String(workspaceWidth))
  }, [workspaceWidth])

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

  if (!isDesktop && !expanded) {
    return (
      <div className="flex min-h-0 flex-1 flex-col bg-white">
        <nav aria-label="Chat mobile tabs" className="flex shrink-0 overflow-x-auto border-b border-gray-200 px-2 pt-2 text-sm font-medium">
          {(["chat", "whiteboard", "context", "chats"] as MobileChatTab[]).map((tab) => (
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
            <ChatColumn bookmarkTarget={bookmarkTarget} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
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
      </div>
    )
  }

  return (
    <div
      className={expanded ? "flex min-h-0 flex-1 flex-col" : "flex min-h-0 flex-1 flex-col gap-4 lg:grid lg:gap-0"}
      style={expanded ? undefined : { gridTemplateColumns: `minmax(0,1fr) 0.5rem minmax(${CHAT_WORKSPACE_MIN_WIDTH}px,${workspaceWidth}px)` }}
    >
      {expanded ? null : <ChatColumn bookmarkTarget={bookmarkTarget} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />}
      {expanded ? null : (
        <button
          aria-label="Resize chat workspace"
          className="hidden cursor-col-resize rounded bg-transparent transition hover:bg-blue-100 focus:bg-blue-100 focus:outline-none lg:block"
          onMouseDown={beginResize}
          type="button"
        />
      )}
      <ChatWorkspacePanel
        activeTab={activeTab}
        fullscreen={expanded}
        onSelectTab={selectTab}
        onToggleWhiteboardFullscreen={() => onWhiteboardFullscreenChange(!expanded)}
        payload={payload}
        prefix={prefix}
        queryKey={queryKey}
        onNotice={onNotice}
        onBookmarkSelect={selectBookmark}
      />
    </div>
  )
}

function ChatColumn({ bookmarkTarget, payload, prefix, queryKey, onNotice }: { bookmarkTarget: BookmarkTarget | null; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  return (
    <section className="flex min-h-0 min-w-0 flex-1 flex-col gap-3">
      <div className="relative min-h-0 flex-1 overflow-hidden rounded border border-gray-200 bg-white">
        <MessageStream bookmarkTarget={bookmarkTarget} payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
        <UsageOverlay payload={payload} />
      </div>
      <Compose payload={payload} queryKey={queryKey} onNotice={onNotice} />
    </section>
  )
}

function ChatWorkspacePanel({
  activeTab,
  fullscreen,
  showTabs = true,
  onSelectTab,
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
  onToggleWhiteboardFullscreen: () => void
  payload: ChatPayload
  prefix: string
  queryKey: ChatQueryKey
  onNotice: (message: string | null) => void
  onBookmarkSelect: (messageId: number) => void
}) {
  return (
    <aside aria-label="Chat workspace" className={`flex min-h-0 min-w-0 flex-1 flex-col rounded border border-gray-200 bg-white ${fullscreen ? "" : "h-full w-full"}`}>
      {fullscreen || !showTabs ? null : (
        <nav aria-label="Chat workspace tabs" className="flex border-b border-gray-200 px-3 pt-3 text-sm font-medium">
          {(["whiteboard", "context", "chats"] as WorkspaceTab[]).map((tab) => (
            <button
              className={workspaceTabClass(activeTab === tab)}
              key={tab}
              onClick={() => onSelectTab(tab)}
              type="button"
            >
              {workspaceTabLabel(tab)}
            </button>
          ))}
        </nav>
      )}
      <div className={`min-h-0 flex-1 ${activeTab === "whiteboard" ? "overflow-hidden p-3" : "overflow-y-auto p-4"}`}>
        {activeTab === "whiteboard" ? (
          <WhiteboardBoundary>
            <WhiteboardPanel fullscreen={fullscreen} onToggleFullscreen={onToggleWhiteboardFullscreen} payload={payload} />
          </WhiteboardBoundary>
        ) : null}
        {activeTab === "context" ? <Attachments payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} /> : null}
        {activeTab === "chats" ? <ChatNavigator payload={payload} prefix={prefix} onBookmarkSelect={onBookmarkSelect} /> : null}
      </div>
    </aside>
  )
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
          <div className="mb-2 text-xs font-semibold uppercase text-gray-500">Whiteboard</div>
          <div className="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-700">
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
        <div className="text-xs font-semibold uppercase text-gray-500">Whiteboard</div>
        <div className="flex items-center gap-2">
          <button
            aria-pressed={fullscreen}
            className="rounded border border-gray-300 bg-white px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50"
            onClick={onToggleFullscreen}
            type="button"
          >
            {fullscreen ? "Exit fullscreen" : "Fullscreen"}
          </button>
        </div>
      </div>
      <div className="relative min-h-0 flex-1 overflow-hidden rounded border border-gray-200 bg-gray-50">
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
          <div className="flex h-full items-center justify-center p-4 text-sm text-gray-500">
            {loadError || "Loading canvas..."}
          </div>
        )}
        {scene.elements.length === 0 ? (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center px-6 text-center text-sm text-gray-400">
            Empty canvas. Start sketching, or ask the agent to draw something.
          </div>
        ) : null}
      </div>
      <div className="mt-1 text-xs text-gray-500">
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

function signatureForScene(scene: ChatWhiteboardScene) {
  return JSON.stringify(scene)
}

function asExcalidrawElements(elements: readonly ChatWhiteboardElement[]) {
  return elements as unknown as readonly ExcalidrawElement[]
}

function asExcalidrawFiles(files: ChatWhiteboardScene["files"]) {
  return Object.values(files) as Parameters<ExcalidrawApi["addFiles"]>[0]
}

function cleanWhiteboardAppState(value: unknown): ChatWhiteboardScene["appState"] {
  const appState = safeJsonObject(value)
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

function ChatNavigator({ payload, prefix, onBookmarkSelect }: { payload: ChatPayload; prefix: string; onBookmarkSelect: (messageId: number) => void }) {
  const [query, setQuery] = useState("")
  const normalizedQuery = query.trim().toLowerCase()
  const recentChats = useMemo(() => {
    return (payload.recent_chats || []).filter((chat) => {
      if (!normalizedQuery) return true

      return [
        chatDisplayTitle(chat),
        chat.repository?.slug || "",
        String(chat.id)
      ].some((value) => value.toLowerCase().includes(normalizedQuery))
    })
  }, [normalizedQuery, payload.recent_chats])

  return (
    <div className="space-y-5">
      <section className="space-y-3">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-sm font-semibold text-gray-900">Chats</h2>
          <Link className="rounded bg-gray-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-gray-700" to={withRoutePrefix(payload.paths.new_chat_path, prefix)}>New chat</Link>
        </div>
        <label className="block text-xs font-medium text-gray-600">
          Search chats
          <input
            className="mt-1 w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm"
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Title, repo, or id"
            type="search"
            value={query}
          />
        </label>
        {recentChats.length > 0 ? (
          <nav aria-label="Recent chats" className="space-y-1">
            {recentChats.map((chat) => (
              <Link
                className={`block rounded border px-2 py-1.5 text-xs ${chat.current ? "border-blue-200 bg-blue-50 text-blue-800" : "border-gray-200 bg-gray-50 text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700"}`}
                key={chat.id}
                to={withRoutePrefix(chat.chat_path, prefix)}
              >
                <span className="block truncate font-medium">{chatDisplayTitle(chat)}</span>
                <span className="mt-0.5 block truncate font-mono text-[0.7rem] text-gray-500">{chat.repository?.slug || `Chat #${chat.id}`}</span>
              </Link>
            ))}
          </nav>
        ) : (
          <div className="text-xs text-gray-400">No matching chats.</div>
        )}
      </section>
      <ChatBookmarks payload={payload} onBookmarkSelect={onBookmarkSelect} />
    </div>
  )
}

function ChatBookmarks({ payload, onBookmarkSelect }: { payload: ChatPayload; onBookmarkSelect: (messageId: number) => void }) {
  return (
    <section>
      <div className="mb-2 text-xs font-semibold uppercase text-gray-500">Bookmarks in this chat</div>
      {payload.bookmarks.length > 0 ? (
        <nav aria-label="Chat bookmarks" className="space-y-1">
          {payload.bookmarks.map((bookmark) => {
            const anchorMessageId = bookmark.anchor_message_id ?? bookmark.chat_message_id

            return (
              <a
                className="block rounded border border-gray-200 bg-gray-50 px-2 py-1.5 text-xs text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700"
                href={`#message-${anchorMessageId}`}
                key={bookmark.id}
                onClick={(event) => {
                  if (!isPlainAnchorClick(event)) return

                  event.preventDefault()
                  onBookmarkSelect(anchorMessageId)
                }}
              >
                <span className="block truncate">{bookmark.label}</span>
              </a>
            )
          })}
        </nav>
      ) : <div className="text-xs text-gray-400">No bookmarks yet.</div>}
    </section>
  )
}

function Attachments({ payload, prefix, queryKey, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900">Attachments</h2>
        <a className="rounded bg-gray-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-gray-700" href="#add-attachment">Add attachment</a>
      </div>
      <div className="space-y-4">
        <AttachmentGroup label="Repos" rows={payload.attachment_groups.repositories} queryKey={queryKey} onNotice={onNotice} />
        <AttachmentGroup label="Epics" rows={payload.attachment_groups.epics} queryKey={queryKey} onNotice={onNotice} />
        <AttachmentGroup label="Jobs" rows={payload.attachment_groups.jobs} queryKey={queryKey} onNotice={onNotice} />
        <AttachmentGroup label="Documents" rows={payload.attachment_groups.documents} queryKey={queryKey} onNotice={onNotice} />
      </div>
      <section>
        <div className="mb-2 text-xs font-semibold uppercase text-gray-500">In-scope documents</div>
        {payload.documents_in_scope.length > 0 ? (
          <div className="space-y-1">
            {payload.documents_in_scope.map((document) => (
              <div className="rounded border border-gray-200 px-2 py-1.5 text-xs" key={document.id}>
                <div className="font-medium text-gray-800">{document.title}</div>
                <div className="font-mono text-[0.7rem] text-gray-500">{document.repository_slug}</div>
              </div>
            ))}
          </div>
        ) : <div className="text-xs text-gray-400">No documents in scope.</div>}
      </section>
      <AddAttachment payload={payload} prefix={prefix} queryKey={queryKey} onNotice={onNotice} />
    </>
  )
}

function AttachmentGroup({ label, rows, queryKey, onNotice }: { label: string; rows: ChatAttachmentRow[]; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const detach = useMutation({
    mutationFn: (path: string) => deleteChatAttachment(appendSearch(path, search)),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  return (
    <section>
      <div className="mb-2 text-xs font-semibold uppercase text-gray-500">{label}</div>
      {rows.length > 0 ? (
        <div className="space-y-1">
          {rows.map((row) => (
            <button
              className="block w-full rounded border border-gray-200 bg-gray-50 px-2 py-1.5 text-left text-xs text-gray-700 hover:border-red-200 hover:bg-red-50 hover:text-red-700 disabled:text-gray-300"
              disabled={detach.isPending}
              key={row.id}
              onClick={() => detach.mutate(row.app_detach_path)}
              title={`Detach ${row.label}`}
              type="button"
            >
              {row.label}
            </button>
          ))}
        </div>
      ) : <div className="text-xs text-gray-400">None</div>}
      {detach.isError ? <div className="mt-1 text-xs text-red-700">{errorMessage(detach.error, "Detach failed.")}</div> : null}
    </section>
  )
}

function AddAttachment({ payload, prefix, queryKey, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const location = useLocation()
  const navigate = useNavigate()
  const params = new URLSearchParams(location.search)
  const [type, setType] = useState(params.get("attachment_type") || "Repository")
  const [query, setQuery] = useState(params.get("attachment_query") || "")
  const add = useMutation({
    mutationFn: (record: ChatAttachmentResult) => addChatAttachment(appendSearch(payload.paths.app_attachments_path, location.search), record),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  useEffect(() => {
    const next = new URLSearchParams(location.search)
    setType(next.get("attachment_type") || "Repository")
    setQuery(next.get("attachment_query") || "")
  }, [location.search])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const next = new URLSearchParams()
    next.set("attachment_type", type)
    if (query.trim()) next.set("attachment_query", query.trim())
    navigate(withRoutePrefix(`${payload.chat.chat_path}?${next.toString()}`, prefix))
  }

  return (
    <div className="rounded border border-gray-200 bg-gray-50 p-3" id="add-attachment">
      <h3 className="mb-3 text-sm font-semibold text-gray-900">Add attachment</h3>
      <form className="space-y-3" onSubmit={submit}>
        <label className="block text-xs font-medium text-gray-600">
          Type
          <select className="mt-1 w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm" name="attachment_type" onChange={(event) => setType(event.target.value)} value={type}>
            <option value="Repository">Repo</option>
            <option value="Epic">Epic</option>
            <option value="Job">Job</option>
            <option value="Document">Document</option>
          </select>
        </label>
        <label className="block text-xs font-medium text-gray-600">
          Search
          <input className="mt-1 w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm" name="attachment_query" onChange={(event) => setQuery(event.target.value)} placeholder="Search by name or id" type="search" value={query} />
        </label>
        <button className={secondaryButton()} type="submit">Search</button>
      </form>
      <div className="mt-3 space-y-1">
        {payload.attachment_results.length > 0 ? payload.attachment_results.map((record) => (
          <button
            className="block w-full rounded border border-gray-200 bg-white px-2 py-1.5 text-left text-xs text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 disabled:text-gray-300"
            disabled={add.isPending}
            key={`${record.type}-${record.id}`}
            onClick={() => add.mutate(record)}
            type="button"
          >
            {record.label}
          </button>
        )) : <div className="text-xs text-gray-500">No matches.</div>}
        {add.isError ? <div className="text-xs text-red-700">{errorMessage(add.error, "Attachment failed.")}</div> : null}
      </div>
    </div>
  )
}

function UsageOverlay({ payload }: { payload: ChatPayload }) {
  return (
    <p className="pointer-events-none absolute left-0 right-0 top-0 border-b border-gray-100 bg-white/95 px-4 py-1.5 text-xs text-gray-500">
      Tokens: {formatThousands(payload.chat.cumulative_input_tokens)}k in / {formatThousands(payload.chat.cumulative_output_tokens)}k out · {formatCurrency(payload.chat.cumulative_cost_usd)}
    </p>
  )
}

function PillList({ values }: { values: string[] }) {
  return <div className="flex flex-wrap gap-1">{values.map((value) => <span className="rounded bg-gray-100 px-2 py-0.5 font-mono" key={value}>{value}</span>)}</div>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    success: "border-green-200 bg-green-50 text-green-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function primaryButton() {
  return "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-gray-300"
}

function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:text-gray-300"
}

function workspaceTabClass(active: boolean) {
  return `border-b-2 px-3 py-2 ${active ? "border-blue-600 text-blue-700" : "border-transparent text-gray-600 hover:border-gray-300 hover:text-gray-900"}`
}

function workspaceTabLabel(tab: WorkspaceTab) {
  if (tab === "whiteboard") return "Whiteboard"
  if (tab === "context") return "Context"

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
    return value === "whiteboard" || value === "context" || value === "chats" ? value : null
  } catch (_error) {
    return null
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

function chatDisplayTitle(chat: Pick<ChatNavRecord, "id" | "title" | "repository">) {
  return chat.title || chat.repository?.slug || `Chat #${chat.id}`
}

function formatThousands(value: number) {
  const thousands = value / 1000
  return Number.isInteger(thousands) ? String(thousands) : thousands.toFixed(1).replace(/\.0$/, "")
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
        items.push(renderMessage(message))
      }
    } else {
      currentGroup = null
      items.push(renderMessage(message))
    }
  }

  return items
}

function renderMessage(message: ChatMessageItem): ChatRenderItem {
  if (message.role === "system") {
    return { ...message, system: systemMessage(message) }
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

function systemMessage(message: ChatMessageItem): ChatSystemMessage {
  const text = message.text
  const mcpHealth = mcpHealthFromContent(message.content)
  if (mcpHealth.length > 0) return structuredMcpMessage(mcpHealth)

  const result = text.match(/^\[(?:codex )?result\]\s+(.+)$/)
  if (result) return systemResultMessage(parseSystemFields(result[1]))

  const mcp = text.match(/^\[mcp_servers\]\s+(.+)$/)
  if (mcp) return systemMcpMessage(mcp[1])

  const codexError = text.match(/^\[codex error\]\s+(.+)$/)
  if (codexError) return { tone: "error", label: "Error", body: codexError[1] }

  return { tone: "neutral", label: "System", body: text }
}

function structuredMcpMessage(servers: ChatMcpHealth[]): ChatSystemMessage {
  const pending = servers.filter((server) => server.pending_tools.length > 0)
  const unavailable = servers.filter((server) => server.unavailable_tools.length > 0)
  const available = servers.filter((server) => server.available_tools.length > 0)

  if (unavailable.length > 0) {
    return {
      tone: "warning",
      label: "MCP unavailable",
      body: `MCP unavailable: ${serverStatusList(unavailable)}. Tools unavailable: ${toolSummary(unavailable, "unavailable_tools")}. Retry the turn or check the chat sidecar logs before asking the agent to persist proposals, schedules, bookmarks, or whiteboard edits.`
    }
  }

  if (pending.length > 0) {
    return {
      tone: "warning",
      label: "MCP pending",
      body: `MCP still pending: ${serverStatusList(pending)}. Tools pending: ${toolSummary(pending, "pending_tools")}. If this does not clear on the next turn, retry the turn or check worker logs for chat sidecar startup.`
    }
  }

  if (available.length > 0) {
    return {
      tone: "success",
      label: "MCP ready",
      body: `MCP tools available: ${toolSummary(available, "available_tools")}`
    }
  }

  return { tone: "neutral", label: "MCP", body: "MCP server status unavailable" }
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
  if (error) return `Agent run failed${subtype ? `: ${humanize(subtype)}` : ""}`
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

type ToolResultLanguage = "ruby" | "javascript" | "json" | "yaml" | "shell" | "css" | "html"

const RUBY_KEYWORDS = new Set([
  "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
  "for", "if", "in", "module", "next", "nil", "not", "or", "private", "protected", "public", "redo", "rescue", "retry",
  "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"
])

const JAVASCRIPT_KEYWORDS = new Set([
  "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "export",
  "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new",
  "null", "return", "switch", "throw", "true", "try", "type", "undefined", "while"
])

function inferToolResultLanguage(tool: string, detail: string): ToolResultLanguage | null {
  if (tool !== "Read") return null

  const path = firstPathToken(detail)
  if (/\.(rb|rake)\b/.test(path) || /(^|\/)(Gemfile|Rakefile|config\.ru)$/.test(path)) return "ruby"
  if (/\.(js|jsx|ts|tsx)\b/.test(path)) return "javascript"
  if (/\.json\b/.test(path)) return "json"
  if (/\.(ya?ml)\b/.test(path)) return "yaml"
  if (/\.(sh|bash|zsh)\b/.test(path) || /(^|\/)(bin|script)\//.test(path)) return "shell"
  if (/\.css\b/.test(path)) return "css"
  if (/\.(html|erb)\b/.test(path)) return "html"

  return null
}

function firstPathToken(value: string) {
  return value.split(/[\s,]+/, 1)[0] || ""
}

function highlightCode(code: string, language: ToolResultLanguage): ReactNode[] {
  const highlighted: ReactNode[] = []
  const lines = code.split("\n")

  lines.forEach((line, lineIndex) => {
    highlighted.push(...highlightLine(line, language, `line-${lineIndex}`))
    if (lineIndex < lines.length - 1) highlighted.push("\n")
  })

  return highlighted
}

function highlightLine(line: string, language: ToolResultLanguage, keyPrefix: string): ReactNode[] {
  const match = line.match(/^(\s*\d+\s+)(.*)$/)
  const prefix = match?.[1] || ""
  const source = match?.[2] || line
  const nodes: ReactNode[] = []

  if (prefix) nodes.push(<span className="text-gray-400" key={`${keyPrefix}-number`}>{prefix}</span>)

  nodes.push(...highlightSourceLine(source, language, keyPrefix))
  return nodes
}

function highlightSourceLine(line: string, language: ToolResultLanguage, keyPrefix: string): ReactNode[] {
  if (language === "ruby" || language === "shell" || language === "yaml") {
    return highlightLexedLine(line, {
      keyPrefix,
      commentMarkers: [ "#" ],
      keywords: language === "ruby" ? RUBY_KEYWORDS : new Set<string>()
    })
  }

  if (language === "javascript" || language === "json" || language === "css") {
    return highlightLexedLine(line, {
      keyPrefix,
      commentMarkers: language === "json" ? [] : [ "//" ],
      keywords: language === "javascript" ? JAVASCRIPT_KEYWORDS : new Set<string>()
    })
  }

  if (language === "html") return highlightHtmlLine(line, keyPrefix)

  return [ line ]
}

function highlightLexedLine(line: string, options: { keyPrefix: string; commentMarkers: string[]; keywords: Set<string> }) {
  const nodes: ReactNode[] = []
  let index = 0
  let part = 0

  function push(text: string, className?: string) {
    if (!text) return
    nodes.push(className ? <span className={className} key={`${options.keyPrefix}-${part++}`}>{text}</span> : text)
  }

  while (index < line.length) {
    const commentMarker = options.commentMarkers.find((marker) => line.startsWith(marker, index))
    if (commentMarker) {
      push(line.slice(index), "text-gray-400 italic")
      break
    }

    const char = line[index]
    if (char === "\"" || char === "'" || char === "`") {
      const end = stringEndIndex(line, index, char)
      push(line.slice(index, end), "text-emerald-700")
      index = end
      continue
    }

    const number = line.slice(index).match(/^\b\d+(?:\.\d+)?\b/)
    if (number) {
      push(number[0], "text-amber-700")
      index += number[0].length
      continue
    }

    const variable = line.slice(index).match(/^[@$][A-Za-z_]\w*/)
    if (variable) {
      push(variable[0], "text-rose-700")
      index += variable[0].length
      continue
    }

    const symbol = line.slice(index).match(/^:[A-Za-z_]\w*[!?=]?/)
    if (symbol) {
      push(symbol[0], "text-violet-700")
      index += symbol[0].length
      continue
    }

    const word = line.slice(index).match(/^[A-Za-z_]\w*[!?=]?/)
    if (word) {
      const value = word[0]
      if (options.keywords.has(value)) {
        push(value, "font-semibold text-blue-700")
      } else if (/^[A-Z]/.test(value)) {
        push(value, "text-cyan-700")
      } else {
        push(value)
      }
      index += value.length
      continue
    }

    push(char)
    index += 1
  }

  return nodes
}

function highlightHtmlLine(line: string, keyPrefix: string) {
  const nodes: ReactNode[] = []
  let part = 0

  line.split(/(<\/?[A-Za-z][^>]*>)/g).forEach((segment) => {
    if (!segment) return
    nodes.push(segment.startsWith("<") ? <span className="text-blue-700" key={`${keyPrefix}-${part++}`}>{segment}</span> : segment)
  })

  return nodes
}

function stringEndIndex(line: string, start: number, quote: string) {
  let index = start + 1
  while (index < line.length) {
    if (line[index] === "\\" && index + 1 < line.length) {
      index += 2
      continue
    }
    if (line[index] === quote) return index + 1
    index += 1
  }

  return line.length
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

function renderItemKey(item: ChatRenderItem) {
  if (item.type === "message") return `message-${item.id}`

  return `tool-${item.calls.map((call) => call.message_id).join("-")}`
}

function chatRenderItemsSignature(items: ChatRenderItem[]) {
  return items.map((item) => {
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
