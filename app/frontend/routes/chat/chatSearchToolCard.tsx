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
import { ErrorCard } from "./chatHelperToolCard"
import { MarkdownPreview } from "./toolCardMarkdown"
import { MediaPreviewShell, type MediaPreviewAction } from "./mediaPreviewShell"

const SNIPPET_CHARS = 280
const MESSAGE_CHARS = 520
const TRANSCRIPT_LIST_CLASS = [
  "min-w-0 max-h-80 space-y-1 overflow-x-hidden overflow-y-auto rounded border",
  "border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950"
].join(" ")

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
  mode: string | null
  repositoryId: string | null
  repository: string | null
  role: string | null
  snippet: string | null
  createdAt: string | null
  attachedJobsCount: number | null
  attachedJobs: AttachedJob[]
  chatDeletedAt: string | null
  chatDeletedBy: string | null
  messageDeletedAt: string | null
  messageDeletedBy: string | null
}

type MessageRow = {
  id: string
  role: string | null
  content: string
  createdAt: string | null
  deletedAt: string | null
  deletedBy: string | null
  attachments: MessageAttachment[]
}

type MessageAttachment = {
  key: string
  name: string
  mimeType: string | null
  src: string | null
  image: boolean
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

function parseAttachedJobs(value: unknown): AttachedJob[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    if (!id) return []
    return [
      {
        id,
        slug: displayValue(item.slug),
        title: displayValue(item.title),
        state: displayValue(item.state),
        repositoryId: displayValue(item.repository_id),
        repository: displayValue(item.repository)
      }
    ]
  })
}

function deletedBy(value: unknown): string | null {
  if (!isPlainObject(value)) return displayValue(value)
  return displayValue(value.name) ?? displayValue(value.email) ?? displayValue(value.id)
}

function safeSnippet(value: unknown): string | null {
  const snippet = displayValue(value)
  if (!snippet) return null
  // FTS supplies only these highlight markers. Converting the exact markers
  // to markdown preserves emphasis while every other HTML-looking string is
  // rendered as text by MarkdownPreview.
  return snippet.replace(/<b>/gi, "**").replace(/<\/b>/gi, "**")
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
    mode: displayValue(value.mode),
    repositoryId: displayValue(value.repository_id),
    repository: displayValue(value.repository),
    role: displayValue(value.role),
    snippet: safeSnippet(value.snippet),
    createdAt: displayValue(value.created_at),
    attachedJobsCount: numberValue(value.attached_jobs_count),
    attachedJobs: parseAttachedJobs(value.attached_jobs),
    chatDeletedAt: displayValue(value.chat_session_deleted_at),
    chatDeletedBy: deletedBy(value.chat_session_deleted_by),
    messageDeletedAt: displayValue(value.deleted_at),
    messageDeletedBy: deletedBy(value.deleted_by)
  }
}

function jsonMarkdown(value: unknown): string | null {
  if (value == null) return null
  if (typeof value === "string") return value
  try {
    return `\`\`\`json\n${JSON.stringify(value, null, 2)}\n\`\`\``
  } catch {
    return "[Structured content unavailable]"
  }
}

function contentBlockText(value: unknown): string | null {
  if (typeof value === "string") return value
  if (!isPlainObject(value)) return null

  const type = displayValue(value.type)
  if (type === "text" || type === "output_text") return displayValue(value.text) ?? displayValue(value.output)
  if (type === "thinking" || type === "redacted_thinking") return "[Thinking block omitted]"
  if (type === "tool_use") {
    const name = displayValue(value.name) ?? "tool"
    return [`Tool call: **${name}**`, jsonMarkdown(value.input)].filter(Boolean).join("\n\n")
  }
  if (type === "tool_result") {
    const status = value.is_error === true ? "error" : "result"
    return [`Tool ${status}`, contentText(value.content ?? value.result)].filter(Boolean).join("\n\n")
  }

  const label = type ? type.replace(/_/g, " ") : "structured"
  return `[${label} block]`
}

function contentText(value: unknown): string | null {
  if (typeof value === "string") return value
  if (Array.isArray(value)) {
    const text = value.flatMap((item) => {
      const block = contentBlockText(item)
      return block ? [block] : []
    })
    return text.length > 0 ? text.join("\n\n") : null
  }
  if (!isPlainObject(value)) return null

  const typed = contentBlockText(value)
  if (displayValue(value.type)) return typed
  const direct = displayValue(value.text) ?? displayValue(value.summary)
  if (direct) return direct
  if (value.content != null) return contentText(value.content)
  if (value.result != null) return contentText(value.result) ?? jsonMarkdown(value.result)
  return jsonMarkdown(value)
}

function safeAttachmentUrl(value: unknown, mimeType: string | null): string | null {
  const url = displayValue(value)
  if (!url) return null
  if (/^(https?:\/\/|\/)/i.test(url)) return url
  if (url.startsWith("data:image/") && mimeType?.startsWith("image/")) return url
  return null
}

function parseAttachments(content: unknown): MessageAttachment[] {
  const values = Array.isArray(content)
    ? content.filter((value) => isPlainObject(value) && ["image", "document"].includes(displayValue(value.type) ?? ""))
    : isPlainObject(content)
      ? [content.attachments, content.media, content.images].flatMap((value) => (Array.isArray(value) ? value : []))
      : []
  return values.flatMap((value, index) => {
    if (!isPlainObject(value)) return []
    const source = isPlainObject(value.source) ? value.source : null
    const mimeType =
      displayValue(value.mime_type) ??
      displayValue(value.mimeType) ??
      displayValue(value.content_type) ??
      displayValue(value.media_type) ??
      displayValue(source?.media_type)
    const name = displayValue(value.name) ?? displayValue(value.filename) ?? `Attachment ${index + 1}`
    const data = displayValue(value.data) ?? displayValue(source?.data)
    const encodedImage = data && mimeType?.startsWith("image/") ? `data:${mimeType};base64,${data}` : null
    const src = encodedImage ?? safeAttachmentUrl(value.url ?? value.file_path ?? value.image_url ?? value.data_url ?? source?.url, mimeType)
    return [{ key: `${name}-${index}`, name, mimeType, src, image: Boolean(mimeType?.startsWith("image/")) }]
  })
}

function parseMessage(value: unknown, index: number): MessageRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id) ?? String(index)
  const content = contentText(value.content) ?? ""
  const attachments = parseAttachments(value.content)
  if (!content.trim() && attachments.length === 0) return null
  return {
    id,
    role: displayValue(value.role),
    content,
    createdAt: displayValue(value.created_at),
    deletedAt: displayValue(value.deleted_at),
    deletedBy: deletedBy(value.deleted_by),
    attachments
  }
}

function MessageAttachments({ attachments }: { attachments: MessageAttachment[] }) {
  if (attachments.length === 0) return null
  return (
    <div className="mt-2 flex min-w-0 flex-wrap gap-2">
      {attachments.map((attachment) => {
        if (!attachment.image) {
          const label = attachment.mimeType ? `${attachment.name} · ${attachment.mimeType}` : attachment.name
          return attachment.src ? (
            <InternalLink href={attachment.src} key={attachment.key}>
              {label}
            </InternalLink>
          ) : (
            <Badge key={attachment.key}>📎 {label}</Badge>
          )
        }
        const actions: MediaPreviewAction[] = attachment.src
          ? [
              { label: "Open image", href: attachment.src },
              { label: "Download", href: attachment.src, download: true }
            ]
          : []
        return (
          <MediaPreviewShell
            item={{
              title: attachment.name,
              subtitle: attachment.mimeType,
              src: attachment.src,
              alt: attachment.name,
              badge: "image",
              fallbackLabel: "Image preview unavailable",
              actions,
              meta: [{ label: "Content type", value: attachment.mimeType }]
            }}
            key={attachment.key}
            modalLabel={attachment.name}
            thumbnailClassName="w-40 max-w-full"
          />
        )
      })}
    </div>
  )
}

function PaginationNote({ pagination }: { pagination: Pagination }) {
  const pieces = [
    pagination.page != null && pagination.totalPages != null ? `Page ${pagination.page} of ${pagination.totalPages}` : null,
    pagination.totalCount != null ? `${pagination.totalCount} total` : null,
    pagination.hasNextPage === true ? "More available" : pagination.hasNextPage === false ? "End of results" : null
  ].filter(Boolean)
  if (pieces.length === 0) return null
  return <div className="text-2xs text-gray-500 dark:text-gray-400">{pieces.join(" · ")}</div>
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
      {mode ? <Badge>Mode: {mode}</Badge> : null}
      {jobId ? (
        <Badge>
          <span>Job:</span> <EntityReference id={jobId} kind="job" />
        </Badge>
      ) : null}
      {hasAttachedJobs == null ? null : <Badge>{hasAttachedJobs ? "Has attached Jobs" : "No attached Jobs"}</Badge>}
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
  return count === 0 ? "No chats" : `${count} chat${count === 1 ? "" : "s"}`
}

export function ListChatsCard({ context }: { context: ToolCardContext }) {
  if (context.resultError) return <ErrorCard title="Could not list chats" message={displayValue(context.resultBody) ?? "The chat list request failed."} />
  const result = parseListChats(context)
  if (!result) return null

  const modeFilter = displayValue(context.input?.mode)
  const jobFilter = displayValue(context.input?.job_id)
  const attachedFilter = typeof context.input?.has_attached_jobs === "boolean" ? context.input.has_attached_jobs : null

  if (result.rows.length === 0)
    return (
      <CardShell>
        <ListChatsFilters hasAttachedJobs={attachedFilter} jobId={jobFilter} mode={modeFilter} />
        <EmptyState>No chats found.</EmptyState>
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
                    <span>No repository</span>
                  )}
                  {chat.messageCount != null ? (
                    <span>
                      {chat.messageCount} message{chat.messageCount === 1 ? "" : "s"}
                    </span>
                  ) : null}
                  {chat.attachedJobsCount != null ? (
                    <span>
                      {chat.attachedJobsCount} attached Job{chat.attachedJobsCount === 1 ? "" : "s"}
                    </span>
                  ) : null}
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
  if (!isPlainObject(parsed)) return null
  if (!Array.isArray(parsed.results) && !displayValue(parsed.message)) return null
  const results = Array.isArray(parsed.results) ? parsed.results : []
  const hits = results.flatMap((item, index) => {
    const hit = parseSearchHit(item, index)
    return hit ? [hit] : []
  })
  return { hits, message: displayValue(parsed.message), query: displayValue(context.input?.query), limit: numberValue(context.input?.limit) }
}

export function searchChatsCollapsedSummary(context: ToolCardContext) {
  const result = parseSearchChats(context)
  if (!result) return null
  const query = result.query ? `"${result.query}"` : "Chat search"
  return `${query} - ${result.hits.length} hit${result.hits.length === 1 ? "" : "s"}`
}

export function SearchChatsCard({ context }: { context: ToolCardContext }) {
  if (context.resultError) return <ErrorCard title="Could not search chats" message={displayValue(context.resultBody) ?? "The chat search request failed."} />
  const result = parseSearchChats(context)
  if (!result) return null
  if (result.hits.length === 0)
    return (
      <CardShell>
        {result.query ? <Row label="Query" value={result.query} /> : null}
        {result.limit != null ? <Row label="Limit" value={String(result.limit)} /> : null}
        <EmptyState>{result.message || "No matching messages found."}</EmptyState>
      </CardShell>
    )

  const matchCounts = new Map<string, number>()
  for (const hit of result.hits) matchCounts.set(hit.chatSessionId, (matchCounts.get(hit.chatSessionId) ?? 0) + 1)

  return (
    <CardShell>
      {result.query ? <Row label="Query" value={result.query} /> : null}
      {result.limit != null ? <Row label="Limit" value={String(result.limit)} /> : null}
      <div className="space-y-2">
        {result.hits.map((hit) => (
          <article className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={hit.key}>
            <div className="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-start sm:justify-between sm:gap-2">
              <div className="min-w-0 flex-1">
                <div className="break-words font-medium text-gray-900 dark:text-gray-100" title={hit.chatTitle}>
                  <ChatTitle chatId={hit.chatSessionId} messageId={hit.messageId} title={hit.chatTitle} />
                </div>
                <Metadata>
                  {hit.mode ? <Badge>{hit.mode}</Badge> : null}
                  {hit.repository ? (
                    <EntityReference kind="repository" repositoryId={hit.repositoryId} repositorySlug={hit.repository} />
                  ) : (
                    <span>No repository</span>
                  )}
                  {hit.role ? <Badge>{hit.role}</Badge> : null}
                  <span>
                    {matchCounts.get(hit.chatSessionId) ?? 1} match{(matchCounts.get(hit.chatSessionId) ?? 1) === 1 ? "" : "es"} in chat
                  </span>
                  {hit.attachedJobsCount != null ? (
                    <span>
                      {hit.attachedJobsCount} attached Job{hit.attachedJobsCount === 1 ? "" : "s"}
                    </span>
                  ) : null}
                </Metadata>
              </div>
              {hit.createdAt ? (
                <time className="text-2xs text-gray-500 dark:text-gray-400 sm:shrink-0" dateTime={hit.createdAt} title={hit.createdAt}>
                  {timestamp(hit.createdAt)}
                </time>
              ) : null}
            </div>
            {hit.chatDeletedAt || hit.messageDeletedAt ? (
              <div className="mt-1 flex flex-wrap gap-1">
                {hit.chatDeletedAt ? (
                  <span className="inline-flex flex-wrap items-center gap-1 text-2xs text-text-muted">
                    <StatePill state="deleted" />
                    <span>
                      Chat{hit.chatDeletedBy ? ` by ${hit.chatDeletedBy}` : ""} · {timestamp(hit.chatDeletedAt)}
                    </span>
                  </span>
                ) : null}
                {hit.messageDeletedAt ? (
                  <span className="inline-flex flex-wrap items-center gap-1 text-2xs text-text-muted">
                    <StatePill state="deleted" />
                    <span>
                      Message{hit.messageDeletedBy ? ` by ${hit.messageDeletedBy}` : ""} · {timestamp(hit.messageDeletedAt)}
                    </span>
                  </span>
                ) : null}
              </div>
            ) : null}
            {hit.attachedJobs.length > 0 ? (
              <div className="mt-2 flex flex-wrap gap-1.5">
                {hit.attachedJobs.map((job) => (
                  <span className="inline-flex min-h-7 max-w-full flex-wrap items-center gap-1 rounded border border-border px-2 py-1" key={job.id}>
                    <EntityReference id={job.id} kind="job" slug={job.slug} />
                    {job.title ? <span className="break-words text-text-secondary">{job.title}</span> : null}
                    {job.state ? <StatePill state={job.state} /> : null}
                    {job.repository ? <EntityReference kind="repository" repositoryId={job.repositoryId} repositorySlug={job.repository} /> : null}
                  </span>
                ))}
              </div>
            ) : null}
            {hit.snippet ? (
              <div className="mt-2">
                <MarkdownPreview
                  linkifySlugs
                  linkifyUrls
                  maxChars={SNIPPET_CHARS}
                  maxLines={3}
                  modalLabel={`Message match in ${hit.chatTitle}`}
                  text={hit.snippet}
                />
              </div>
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
    chatDeletedAt: displayValue(parsed.chat_session_deleted_at),
    chatDeletedBy: deletedBy(parsed.chat_session_deleted_by),
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
  if (context.resultError)
    return <ErrorCard title="Could not read chat messages" message={displayValue(context.resultBody) ?? "The chat messages request failed."} />
  const result = parseReadChatMessages(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {result.chatId ? (
          <ChatTitle chatId={result.chatId} title={result.chatTitle || `Chat ${result.chatId}`} />
        ) : (
          <span className="font-medium text-gray-900 dark:text-gray-100">{result.chatTitle || "Chat transcript"}</span>
        )}
        {result.page != null ? <Badge>page {result.page}</Badge> : null}
        {result.hasMore === true ? <Badge>more messages available</Badge> : result.hasMore === false ? <Badge>end of messages</Badge> : null}
      </div>
      {result.chatDeletedAt ? (
        <div className="flex min-w-0 flex-wrap items-center gap-1 text-2xs text-text-muted">
          <StatePill state="deleted" />
          <span className="break-words">
            Chat{result.chatDeletedBy ? ` by ${result.chatDeletedBy}` : ""} · {timestamp(result.chatDeletedAt)}
          </span>
        </div>
      ) : null}
      {result.messages.length === 0 ? (
        <EmptyState>No messages on this page.</EmptyState>
      ) : (
        <div>
          <SectionLabel>Transcript excerpt</SectionLabel>
          <div className="mt-1">
            <FilterableList
              itemText={(message) =>
                [message.role, message.createdAt, message.content, ...message.attachments.map((attachment) => attachment.name)].filter(Boolean).join(" ")
              }
              items={result.messages}
              placeholder="Filter messages"
            >
              {(messages) => (
                <ol className={TRANSCRIPT_LIST_CLASS}>
                  {messages.map((message) => (
                    <li className="min-w-0 overflow-hidden rounded border border-gray-100 p-2 dark:border-gray-800" key={message.id}>
                      <Metadata>
                        {message.role ? <Badge>{message.role}</Badge> : null}
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
                      {message.deletedAt ? (
                        <div className="mt-1 flex min-w-0 flex-wrap items-center gap-1 text-2xs text-text-muted">
                          <StatePill state="deleted" />
                          <span className="break-words">
                            Message{message.deletedBy ? ` by ${message.deletedBy}` : ""} · {timestamp(message.deletedAt)}
                          </span>
                        </div>
                      ) : null}
                      <div className="mt-1 min-w-0">
                        <MarkdownPreview
                          emptyState={message.attachments.length > 0 ? null : undefined}
                          linkifySlugs
                          linkifyUrls
                          maxChars={MESSAGE_CHARS}
                          maxLines={6}
                          modalLabel={`Message ${message.id}`}
                          text={message.content}
                        />
                      </div>
                      <MessageAttachments attachments={message.attachments} />
                    </li>
                  ))}
                </ol>
              )}
            </FilterableList>
          </div>
        </div>
      )}
      {result.hasMore && result.nextPage != null ? <div className="text-2xs text-text-muted">Next page: {result.nextPage}</div> : null}
    </CardShell>
  )
}
