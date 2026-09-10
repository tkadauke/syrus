import type { ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel } from "./toolCardUi"

const SNIPPET_CHARS = 280
const MESSAGE_CHARS = 520

type Pagination = {
  page: number | null
  perPage: number | null
  totalCount: number | null
  totalPages: number | null
  hasNextPage: boolean | null
}

type ChatRow = {
  id: string
  title: string
  repository: string | null
  messageCount: number | null
  updatedAt: string | null
}

type SearchHit = {
  key: string
  chatSessionId: string
  messageId: string | null
  chatTitle: string
  repository: string | null
  role: string | null
  snippet: string | null
  createdAt: string | null
}

type MessageRow = {
  id: string
  role: string | null
  sender: string | null
  content: string
  createdAt: string | null
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

export function compactText(value: string | null, maxChars = SNIPPET_CHARS) {
  if (!value) return null
  const normalized = value.replace(/\s+/g, " ").trim()
  if (!normalized) return null
  return normalized.length > maxChars ? `${normalized.slice(0, maxChars - 3)}...` : normalized
}

function timestamp(value: string | null) {
  if (!value) return null
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(parsed)
}

function chatHref(chatId: string) {
  return `/chats/${encodeURIComponent(chatId)}`
}

function messageHref(chatId: string, messageId: string | null) {
  return messageId ? `${chatHref(chatId)}#message-${encodeURIComponent(messageId)}` : chatHref(chatId)
}

function parsePagination(value: unknown): Pagination {
  if (!isPlainObject(value)) return { page: null, perPage: null, totalCount: null, totalPages: null, hasNextPage: null }
  return {
    page: numberValue(value.page),
    perPage: numberValue(value.per_page),
    totalCount: numberValue(value.total_count),
    totalPages: numberValue(value.total_pages),
    hasNextPage: typeof value.has_next_page === "boolean" ? value.has_next_page : null
  }
}

function parseChatRow(value: unknown): ChatRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const title = displayValue(value.title)
  if (!id || !title) return null
  return {
    id,
    title,
    repository: displayValue(value.repository),
    messageCount: numberValue(value.message_count),
    updatedAt: displayValue(value.updated_at)
  }
}

function parseSearchHit(value: unknown, index: number): SearchHit | null {
  if (!isPlainObject(value)) return null
  const chatSessionId = displayValue(value.chat_session_id)
  const chatTitle = displayValue(value.chat_title)
  if (!chatSessionId || !chatTitle) return null
  const messageId = displayValue(value.message_id)
  return {
    key: `${chatSessionId}-${messageId ?? index}`,
    chatSessionId,
    messageId,
    chatTitle,
    repository: displayValue(value.repository),
    role: displayValue(value.role),
    snippet: compactText(displayValue(value.snippet)),
    createdAt: displayValue(value.created_at)
  }
}

function contentText(value: unknown): string | null {
  if (typeof value === "string") return value
  if (!isPlainObject(value)) return null
  return displayValue(value.text) ?? displayValue(value.content) ?? displayValue(value.summary)
}

function parseMessage(value: unknown, index: number): MessageRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id) ?? String(index)
  const content = compactText(contentText(value.content), MESSAGE_CHARS)
  if (!content) return null
  return {
    id,
    role: displayValue(value.role),
    sender: displayValue(value.sender) ?? displayValue(value.sender_name),
    content,
    createdAt: displayValue(value.created_at)
  }
}

function PaginationNote({ pagination }: { pagination: Pagination }) {
  const pieces = [
    pagination.page != null && pagination.totalPages != null ? `Page ${pagination.page} of ${pagination.totalPages}` : null,
    pagination.totalCount != null ? `${pagination.totalCount} total` : null,
    pagination.hasNextPage ? "More available" : null
  ].filter(Boolean)
  if (pieces.length === 0) return null
  return <div className="text-2xs text-gray-500 dark:text-gray-400">{pieces.join(" · ")}</div>
}

function Snippet({ text }: { text: string }) {
  const parts = text.split(/(<\/?b>)/i)
  let marked = false
  return (
    <>
      {parts.map((part, index) => {
        const lower = part.toLowerCase()
        if (lower === "<b>") {
          marked = true
          return null
        }
        if (lower === "</b>") {
          marked = false
          return null
        }
        if (!part) return null
        return marked ? <mark className="rounded bg-amber-100 px-0.5 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100" key={index}>{part}</mark> : <span key={index}>{part}</span>
      })}
    </>
  )
}

function ChatTitle({ chatId, messageId, title }: { chatId: string; messageId?: string | null; title: string }) {
  return <InternalLink href={messageHref(chatId, messageId ?? null)}>{title}</InternalLink>
}

function Metadata({ children }: { children: ReactNode }) {
  return <div className="flex min-w-0 flex-wrap items-center gap-1 text-2xs text-gray-500 dark:text-gray-400">{children}</div>
}

export function parseListChats(context: ToolCardContext) {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.chats)) return null
  return {
    rows: parsed.chats.flatMap((item) => {
      const row = parseChatRow(item)
      return row ? [row] : []
    }),
    pagination: parsePagination(parsed.pagination)
  }
}

export function listChatsCollapsedSummary(context: ToolCardContext) {
  const result = parseListChats(context)
  if (!result) return null
  const count = result.pagination.totalCount ?? result.rows.length
  return count === 0 ? "No chats" : `${count} chat${count === 1 ? "" : "s"}`
}

export function ListChatsCard({ context }: { context: ToolCardContext }) {
  const result = parseListChats(context)
  if (!result) return null
  if (result.rows.length === 0) return <EmptyState>No chats found.</EmptyState>

  return (
    <CardShell>
      <div className="space-y-2">
        {result.rows.map((chat) => (
          <article className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={chat.id}>
            <div className="flex min-w-0 items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="truncate font-medium text-gray-900 dark:text-gray-100" title={chat.title}>
                  <ChatTitle chatId={chat.id} title={chat.title} />
                </div>
                <Metadata>
                  {chat.repository ? <Badge>{chat.repository}</Badge> : <span>No repository</span>}
                  {chat.messageCount != null ? <span>{chat.messageCount} message{chat.messageCount === 1 ? "" : "s"}</span> : null}
                </Metadata>
              </div>
              {chat.updatedAt ? <time className="shrink-0 text-2xs text-gray-500 dark:text-gray-400" dateTime={chat.updatedAt} title={chat.updatedAt}>{timestamp(chat.updatedAt)}</time> : null}
            </div>
          </article>
        ))}
      </div>
      <PaginationNote pagination={result.pagination} />
    </CardShell>
  )
}

export function parseSearchChats(context: ToolCardContext) {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.results)) return null
  const hits = parsed.results.flatMap((item, index) => {
    const hit = parseSearchHit(item, index)
    return hit ? [hit] : []
  })
  return { hits, message: displayValue(parsed.message), query: displayValue(context.input?.query) }
}

export function searchChatsCollapsedSummary(context: ToolCardContext) {
  const result = parseSearchChats(context)
  if (!result) return null
  const query = result.query ? `"${result.query}"` : "Chat search"
  return `${query} - ${result.hits.length} hit${result.hits.length === 1 ? "" : "s"}`
}

export function SearchChatsCard({ context }: { context: ToolCardContext }) {
  const result = parseSearchChats(context)
  if (!result) return null
  if (result.hits.length === 0) return <EmptyState>{result.message || "No matching messages found."}</EmptyState>

  const matchCounts = new Map<string, number>()
  for (const hit of result.hits) matchCounts.set(hit.chatSessionId, (matchCounts.get(hit.chatSessionId) ?? 0) + 1)

  return (
    <CardShell>
      {result.query ? <Row label="Query" value={result.query} /> : null}
      <div className="space-y-2">
        {result.hits.map((hit) => (
          <article className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={hit.key}>
            <div className="flex min-w-0 items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="truncate font-medium text-gray-900 dark:text-gray-100" title={hit.chatTitle}>
                  <ChatTitle chatId={hit.chatSessionId} messageId={hit.messageId} title={hit.chatTitle} />
                </div>
                <Metadata>
                  {hit.repository ? <Badge>{hit.repository}</Badge> : <span>No repository</span>}
                  {hit.role ? <Badge>{hit.role}</Badge> : null}
                  <span>{matchCounts.get(hit.chatSessionId) ?? 1} match{(matchCounts.get(hit.chatSessionId) ?? 1) === 1 ? "" : "es"} in chat</span>
                </Metadata>
              </div>
              {hit.createdAt ? <time className="shrink-0 text-2xs text-gray-500 dark:text-gray-400" dateTime={hit.createdAt} title={hit.createdAt}>{timestamp(hit.createdAt)}</time> : null}
            </div>
            {hit.snippet ? <p className="mt-1 whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300"><Snippet text={hit.snippet} /></p> : null}
          </article>
        ))}
      </div>
    </CardShell>
  )
}

export function parseReadChatMessages(context: ToolCardContext) {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.messages)) return null
  const chatId = displayValue(context.input?.chat_session_id)
  return {
    chatId,
    chatTitle: displayValue(parsed.chat_title),
    page: numberValue(parsed.page),
    hasMore: typeof parsed.has_more === "boolean" ? parsed.has_more : null,
    nextPage: numberValue(parsed.next_page),
    messages: parsed.messages.flatMap((item, index) => {
      const message = parseMessage(item, index)
      return message ? [message] : []
    })
  }
}

export function readChatMessagesCollapsedSummary(context: ToolCardContext) {
  const result = parseReadChatMessages(context)
  if (!result) return null
  const title = result.chatTitle || (result.chatId ? `Chat ${result.chatId}` : "Chat")
  return `${title} - ${result.messages.length} message${result.messages.length === 1 ? "" : "s"}`
}

export function ReadChatMessagesCard({ context }: { context: ToolCardContext }) {
  const result = parseReadChatMessages(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {result.chatId && result.chatTitle ? <ChatTitle chatId={result.chatId} title={result.chatTitle} /> : <span className="font-medium text-gray-900 dark:text-gray-100">{result.chatTitle || "Chat transcript"}</span>}
        {result.page != null ? <Badge>page {result.page}</Badge> : null}
        {result.hasMore ? <Badge>more messages available</Badge> : null}
      </div>
      {result.messages.length === 0 ? (
        <EmptyState>No messages on this page.</EmptyState>
      ) : (
        <div>
          <SectionLabel>Transcript excerpt</SectionLabel>
          <ol className="mt-1 max-h-80 space-y-1 overflow-auto rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
            {result.messages.map((message) => (
              <li className="rounded border border-gray-100 p-2 dark:border-gray-800" key={message.id}>
                <Metadata>
                  {message.role ? <Badge>{message.role}</Badge> : null}
                  {message.sender ? <span>{message.sender}</span> : null}
                  {message.createdAt ? <time dateTime={message.createdAt} title={message.createdAt}>{timestamp(message.createdAt)}</time> : null}
                  {result.chatId ? <InternalLink href={messageHref(result.chatId, message.id)}>message {message.id}</InternalLink> : <span>message {message.id}</span>}
                </Metadata>
                <p className="mt-1 whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{message.content}</p>
              </li>
            ))}
          </ol>
        </div>
      )}
      {result.hasMore && result.nextPage != null ? <div className="text-2xs text-gray-500 dark:text-gray-400">Next page: {result.nextPage}</div> : null}
    </CardShell>
  )
}
