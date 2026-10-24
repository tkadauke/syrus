import type { ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import {
  Badge,
  CardShell,
  EntityReference,
  FilterableList,
  displayValue,
  EmptyState,
  InternalLink,
  numberValue,
  Row,
  SectionLabel,
  StatePill
} from "./toolCardUi"
import i18n from "../../i18n"
import { ErrorCard } from "./chatHelperToolCard"

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
  mode: string | null
  repositoryId: string | null
  repository: string | null
  messageCount: number | null
  updatedAt: string | null
  attachedJobsCount: number | null
  attachedJobs: AttachedJob[]
}

type AttachedJob = {
  id: string
  slug: string | null
  title: string | null
  state: string | null
  repositoryId: string | null
  repository: string | null
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
    mode: displayValue(value.mode),
    repositoryId: displayValue(value.repository_id),
    repository: displayValue(value.repository),
    messageCount: numberValue(value.message_count),
    updatedAt: displayValue(value.updated_at),
    attachedJobsCount: numberValue(value.attached_jobs_count),
    attachedJobs: Array.isArray(value.attached_jobs)
      ? value.attached_jobs.flatMap((item) => {
          if (!isPlainObject(item)) return []
          const jobId = displayValue(item.id)
          if (!jobId) return []
          return [
            {
              id: jobId,
              slug: displayValue(item.slug),
              title: displayValue(item.title),
              state: displayValue(item.state),
              repositoryId: displayValue(item.repository_id),
              repository: displayValue(item.repository)
            }
          ]
        })
      : []
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
    pagination.page != null && pagination.totalPages != null ? i18n.t("chat:page_of_pages", { page: pagination.page, total: pagination.totalPages }) : null,
    pagination.totalCount != null ? i18n.t("chat:total_count", { count: pagination.totalCount }) : null,
    pagination.hasNextPage === true ? i18n.t("chat:more_available") : pagination.hasNextPage === false ? i18n.t("chat:end_of_results") : null
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
        return marked ? (
          <mark className="rounded bg-amber-100 px-0.5 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100" key={index}>
            {part}
          </mark>
        ) : (
          <span key={index}>{part}</span>
        )
      })}
    </>
  )
}

function ChatTitle({ chatId, messageId, title }: { chatId: string; messageId?: string | null; title: string }) {
  if (messageId) return <EntityReference href={messageHref(chatId, messageId)} id={chatId} kind="chat" label={title} />
  return <EntityReference id={chatId} kind="chat" label={title} />
}

function Metadata({ children }: { children: ReactNode }) {
  return <div className="flex min-w-0 flex-wrap items-center gap-1 text-2xs text-gray-500 dark:text-gray-400">{children}</div>
}

function ListChatsFilters({ mode, jobId, hasAttachedJobs }: { mode: string | null; jobId: string | null; hasAttachedJobs: boolean | null }) {
  if (!mode && !jobId && hasAttachedJobs == null) return null

  return (
    <div className="flex flex-wrap gap-1">
      {mode ? <Badge>{i18n.t("chat:mode_value", { mode })}</Badge> : null}
      {jobId ? (
        <Badge>
          <span>{i18n.t("chat:job_label")}</span> <EntityReference id={jobId} kind="job" />
        </Badge>
      ) : null}
      {hasAttachedJobs == null ? null : <Badge>{hasAttachedJobs ? i18n.t("chat:has_attached_jobs") : i18n.t("chat:no_attached_jobs")}</Badge>}
    </div>
  )
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
  return i18n.t("chat:chat_count", { count })
}

export function ListChatsCard({ context }: { context: ToolCardContext }) {
  if (context.resultError)
    return <ErrorCard title={i18n.t("chat:could_not_list_chats")} message={displayValue(context.resultBody) ?? i18n.t("chat:chat_list_failed")} />
  const result = parseListChats(context)
  if (!result) return null

  const modeFilter = displayValue(context.input?.mode)
  const jobFilter = displayValue(context.input?.job_id)
  const attachedFilter = typeof context.input?.has_attached_jobs === "boolean" ? context.input.has_attached_jobs : null

  if (result.rows.length === 0)
    return (
      <CardShell>
        <ListChatsFilters hasAttachedJobs={attachedFilter} jobId={jobFilter} mode={modeFilter} />
        <EmptyState>{i18n.t("chat:no_chats_found")}</EmptyState>
        <PaginationNote pagination={result.pagination} />
      </CardShell>
    )

  return (
    <CardShell>
      <ListChatsFilters hasAttachedJobs={attachedFilter} jobId={jobFilter} mode={modeFilter} />
      <div className="space-y-2">
        {result.rows.map((chat) => (
          <article className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={chat.id}>
            <div className="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-start sm:justify-between sm:gap-2">
              <div className="min-w-0 flex-1">
                <div className="break-words font-medium text-gray-900 dark:text-gray-100" title={chat.title}>
                  <ChatTitle chatId={chat.id} title={chat.title} />
                </div>
                <Metadata>
                  {chat.mode ? <Badge>{chat.mode}</Badge> : null}
                  {chat.repository ? (
                    <EntityReference kind="repository" repositoryId={chat.repositoryId} repositorySlug={chat.repository} />
                  ) : (
                    <span>{i18n.t("chat:no_repository")}</span>
                  )}
                  {chat.messageCount != null ? <span>{i18n.t("chat:message_count", { count: chat.messageCount })}</span> : null}
                  {chat.attachedJobsCount != null ? <span>{i18n.t("chat:attached_job_count", { count: chat.attachedJobsCount })}</span> : null}
                </Metadata>
              </div>
              {chat.updatedAt ? (
                <time className="text-2xs text-gray-500 dark:text-gray-400 sm:shrink-0" dateTime={chat.updatedAt} title={chat.updatedAt}>
                  {timestamp(chat.updatedAt)}
                </time>
              ) : null}
            </div>
            {chat.attachedJobs.length > 0 ? (
              <div className="mt-2 flex flex-wrap gap-1.5">
                {chat.attachedJobs.map((job) => (
                  <span className="inline-flex min-h-7 max-w-full flex-wrap items-center gap-1 rounded border border-border px-2 py-1" key={job.id}>
                    <EntityReference id={job.id} kind="job" slug={job.slug} />
                    {job.title ? <span className="break-words text-text-secondary">{job.title}</span> : null}
                    {job.state ? <StatePill state={job.state} /> : null}
                    {job.repository ? <EntityReference kind="repository" repositoryId={job.repositoryId} repositorySlug={job.repository} /> : null}
                  </span>
                ))}
              </div>
            ) : null}
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
  const query = result.query ? `"${result.query}"` : i18n.t("chat:chat_search")
  return i18n.t("chat:search_hit_summary", { query, count: result.hits.length })
}

export function SearchChatsCard({ context }: { context: ToolCardContext }) {
  const result = parseSearchChats(context)
  if (!result) return null
  if (result.hits.length === 0) return <EmptyState>{result.message || i18n.t("chat:no_matching_messages")}</EmptyState>

  const matchCounts = new Map<string, number>()
  for (const hit of result.hits) matchCounts.set(hit.chatSessionId, (matchCounts.get(hit.chatSessionId) ?? 0) + 1)

  return (
    <CardShell>
      {result.query ? <Row label={i18n.t("chat:query")} value={result.query} /> : null}
      <div className="space-y-2">
        {result.hits.map((hit) => (
          <article className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={hit.key}>
            <div className="flex min-w-0 items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="truncate font-medium text-gray-900 dark:text-gray-100" title={hit.chatTitle}>
                  <ChatTitle chatId={hit.chatSessionId} messageId={hit.messageId} title={hit.chatTitle} />
                </div>
                <Metadata>
                  {hit.repository ? <Badge>{hit.repository}</Badge> : <span>{i18n.t("chat:no_repository")}</span>}
                  {hit.role ? <Badge>{hit.role}</Badge> : null}
                  <span>{i18n.t("chat:match_in_chat_count", { count: matchCounts.get(hit.chatSessionId) ?? 1 })}</span>
                </Metadata>
              </div>
              {hit.createdAt ? (
                <time className="shrink-0 text-2xs text-gray-500 dark:text-gray-400" dateTime={hit.createdAt} title={hit.createdAt}>
                  {timestamp(hit.createdAt)}
                </time>
              ) : null}
            </div>
            {hit.snippet ? (
              <p className="mt-1 whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">
                <Snippet text={hit.snippet} />
              </p>
            ) : null}
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
  const title = result.chatTitle || (result.chatId ? i18n.t("chat:chat_number", { id: result.chatId }) : i18n.t("chat:tool_card_chat"))
  return i18n.t("chat:chat_message_summary", { title, count: result.messages.length })
}

export function ReadChatMessagesCard({ context }: { context: ToolCardContext }) {
  const result = parseReadChatMessages(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {result.chatId && result.chatTitle ? (
          <ChatTitle chatId={result.chatId} title={result.chatTitle} />
        ) : (
          <span className="font-medium text-gray-900 dark:text-gray-100">{result.chatTitle || i18n.t("chat:chat_transcript")}</span>
        )}
        {result.page != null ? <Badge>page {result.page}</Badge> : null}
        {result.hasMore ? <Badge>{i18n.t("chat:more_messages_available")}</Badge> : null}
      </div>
      {result.messages.length === 0 ? (
        <EmptyState>{i18n.t("chat:no_messages_on_page")}</EmptyState>
      ) : (
        <div>
          <SectionLabel>{i18n.t("chat:transcript_excerpt")}</SectionLabel>
          <div className="mt-1">
            <FilterableList
              itemText={(message) => [message.role, message.sender, message.createdAt, message.content].filter(Boolean).join(" ")}
              items={result.messages}
              placeholder={i18n.t("chat:filter_messages")}
            >
              {(messages) => (
                <ol className="max-h-80 space-y-1 overflow-auto rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
                  {messages.map((message) => (
                    <li className="rounded border border-gray-100 p-2 dark:border-gray-800" key={message.id}>
                      <Metadata>
                        {message.role ? <Badge>{message.role}</Badge> : null}
                        {message.sender ? <span>{message.sender}</span> : null}
                        {message.createdAt ? (
                          <time dateTime={message.createdAt} title={message.createdAt}>
                            {timestamp(message.createdAt)}
                          </time>
                        ) : null}
                        {result.chatId ? (
                          <InternalLink href={messageHref(result.chatId, message.id)}>message {message.id}</InternalLink>
                        ) : (
                          <span>message {message.id}</span>
                        )}
                      </Metadata>
                      <p className="mt-1 whitespace-pre-wrap break-words text-text-secondary">{message.content}</p>
                    </li>
                  ))}
                </ol>
              )}
            </FilterableList>
          </div>
        </div>
      )}
      {result.hasMore && result.nextPage != null ? <div className="text-2xs text-text-muted">{i18n.t("chat:next_page", { page: result.nextPage })}</div> : null}
    </CardShell>
  )
}
