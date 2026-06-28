import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useEffect, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import {
  createMemory,
  deleteMemory,
  fetchMemories,
  publishMemory,
  unpublishMemory,
  updateMemory,
  type MemoriesPayload,
  type MemoryKind,
  type MemoryRow,
  type MemoryScope
} from "../api/memories"
import { CloseIcon } from "../components/CloseIcon"
import { FilterBar } from "../components/FilterBar"
import { NoticeToast } from "../components/NoticeToast"
import { Markdown } from "../lib/Markdown"

const kindLabels: Record<string, string> = {
  user_pref: "User pref",
  project_fact: "Project fact",
  feedback: "Feedback",
  reference: "Reference",
  decision: "Decision"
}

const kindClasses: Record<string, string> = {
  user_pref: "bg-blue-50 text-blue-700 ring-blue-200 dark:bg-blue-950 dark:text-blue-200 dark:ring-blue-800",
  project_fact: "bg-emerald-50 text-emerald-700 ring-emerald-200 dark:bg-emerald-950 dark:text-emerald-200 dark:ring-emerald-800",
  feedback: "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-950 dark:text-amber-200 dark:ring-amber-800",
  reference: "bg-slate-100 text-slate-700 ring-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:ring-slate-700",
  decision: "bg-fuchsia-50 text-fuchsia-700 ring-fuchsia-200 dark:bg-fuchsia-950 dark:text-fuchsia-200 dark:ring-fuchsia-800"
}

export function MemoriesRoute() {
  const location = useLocation()
  const search = location.search || ""
  const [notice, setNotice] = useState<string | null>(null)
  const memories = useQuery({
    queryKey: ["memories", search],
    queryFn: () => fetchMemories(search)
  })

  return (
    <main aria-label="Memories" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">Memories</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-600 dark:text-gray-400">Manage persistent agent memories for your account and repositories.</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {memories.isPending ? <PanelMessage>Loading memories...</PanelMessage> : null}
      {memories.isError ? <MemoriesError error={memories.error} /> : null}
      {memories.isSuccess ? <MemoriesView onNotice={setNotice} payload={memories.data} /> : null}
    </main>
  )
}

function MemoriesView({ payload, onNotice }: { payload: MemoriesPayload; onNotice: (message: string | null) => void }) {
  const location = useLocation()
  const [creating, setCreating] = useState(false)

  return (
    <>
      <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <FilterBar
            filter={payload.filter}
            filterSchema={payload.controls.filter_schema}
            legacyFilterKeys={["scope", "kind", "published", "search", "repository_id"]}
            pathname={location.pathname}
            search={location.search}
          />
          <button className="shrink-0 rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500" onClick={() => setCreating(true)} type="button">
            Create memory
          </button>
        </div>
      </section>
      <MemoriesTable onNotice={onNotice} payload={payload} />
      <MemoryPagination pagination={payload.pagination} />
      {creating ? <MemoryModal mode="create" onClose={() => setCreating(false)} onNotice={onNotice} payload={payload} /> : null}
    </>
  )
}

function MemoriesTable({ payload, onNotice }: { payload: MemoriesPayload; onNotice: (message: string | null) => void }) {
  const showOwner = payload.current_user.admin

  return (
    <section className="overflow-x-auto rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Kind</th>
            <th className="px-4 py-2">Scope</th>
            {showOwner ? <th className="px-4 py-2">Owner</th> : null}
            <th className="px-4 py-2">Content</th>
            <th className="px-4 py-2">Published</th>
            <th className="px-4 py-2">Created</th>
            <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
          {payload.memories.length === 0 ? (
            <tr><td className="px-4 py-6 text-center text-gray-500 dark:text-gray-400" colSpan={showOwner ? 7 : 6}>No memories match these filters.</td></tr>
          ) : payload.memories.map((memory) => (
            <MemoryRowView key={memory.id} memory={memory} onNotice={onNotice} payload={payload} showOwner={showOwner} />
          ))}
        </tbody>
      </table>
    </section>
  )
}

function MemoryRowView({ memory, payload, showOwner, onNotice }: { memory: MemoryRow; payload: MemoriesPayload; showOwner: boolean; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [viewing, setViewing] = useState(false)
  const [editing, setEditing] = useState(false)
  const publish = useMutation({
    mutationFn: () => memory.published ? unpublishMemory(memory.paths.app_publish_path) : publishMemory(memory.paths.app_publish_path),
    onSuccess: (payload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(payload.message || (memory.published ? "Memory unpublished." : "Memory published."))
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteMemory(memory.paths.app_memory_path),
    onSuccess: (payload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(payload.message || "Memory deleted.")
    }
  })

  return (
    <tr className="align-top">
      <td className="px-4 py-3"><KindBadge kind={memory.kind} /></td>
      <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{memory.scope === "global" ? "Global" : memory.repository_name || `Repository #${memory.scope_id}`}</td>
      {showOwner ? <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{memory.owner.name}</td> : null}
      <td className="max-w-2xl px-4 py-3 text-gray-800 dark:text-gray-200">
        <Markdown className="chat-prose line-clamp-2 text-sm text-gray-800 break-words dark:text-gray-200" text={memory.content} />
        {memory.content.length > 160 ? (
          <button className="mt-1 block text-xs text-blue-700 underline hover:no-underline dark:text-blue-300" onClick={() => setViewing(true)} type="button">
            See more
          </button>
        ) : null}
      </td>
      <td className="px-4 py-3">
        <span className={memory.published ? "text-green-700 dark:text-green-300" : "text-gray-500 dark:text-gray-400"}>{memory.published ? "Published" : "Unpublished"}</span>
      </td>
      <td className="px-4 py-3 text-gray-600 dark:text-gray-400">{formatDate(memory.created_at)}</td>
      <td className="px-4 py-3">
        <div className="flex justify-end gap-2">
          {memory.permissions.can_manage ? (
            <button className="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800" onClick={() => setEditing(true)} type="button">
              Edit
            </button>
          ) : null}
          {memory.permissions.can_publish ? (
            <button className="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800" disabled={publish.isPending} onClick={() => publish.mutate()} type="button">
              {memory.published ? "Unpublish" : "Publish"}
            </button>
          ) : null}
          {memory.permissions.can_manage ? (
            <button
              className="rounded border border-red-200 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:text-red-300 dark:border-red-900 dark:text-red-300 dark:hover:bg-red-950"
              disabled={destroy.isPending}
              onClick={() => {
                if (window.confirm("Delete this memory?")) {
                  onNotice(null)
                  destroy.mutate()
                }
              }}
              type="button"
            >
              {destroy.isPending ? "Deleting..." : "Delete"}
            </button>
          ) : null}
        </div>
        {publish.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(publish.error, "Unable to change publish state.")}</p> : null}
        {destroy.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(destroy.error, "Unable to delete memory.")}</p> : null}
        {viewing ? <MemoryContentModal memory={memory} onClose={() => setViewing(false)} /> : null}
        {editing ? <MemoryModal memory={memory} mode="edit" onClose={() => setEditing(false)} onNotice={onNotice} payload={payload} /> : null}
      </td>
    </tr>
  )
}

function MemoryContentModal({ memory, onClose }: { memory: MemoryRow; onClose: () => void }) {
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby={`memory-content-modal-title-${memory.id}`}
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-2xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="space-y-4 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id={`memory-content-modal-title-${memory.id}`}>Memory content</h2>
            <button
              aria-label="Close"
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>
          <Markdown className="chat-prose text-sm text-gray-800 break-words dark:text-gray-200" text={memory.content} />
        </div>
      </section>
    </div>
  )
}

function MemoryModal({ memory, mode, payload, onClose, onNotice }: { memory?: MemoryRow; mode: "create" | "edit"; payload: MemoriesPayload; onClose: () => void; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [kind, setKind] = useState<MemoryKind>(memory?.kind || payload.kinds[0] || "user_pref")
  const [scope, setScope] = useState<MemoryScope>(memory?.scope || "global")
  const [scopeId, setScopeId] = useState(memory?.scope_id ? String(memory.scope_id) : "")
  const [content, setContent] = useState(memory?.content || "")
  const title = mode === "create" ? "Create memory" : "Edit memory"
  const create = useMutation({
    mutationFn: () => createMemory({
      kind,
      scope,
      scope_id: scope === "repository" ? Number(scopeId) : null,
      content
    }),
    onSuccess: (nextPayload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(nextPayload.message || "Memory created.")
      onClose()
    }
  })
  const update = useMutation({
    mutationFn: () => updateMemory(memory?.paths.app_memory_path || "", { content, kind }),
    onSuccess: (nextPayload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(nextPayload.message || "Memory updated.")
      onClose()
    }
  })
  const pending = create.isPending || update.isPending
  const error = create.error || update.error

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  useEffect(() => {
    if (scope === "repository" && !scopeId && payload.repositories.length > 0) {
      setScopeId(String(payload.repositories[0].id))
    }
  }, [payload.repositories, scope, scopeId])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    if (mode === "create") create.mutate()
    else update.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby="memory-modal-title"
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <form className="space-y-5 p-5 sm:p-6" onSubmit={submit}>
          <div className="flex items-start justify-between gap-4">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="memory-modal-title">{title}</h2>
            <button
              aria-label="Close"
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <label className={labelClass()} htmlFor="memory-kind">
              Kind
              <select id="memory-kind" className={fieldClass()} onChange={(event) => setKind(event.target.value as MemoryKind)} value={kind}>
                {payload.kinds.map((option) => <option key={option} value={option}>{kindLabel(option)}</option>)}
              </select>
            </label>
            {mode === "create" ? (
              <label className={labelClass()} htmlFor="memory-scope">
                Scope
                <select id="memory-scope" className={fieldClass()} onChange={(event) => setScope(event.target.value as MemoryScope)} value={scope}>
                  {payload.scopes.map((option) => <option key={option} value={option}>{option === "global" ? "Global" : "Repository"}</option>)}
                </select>
              </label>
            ) : null}
          </div>

          {mode === "create" && scope === "repository" ? (
            <label className={labelClass()} htmlFor="memory-repository">
              Repository
              <select
                disabled={payload.repositories.length === 0}
                id="memory-repository"
                className={fieldClass()}
                onChange={(event) => setScopeId(event.target.value)}
                required
                value={scopeId}
              >
                {payload.repositories.length === 0 ? <option value="">No repositories</option> : null}
                {payload.repositories.map((repository) => <option key={repository.id} value={repository.id}>{repository.name}</option>)}
              </select>
            </label>
          ) : null}

          <label className={labelClass()} htmlFor="memory-content">
            Content
            <textarea
              id="memory-content"
              className={`${fieldClass()} min-h-40`}
              maxLength={2000}
              onChange={(event) => setContent(event.target.value)}
              required
              value={content}
            />
          </label>

          {error ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(error, mode === "create" ? "Unable to create memory." : "Unable to update memory.")}</p> : null}

          <div className="flex justify-end gap-2">
            <button className="rounded border border-gray-300 px-3.5 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800" onClick={onClose} type="button">
              Cancel
            </button>
            <button className="rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300" disabled={pending} type="submit">
              {pending ? "Saving..." : "Save"}
            </button>
          </div>
        </form>
      </section>
    </div>
  )
}

function MemoryPagination({ pagination }: { pagination: MemoriesPayload["pagination"] }) {
  const location = useLocation()
  const navigate = useNavigate()
  if (pagination.total_pages <= 1) return null

  const firstItem = (pagination.page - 1) * pagination.per_page + 1
  const lastItem = Math.min(pagination.page * pagination.per_page, pagination.total)

  function go(page: number) {
    const params = new URLSearchParams(location.search)
    params.set("page", String(page))
    navigate({ pathname: location.pathname, search: `?${params.toString()}` })
  }

  return (
    <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>Showing {firstItem}-{lastItem} of {pagination.total}</span>
      <div className="flex gap-2">
        {pagination.page > 1 ? (
          <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800" onClick={() => go(pagination.page - 1)} type="button">Previous</button>
        ) : <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600">Previous</span>}
        {pagination.page < pagination.total_pages ? (
          <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800" onClick={() => go(pagination.page + 1)} type="button">Next</button>
        ) : <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600">Next</span>}
      </div>
    </div>
  )
}

function KindBadge({ kind }: { kind: string }) {
  return <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ring-1 ${kindClasses[kind] || kindClasses.reference}`}>{kindLabel(kind)}</span>
}

function kindLabel(kind: string) {
  return kindLabels[kind] || kind
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function labelClass() {
  return "block text-xs font-medium uppercase text-gray-500 dark:text-gray-400"
}

function fieldClass() {
  return "mt-1 block w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 disabled:bg-gray-100 disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300 dark:disabled:bg-gray-800"
}

function PanelMessage({ children }: { children: string }) {
  return <section className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">{children}</section>
}

function MemoriesError({ error }: { error: unknown }) {
  return <section className="rounded border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">{errorMessage(error, "Unable to load memories.")}</section>
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiError) return error.message
  if (error instanceof Error) return error.message
  return fallback
}
