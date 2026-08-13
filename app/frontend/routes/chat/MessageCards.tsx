import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { memo, useState } from "react"
import type { FormEvent, KeyboardEvent, MouseEvent } from "react"
import { useEffect, useRef } from "react"
import { Link } from "react-router-dom"
import { useDismissiblePopup } from "../../lib/useDismissiblePopup"
import { createChatBookmark, fetchSourceFileContent, sourceFileUrl, type ChatMessageItem, type ChatPayload, type ChatRenderItem, type ChatStructuredTool, type ChatSystemMessage, type ChatToolGroupItem } from "../../api/chats"
import { CloseIcon } from "../../components/CloseIcon"
import { FilePreviewModal } from "../../components/FilePreviewModal"
import { Markdown, PlainText } from "../../lib/Markdown"
import { linkifySlugs } from "../../lib/linkifySlugs"
import { highlightCode, inferToolResultLanguage } from "../../lib/syntaxHighlight"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { type ChatQueryKey } from "./constants"
import { TOOL_RESULT_PREVIEW_LINE_CHARS } from "./toolRendering"
import { appendSearch, primaryButton, secondaryButton, withRoutePrefix } from "./utils"
import { PendingActionCard, ProposalCard } from "./ProposalCards"
import type { ChatMessageImageAttachment } from "./messageDisplay"
import { attachmentDataUrl, formatMessageTimestamp } from "./messageDisplay"




// Message rendering extracted from Chat.tsx: a single chat message bubble and its
// image/file attachments, the image lightbox, the bookmark control, and the tool-
// group / structured-tool / system-message renderers. ChatMessage, ImageLightbox,
// and ToolGroup are the entry points the message stream renders. Depends only on
// leaf modules and shared UI imports; unused header imports were pruned.

export const ChatMessage = memo(function ChatMessage({ animateIn = false, item, payload, pendingActionIds, prefix, queryKey, readOnly = false, onNotice }: { animateIn?: boolean; item: Extract<ChatRenderItem, { type: "message" }>; payload: ChatPayload; pendingActionIds: Set<number>; prefix: string; queryKey: ChatQueryKey; readOnly?: boolean; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  // Motion-safe entrance; reduced-motion users stay at rest.
  const entranceClass = animateIn ? " motion-safe:animate-chat-message-in" : ""
  const [sourcePreview, setSourcePreview] = useState<WorkspaceFileLink | null>(null)

  function handleMarkdownLink(href: string, event: MouseEvent<HTMLAnchorElement>) {
    const resolved = resolveWorkspaceFileLink(href, payload)
    if (resolved) {
      event.preventDefault()
      setSourcePreview(resolved)
      return
    }

    if (workspaceHrefLooksLocal(href)) event.preventDefault()
  }

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
          <div className="px-0 py-1 sm:rounded sm:border sm:border-gray-200 sm:bg-white sm:px-4 sm:py-3 sm:dark:border-gray-700 sm:dark:bg-gray-900">
            <Markdown className="chat-prose text-gray-800 dark:text-gray-100" text={item.text} onLinkClick={handleMarkdownLink} />
          </div>
          <MessageImageAttachments attachments={item.attachments} />
          {!readOnly && item.proposal ? <ProposalCard proposal={item.proposal} prefix={prefix} queryKey={queryKey} onNotice={onNotice} /> : null}
          {!readOnly && !item.proposal && item.pending_action && !pendingActionIds.has(item.pending_action.id) ? <PendingActionCard pendingAction={item.pending_action} queryKey={queryKey} onNotice={onNotice} /> : null}
        </div>
        {sourcePreview ? <ChatSourcePreviewModal link={sourcePreview} payload={payload} onClose={() => setSourcePreview(null)} /> : null}
      </article>
    )
  }

  if (item.role === "system") {
    return <SystemMessage item={item.system || { tone: "neutral", label: "System", body: item.text }} prefix={prefix} />
  }

  return <StructuredTool tool={item.tool} fallback={item.text} />
})

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

export function ImageLightbox({ attachment, onClose }: { attachment: ChatMessageImageAttachment; onClose: () => void }) {
  const { t } = useT("chat")
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
          aria-label={t("aria_close_image")}
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

type WorkspaceFileLink = { path: string; line: number | null }

export function resolveWorkspaceFileLink(href: string, payload: ChatPayload): WorkspaceFileLink | null {
  const repository = payload.chat.repository
  const sourcePath = payload.paths.app_source_file_path
  if (!repository || !sourcePath) return null

  const [owner, repo] = repository.slug.split("/", 2)
  if (!owner || !repo) return null

  const pathname = workspacePathname(href)
  if (!pathname) return null

  const prefix = `/syrus-home/.syrus/chat-workspaces/${payload.chat.id}/repositories/${owner}/${repo}/`
  if (!pathname.startsWith(prefix)) return null

  const decoded = safeDecode(pathname.slice(prefix.length))
  if (!decoded || decoded.includes("\0")) return null

  const parsed = splitLineSuffix(decoded)
  if (parsed.path === "" || parsed.path.startsWith("/") || parsed.path.split("/").includes("..")) return null
  return parsed
}

function workspaceHrefLooksLocal(href: string) {
  return workspacePathname(href)?.startsWith("/syrus-home/.syrus/chat-workspaces/") ?? false
}

function workspacePathname(href: string) {
  if (href.startsWith("/")) return href
  try {
    const url = new URL(href, window.location.origin)
    if (url.origin !== window.location.origin) return null
    return url.pathname
  } catch (_error) {
    return null
  }
}

function safeDecode(value: string) {
  try {
    return decodeURIComponent(value)
  } catch (_error) {
    return null
  }
}

function splitLineSuffix(value: string): WorkspaceFileLink {
  const match = value.match(/^(.*):([1-9]\d*)$/)
  if (!match) return { path: value, line: null }
  return { path: match[1], line: Number.parseInt(match[2], 10) }
}

function ChatSourcePreviewModal({ link, payload, onClose }: { link: WorkspaceFileLink; payload: ChatPayload; onClose: () => void }) {
  const { t } = useT("chat")
  const sourcePath = payload.paths.app_source_file_path
  const rawBasePath = payload.paths.app_source_file_raw_path
  const rawHref = rawBasePath ? sourceFileUrl(rawBasePath, link.path) : "#"

  const fileContent = useQuery({
    queryKey: ["chat_source_file", sourcePath, link.path],
    queryFn: () => fetchSourceFileContent(sourcePath!, link.path),
    enabled: !!sourcePath
  })

  return (
    <FilePreviewModal
      line={link.line}
      onClose={onClose}
      path={link.path}
      query={fileContent}
      rawHref={rawHref}
      unavailableMessage={sourcePath ? null : t("source_preview_unavailable")}
    />
  )
}

// Only messages that ARRIVE while the thread is open animate in —
// the initially loaded history must render at rest (and older pages prepend
// with LOWER ids, so they can never satisfy the > check).
export function shouldAnimateMessageEntrance(messageId: number | null | undefined, initialMaxId: number | null): boolean {
  if (messageId == null || initialMaxId == null) return false
  return messageId > initialMaxId
}


function BookmarkControl({ item, payload, queryKey, onNotice }: { item: Extract<ChatRenderItem, { type: "message" }>; payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
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
                <button className={secondaryButton()} disabled={bookmark.isPending} onClick={() => setOpen(false)} type="button">{t("cancel")}</button>
                <button className={primaryButton()} disabled={bookmark.isPending} type="submit">{t("save")}</button>
              </div>
            </form>
          ) : null}
        </>
      ) : null}
    </div>
  )
}

export const ToolGroup = memo(function ToolGroup({ item, simpleMode = false }: { item: ChatToolGroupItem; simpleMode?: boolean }) {
  const [open, setOpen] = useState(false)

  if (simpleMode) {
    return (
      <div className="space-y-1">
        {item.calls.map((call) => (
          <div className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-gray-50 px-3 py-1 text-sm text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300" key={call.message_id}>
            <span aria-hidden="true" className={`h-2 w-2 rounded-full ${call.result_error ? "bg-amber-500" : "animate-pulse bg-blue-500"}`} />
            <span>{call.result_error ? "Hit a snag" : call.progress_label}</span>
          </div>
        ))}
      </div>
    )
  }

  const details = item.calls.map((call) => [call.detail, call.result_summary].filter(Boolean).join(" · ")).filter(Boolean).join(", ")
  return (
    <details className="group/tool" onToggle={(event) => setOpen(event.currentTarget.open)}>
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
            {open && call.result_body ? <HighlightedToolResult code={call.result_body} detail={call.detail} error={call.result_error} tool={item.tool} /> : null}
          </div>
        ))}
      </div>
    </details>
  )
})

function HighlightedToolResult({ code, detail, error, tool }: { code: string; detail: string; error: boolean; tool: string }) {
  const language = inferToolResultLanguage(detail, tool)
  const className = `mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 dark:text-gray-400 ${error ? "text-red-600 dark:text-red-300" : ""}`

  if (!language || error || hasLongLine(code)) return <pre className={className}>{code}</pre>

  return <pre className={className}>{highlightCode(code, language)}</pre>
}

function hasLongLine(value: string) {
  return value.split(/\r?\n/).some((line) => line.length >= TOOL_RESULT_PREVIEW_LINE_CHARS)
}

function StructuredTool({ tool, fallback }: { tool?: ChatStructuredTool; fallback: string }) {
  const name = tool?.name || "tool"
  const [open, setOpen] = useState(false)
  return (
    <details className="text-xs open:rounded open:border open:border-gray-200 open:bg-gray-50 dark:open:border-gray-700 dark:open:bg-gray-900" onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary className="flex cursor-pointer items-baseline gap-2 py-0.5 text-sm text-gray-700 hover:text-gray-900 group-open/tool:px-3 group-open/tool:py-2 dark:text-gray-300 dark:hover:text-gray-100">
        <span className="text-gray-400 dark:text-gray-500">▸</span>
        <span className="font-mono font-medium text-gray-900 dark:text-gray-100">{name}</span>
        {tool?.proposal_id ? <span className="text-gray-600 dark:text-gray-400">Proposal #{tool.proposal_id} {tool.proposal_state_label ? `created (${tool.proposal_state_label})` : ""}</span> : null}
      </summary>
      {open ? <pre className="overflow-x-auto px-3 pb-3 font-mono text-gray-700 whitespace-pre-wrap break-words dark:text-gray-300">{JSON.stringify(tool?.payload || fallback, null, 2)}</pre> : null}
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
  if (item.prominent) {
    return (
      <div className="flex justify-center">
        <div className={`w-full max-w-3xl rounded border px-4 py-3 text-sm shadow-sm ${colors[item.tone]}`} role={item.tone === "error" ? "alert" : "status"}>
          <div className="mb-1 text-xs font-semibold uppercase">{item.label}</div>
          <div className="break-words leading-relaxed">{linkifySlugs(item.body, { jobStyle: "copyable" })}</div>
          {item.cta ? (
            <Link className="mt-2 inline-block font-medium underline hover:no-underline" to={withRoutePrefix(item.cta.path, prefix)}>
              {item.cta.label}
            </Link>
          ) : null}
        </div>
      </div>
    )
  }

  return (
    <div className="flex justify-center">
      <div className={`inline-flex max-w-full items-center gap-2 rounded-full border px-3 py-1 text-xs ${colors[item.tone]}`}>
        <span className="shrink-0 rounded bg-white/70 px-1.5 py-0.5 font-medium uppercase tracking-wide dark:bg-black/25">{item.label}</span>
        <span className="min-w-0 break-words">{linkifySlugs(item.body, { jobStyle: "copyable" })}</span>
        {item.cta ? (
          <Link className="shrink-0 font-medium underline hover:no-underline" to={withRoutePrefix(item.cta.path, prefix)}>
            {item.cta.label}
          </Link>
        ) : null}
      </div>
    </div>
  )
}
