import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import { addChatAttachment, deleteChatAttachment, fetchChatContext, type ChatAttachmentResult, type ChatAttachmentRow, type ChatContextPayload, type ChatPayload } from "../../api/chats"
import { Button } from "../../components/Button"
import { Input } from "../../components/Input"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { type ChatQueryKey } from "./constants"
import { appendSearch, isSupervisorChat, withRoutePrefix } from "./utils"




// Attachment UI extracted from Chat.tsx: the workspace attachment list
// (Attachments + AttachmentGroup) and the AddAttachment picker/popover.
// Attachments is rendered by the workspace context tab and the composer;
// AddAttachment by the composer. Depends only on leaf modules and shared UI
// imports; unused header imports were pruned after the move.

const DEFAULT_ATTACHMENT_TYPES = ["Repository", "Epic", "Job", "Document"] as const
const SUPERVISOR_ATTACHMENT_TYPES = ["Document"] as const
const EMPTY_ATTACHMENT_GROUPS = { repositories: [], epics: [], jobs: [], documents: [] } satisfies NonNullable<ChatPayload["attachment_groups"]>

export function Attachments({ payload, queryKey, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const contextPayload = useChatContextPayload(payload, queryKey)
  const supervisorChat = isSupervisorChat(payload)
  const attachmentGroups = contextPayload.attachment_groups ?? EMPTY_ATTACHMENT_GROUPS
  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("attachments")}</h2>
      </div>
      <div className="space-y-4">
        {supervisorChat ? null : (
          <>
            <AttachmentGroup label="Repos" rows={attachmentGroups.repositories} queryKey={queryKey} onNotice={onNotice} />
            <AttachmentGroup label="Epics" rows={attachmentGroups.epics} queryKey={queryKey} onNotice={onNotice} />
            <AttachmentGroup label="Jobs" rows={attachmentGroups.jobs} queryKey={queryKey} onNotice={onNotice} />
          </>
        )}
        <AttachmentGroup label="Documents" rows={attachmentGroups.documents} queryKey={queryKey} onNotice={onNotice} />
      </div>
      <section>
        <div className="mb-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">In-scope documents</div>
        {(contextPayload.documents_in_scope ?? []).length > 0 ? (
          <div className="space-y-1">
            {(contextPayload.documents_in_scope ?? []).map((document) => (
              <div className="rounded border border-gray-200 px-2 py-1.5 text-xs dark:border-gray-700" key={document.id}>
                <div className="font-medium text-gray-800 dark:text-gray-100">{document.title}</div>
                <div className="font-mono text-2xs text-gray-500 dark:text-gray-400">{document.repository_slug}</div>
              </div>
            ))}
          </div>
        ) : <div className="text-xs text-gray-400 dark:text-gray-500">No documents in scope.</div>}
      </section>
    </>
  )
}

function useChatContextPayload(payload: ChatPayload, queryKey: ChatQueryKey): ChatContextPayload {
  const contextPath = chatContextPath(payload)
  const queryClient = useQueryClient()
  const context = useQuery({
    queryKey: ["chat-context", String(payload.chat.id), queryKey[2]],
    queryFn: ({ signal }) => fetchChatContext(appendSearch(contextPath, queryKey[2]), { signal }),
    initialData: hasContextPayload(payload) ? {
      attachment_groups: payload.attachment_groups ?? EMPTY_ATTACHMENT_GROUPS,
      documents_in_scope: payload.documents_in_scope ?? [],
      attachment_results: payload.attachment_results ?? []
    } : undefined
  })

  useEffect(() => {
    const data = context.data
    if (!data) return

    queryClient.setQueriesData<ChatPayload>({ queryKey: ["chats", String(payload.chat.id)] }, (current) => current ? {
      ...current,
      attachment_groups: data.attachment_groups,
      documents_in_scope: data.documents_in_scope,
      attachment_results: data.attachment_results
    } : current)
  }, [context.data, payload.chat.id, queryClient])

  return context.data ?? emptyContextPayload()
}

function hasContextPayload(payload: ChatPayload) {
  return (payload.documents_in_scope ?? []).length > 0 ||
    (payload.attachment_results ?? []).length > 0 ||
    Object.values(payload.attachment_groups ?? EMPTY_ATTACHMENT_GROUPS).some((rows) => rows.length > 0)
}

function emptyContextPayload(): ChatContextPayload {
  return {
    attachment_groups: EMPTY_ATTACHMENT_GROUPS,
    documents_in_scope: [],
    attachment_results: []
  }
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
      {(rows ?? []).length > 0 ? (
        <div className="space-y-1">
          {(rows ?? []).map((row) => {
            const rowId = String(row.id)
            const pending = pendingDetachId === rowId
            return (
              <div className="flex items-center gap-2" key={row.id}>
                <Button
                  className={`w-full !justify-start text-left disabled:text-gray-300 dark:disabled:text-gray-600 ${pending ? "!border-red-200 !bg-red-50 !text-red-700 dark:!border-red-800 dark:!bg-red-950 dark:!text-red-300" : "hover:!border-red-200 hover:!bg-red-50 hover:!text-red-700 dark:hover:!border-red-800 dark:hover:!bg-red-950 dark:hover:!text-red-300"}`}
                  disabled={detach.isPending}
                  onClick={() => {
                    if (pending) {
                      setPendingDetachId(null)
                      detach.mutate(row.app_detach_path)
                    } else {
                      setPendingDetachId(rowId)
                    }
                  }}
                  size="sm"
                  title={`Detach ${row.label}`}
                  variant="secondary"
                >
                  {pending ? `Detach ${row.label}?` : row.label}
                </Button>
                {pending ? (
                  <Button
                    disabled={detach.isPending}
                    onClick={() => setPendingDetachId(null)}
                    size="sm"
                    variant="secondary"
                  >
                    Cancel
                  </Button>
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

export function AddAttachment({ payload, prefix, queryKey, onAttached, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onAttached?: () => void; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const location = useLocation()
  const navigate = useNavigate()
  const params = new URLSearchParams(location.search)
  const attachmentTypes = isSupervisorChat(payload) ? SUPERVISOR_ATTACHMENT_TYPES : DEFAULT_ATTACHMENT_TYPES
  type AttachmentType = typeof attachmentTypes[number]
  const initialType = normalizeAttachmentType(params.get("attachment_type"), attachmentTypes)
  const [type, setType] = useState<AttachmentType>(initialType)
  const [query, setQuery] = useState(params.get("attachment_query") || "")
  const contextPath = chatContextPath(payload)
  const contextSearch = useMemo(() => {
    const next = new URLSearchParams(location.search)
    next.set("attachment_type", type)
    if (query.trim()) next.set("attachment_query", query.trim())
    return `?${next.toString()}`
  }, [location.search, query, type])
  const context = useQuery({
    queryKey: ["chat-context", String(payload.chat.id), contextSearch],
    queryFn: ({ signal }) => fetchChatContext(appendSearch(contextPath, contextSearch), { signal }),
    enabled: true
  })
  const attachmentResults = (context.data?.attachment_results ?? payload.attachment_results ?? []).filter((record) => attachmentTypes.some((attachmentType) => attachmentType === record.type))
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
    setType(normalizeAttachmentType(next.get("attachment_type"), attachmentTypes))
    setQuery(next.get("attachment_query") || "")
  }, [attachmentTypes, location.search])

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

  function submitWithType(nextType: AttachmentType) {
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
          {attachmentTypes.map((nextType) => (
            <Button
              key={nextType}
              onClick={() => {
                setType(nextType)
                submitWithType(nextType)
              }}
              size="sm"
              variant={type === nextType ? "primary" : "secondary"}
            >
              {nextType === "Repository" ? "Repo" : nextType === "Document" ? "Doc" : nextType}
            </Button>
          ))}
        </div>
        <div className="px-2 pb-2">
          <Input
            autoFocus
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
            placeholder={t("ph_search_name_id")}
            ref={searchInputRef}
            type="search"
            value={query}
          />
        </div>
      </div>
      <div className="space-y-0 border-t border-gray-100 dark:border-gray-800">
        {attachmentResults.length > 0 ? attachmentResults.map((record) => (
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

function chatContextPath(payload: ChatPayload) {
  return payload.paths.app_context_path || `/api/v1/app/chats/${payload.chat.id}/context`
}

function normalizeAttachmentType<T extends readonly string[]>(candidate: string | null, allowed: T): T[number] {
  return allowed.includes(candidate || "") ? candidate as T[number] : allowed[0]
}
