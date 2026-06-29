import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ClipboardEvent, DragEvent, FormEvent, ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import { createChat, fetchNewChat, type ChatMessageAttachmentInput } from "../api/chats"
import { CloseIcon } from "../components/CloseIcon"
import { ImageAnnotationModal } from "../components/ImageAnnotationModal"
import { updateRecentChatCache } from "../lib/chatCache"

const CHAT_ATTACHMENT_MAX_BYTES = 5 * 1024 * 1024
const CHAT_ATTACHMENT_TOTAL_MAX_BYTES = 20 * 1024 * 1024
const CHAT_ATTACHMENT_ACCEPT = "image/jpeg,image/png,image/gif,image/webp,application/pdf"

type ChatComposeAttachment = ChatMessageAttachmentInput & { size: number }

export function ChatNewRoute() {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const prefix = routePrefix(location.pathname)
  const [repositoryId, setRepositoryId] = useState("")
  const [text, setText] = useState("")
  const [attachments, setAttachments] = useState<ChatComposeAttachment[]>([])
  const [annotatingIndex, setAnnotatingIndex] = useState<number | null>(null)
  const [attachmentError, setAttachmentError] = useState<string | null>(null)
  const [isDragOver, setIsDragOver] = useState(false)
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const form = useQuery({
    queryKey: ["chats", "new"],
    queryFn: fetchNewChat
  })
  const save = useMutation({
    mutationFn: () => createChat({ repositoryId, text, attachments }),
    onSuccess: (created) => {
      updateRecentChatCache(queryClient, created.chat, { prepend: true })
      navigate(withRoutePrefix(created.redirect_to, prefix))
    }
  })

  useEffect(() => {
    if (!form.isSuccess) return

    setRepositoryId(String(form.data.default_repository_id ?? ""))
  }, [form.isSuccess, form.data])

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

  function handleAttachmentChange(files: FileList | File[] | null) {
    const selectedFiles = Array.from(files || [])
    if (fileInputRef.current) fileInputRef.current.value = ""
    if (selectedFiles.length === 0) return

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

  function handlePaste(event: ClipboardEvent<HTMLFormElement>) {
    const files = Array.from(event.clipboardData.items)
      .filter((item) => item.kind === "file" && item.type.startsWith("image/"))
      .map((item) => item.getAsFile())
      .filter((file): file is File => file != null)
    if (files.length === 0) return

    event.preventDefault()
    handleAttachmentChange(files)
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

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (save.isPending || text.trim().length === 0) return

    const validationError = attachmentValidationMessage(attachments)
    if (validationError) {
      setAttachmentError(validationError)
      return
    }

    save.mutate()
  }

  return (
    <main aria-label="New chat" className="mx-auto flex min-h-[calc(100dvh-6rem)] max-w-3xl items-center p-6">
      <div className="w-full">
        {form.isPending ? <PanelMessage>Loading chat form...</PanelMessage> : null}
        {form.isError ? <PanelMessage tone="error">{errorMessage(form.error, "Unable to load chat form.")}</PanelMessage> : null}
        {save.isError ? <div className="mb-3"><PanelMessage tone="error">{errorMessage(save.error, "Unable to open chat.")}</PanelMessage></div> : null}
        {form.isSuccess ? (
          <form
            aria-label="Start a new chat"
            className={`rounded border border-gray-200 bg-white p-4 transition-shadow dark:border-gray-700 dark:bg-gray-900 ${isDragOver ? "ring-2 ring-blue-400 dark:ring-blue-500" : ""}`}
            onDragEnter={handleDragEnter}
            onDragLeave={handleDragLeave}
            onDragOver={handleDragOver}
            onDrop={handleDrop}
            onPaste={handlePaste}
            onSubmit={submit}
          >
            <div className="mb-4">
              <label className="mb-1 block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="new-chat-repository">Repository</label>
              <select
                className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:ring-blue-500 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100"
                disabled={save.isPending}
                id="new-chat-repository"
                onChange={(event) => setRepositoryId(event.target.value)}
                value={repositoryId}
              >
                <option value="">General chat</option>
                {form.data.repositories.map((repository) => (
                  <option key={repository.id} value={repository.id}>{repository.slug}</option>
                ))}
              </select>
            </div>
            {attachmentError ? <div className="mb-3 text-sm text-red-700 dark:text-red-300">{attachmentError}</div> : null}
            {attachments.length > 0 ? (
              <div className="mb-3 flex flex-wrap gap-2">
                {attachments.map((attachment, index) => (
                  <div className="flex max-w-full items-center gap-2 rounded border border-gray-200 bg-gray-50 px-2 py-1 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={`${attachment.name}-${index}`}>
                    {attachment.mimeType.startsWith("image/") ? (
                      <>
                        <button aria-label={`Annotate ${attachment.name}`} className="group relative rounded focus:outline-none focus:ring-2 focus:ring-blue-500" onClick={() => setAnnotatingIndex(index)} type="button">
                          <img alt="" className="h-10 w-10 rounded object-cover" src={attachment.dataUrl} />
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
                      <span aria-hidden="true" className="flex h-10 w-10 items-center justify-center rounded border border-gray-200 bg-white text-xs font-semibold text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">PDF</span>
                    )}
                    <span className="max-w-48 truncate" title={attachment.name}>{attachment.name}</span>
                    <button aria-label={`Remove ${attachment.name}`} className="rounded p-1 text-gray-500 hover:bg-gray-200 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-gray-100" onClick={() => removeAttachment(index)} type="button">
                      <CloseIcon className="h-3.5 w-3.5" />
                    </button>
                  </div>
                ))}
              </div>
            ) : null}
            <div className="flex items-end gap-3">
              <input
                accept={CHAT_ATTACHMENT_ACCEPT}
                aria-label="Chat attachments"
                className="hidden"
                disabled={save.isPending}
                multiple
                onChange={(event) => handleAttachmentChange(event.target.files)}
                ref={fileInputRef}
                type="file"
              />
              <button
                aria-label="Add attachment"
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded border border-gray-300 bg-white text-xl leading-none text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
                disabled={save.isPending}
                onClick={() => fileInputRef.current?.click()}
                type="button"
              >
                +
              </button>
              <textarea
                aria-label="First message"
                className="min-h-24 min-w-0 flex-1 resize-y rounded border border-gray-300 px-3 py-2 text-base leading-6 focus:border-blue-500 focus:ring-blue-500 disabled:bg-gray-50 sm:text-sm sm:leading-5 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500 dark:disabled:bg-gray-800"
                disabled={save.isPending}
                onChange={(event) => setText(event.target.value)}
                placeholder={repositoryId ? "Ask about this repository..." : "Ask anything, or attach a screenshot for context..."}
                required
                rows={4}
                value={text}
              />
              <button className={primaryButton()} disabled={save.isPending || text.trim().length === 0 || attachmentError != null} type="submit">{save.isPending ? "Sending..." : "Send"}</button>
            </div>
          </form>
        ) : null}
      </div>
    </main>
  )
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

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}

function primaryButton() {
  return "rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-60 dark:bg-blue-500 dark:hover:bg-blue-400"
}

function PencilIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  )
}
