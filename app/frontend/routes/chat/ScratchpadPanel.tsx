import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { DragEvent } from "react"
import { useEffect, useRef, useState } from "react"
import "@excalidraw/excalidraw/index.css"
import { createScratchpadItem, deleteScratchpadItem, enqueueChatDraftMessage, reorderScratchpadItems, updateScratchpadItem, type ChatDraftMessage, type ChatMessageAttachmentInput, type ChatScratchpadItem } from "../../api/chats"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { EnqueueIcon } from "../../components/EnqueueIcon"
import { Input } from "../../components/Input"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { type ChatQueryKey } from "./constants"
import { appendSearch, errorAsError } from "./utils"
import { PencilIcon } from "./icons"




// Scratchpad panel extracted from Chat.tsx: the workspace scratchpad list and its
// item rows (inline add/edit/reorder/delete of scratchpad notes). ScratchpadPanel
// is the entry point the chat workspace renders. Depends only on leaf modules and
// shared UI imports; unused header imports were pruned after the move.

export function ScratchpadPanel({
  chatId,
  enqueuePath,
  items,
  open,
  queryKey,
  reorderPath,
  text,
  attachments,
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
  attachments: ChatMessageAttachmentInput[]
  onDismiss?: () => void
  onLoadToInput: (draft: ChatDraftMessage) => void
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
                  attachments={attachments}
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
            <Input
              ref={addInputRef}
              aria-label={t("scratchpad_add_placeholder")}
              className="min-h-8 flex-1"
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
            <Button
              disabled={create.isPending || addDraft.trim().length === 0}
              onClick={submitAdd}
              size="sm"
              variant="secondary"
            >
              {t("scratchpad_add")}
            </Button>
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
  attachments,
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
  attachments: ChatMessageAttachmentInput[]
  index: number
  isDragging: boolean
  item: ChatScratchpadItem
  queryKey: ChatQueryKey
  text: string
  onDragEnd: () => void
  onDragOver: (e: DragEvent<HTMLDivElement>) => void
  onDragStart: () => void
  onDrop: () => void
  onLoadToInput: (draft: ChatDraftMessage) => void
}) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(item.content)
  const itemDraft: ChatDraftMessage = { text: item.text ?? item.content, attachments: item.attachments || [] }
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
      const afterEnqueue = await enqueueChatDraftMessage(appendSearch(enqueuePath, search), itemDraft)
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
      if (text.trim().length > 0 || attachments.length > 0) {
        const stashed = await createScratchpadItem(chatId, text, attachments)
        queryClient.setQueryData(queryKey, stashed)
      }
      const deleted = await deleteScratchpadItem(item.app_delete_path)
      queryClient.setQueryData(queryKey, deleted)
      onLoadToInput(itemDraft)
    } catch (error) {
      setLoadError(errorMessage(errorAsError(error), "Could not load item."))
    } finally {
      setLoadPending(false)
    }
  }

  if (editing) {
    return (
      <div className="rounded border border-brand/30 bg-brand/10 p-2">
        {update.isError ? <div className="mb-2 text-xs text-red-700 dark:text-red-300">{errorMessage(update.error, "Could not update item.")}</div> : null}
        <textarea
          aria-label={t("scratchpad_edit_item")}
          className="min-h-16 w-full resize-y rounded border border-brand/30 bg-white px-2 py-1.5 text-xs focus:border-brand focus:ring-brand dark:bg-gray-950 dark:text-gray-100"
          onChange={(e) => setDraft(e.target.value)}
          value={draft}
        />
        <div className="mt-2 flex justify-end gap-2">
          <Button disabled={update.isPending} onClick={() => setEditing(false)} size="sm" variant="secondary">{t("scratchpad_cancel")}</Button>
          <Button disabled={update.isPending || (draft.trim().length === 0 && (item.attachments || []).length === 0)} onClick={() => update.mutate()} size="sm" variant="primary">{t("scratchpad_save")}</Button>
        </div>
      </div>
    )
  }

  return (
    <div>
      <div
        className={`flex items-start gap-1.5 rounded border px-2 py-1.5 transition-colors ${isDragging ? "opacity-40" : ""} ${dragTarget ? "border-brand bg-brand/10" : "border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800"}`}
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
            className={`w-full text-left text-xs transition-colors ${loadPending ? "text-gray-400 dark:text-gray-500" : "text-gray-700 hover:text-brand dark:text-gray-200"}`}
            disabled={loadPending || remove.isPending}
            onClick={() => void handleLoad()}
            title={t("scratchpad_load")}
            type="button"
          >
            <span className="line-clamp-2 whitespace-pre-wrap break-words">{item.content || t("attachment_only_draft")}</span>
          </button>
          <DraftAttachmentIndicator attachments={item.attachments || []} />
          {loadError ? <p className="mt-0.5 text-xs text-red-600 dark:text-red-400">{loadError}</p> : null}
        </div>

        <div className="flex shrink-0 items-center gap-0.5">
          <button
            aria-label={t("scratchpad_queue_item")}
            className="rounded p-0.5 text-gray-400 hover:bg-white hover:text-brand disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:disabled:text-gray-700"
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

function DraftAttachmentIndicator({ attachments }: { attachments: ChatDraftMessage["attachments"] }) {
  if (!attachments || attachments.length === 0) return null

  const imageCount = attachments.filter((attachment) => attachment.mime_type.startsWith("image/")).length
  const label = imageCount === attachments.length
    ? `${attachments.length} image${attachments.length === 1 ? "" : "s"}`
    : `${attachments.length} attachment${attachments.length === 1 ? "" : "s"}`

  return (
    <span className="mt-1 inline-flex max-w-full items-center gap-1 rounded border border-gray-200 bg-white px-1.5 py-0.5 text-[11px] text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">
      <span aria-hidden="true">+</span>
      <span className="truncate">{label}</span>
    </span>
  )
}
