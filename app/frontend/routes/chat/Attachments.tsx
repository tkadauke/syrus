import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { addChatAttachment, fetchChatContext, type ChatAttachmentResult, type ChatPayload } from "../../api/chats"
import { Button } from "../../components/Button"
import { Input } from "../../components/Input"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { type ChatQueryKey } from "./constants"
import { appendSearch, withRoutePrefix } from "./utils"

// AddAttachment: the composer's "+" popover picker for attaching a
// Repository/Epic/Job/Document to the chat's context. Search results come
// from GET .../context, scoped by type + query; picking one POSTs the
// attachment and refreshes the chat payload. This is the only reachable
// surface left in this file -- the full context panel it used to share with
// (grouped attachment lists + detach controls, in-scope documents) was
// removed with the Context tab. Repository chip detach lives in Compose.tsx.

const DEFAULT_ATTACHMENT_TYPES = ["Repository", "Epic", "Job", "Document"] as const

export function AddAttachment({ payload, prefix, queryKey, onAttached, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onAttached?: () => void; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const location = useLocation()
  const navigate = useNavigate()
  const params = new URLSearchParams(location.search)
  const attachmentTypes = DEFAULT_ATTACHMENT_TYPES
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
            className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-brand/10 hover:text-brand disabled:text-gray-300 dark:text-gray-300 dark:hover:bg-brand/10 dark:hover:text-brand-emphasis dark:disabled:text-gray-600"
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
