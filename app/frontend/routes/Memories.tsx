import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, KeyboardEvent } from "react"
import { useEffect, useMemo, useState } from "react"
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
import { NoticeToast } from "../components/NoticeToast"

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
  return (
    <>
      <CreateMemoryForm onNotice={onNotice} payload={payload} />
      <MemoryFilters kinds={payload.kinds} scopes={payload.scopes} />
      <MemoriesTable onNotice={onNotice} payload={payload} />
      <MemoryPagination pagination={payload.pagination} />
    </>
  )
}

function CreateMemoryForm({ payload, onNotice }: { payload: MemoriesPayload; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [kind, setKind] = useState<MemoryKind>(payload.kinds[0] || "user_pref")
  const [scope, setScope] = useState<MemoryScope>("global")
  const [scopeId, setScopeId] = useState("")
  const [content, setContent] = useState("")
  const create = useMutation({
    mutationFn: () => createMemory({
      kind,
      scope,
      scope_id: scope === "repository" ? Number(scopeId) : null,
      content
    }),
    onSuccess: (nextPayload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      setContent("")
      onNotice(nextPayload.message || "Memory created.")
    }
  })

  useEffect(() => {
    if (scope === "repository" && !scopeId && payload.repositories.length > 0) {
      setScopeId(String(payload.repositories[0].id))
    }
  }, [payload.repositories, scope, scopeId])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Create memory</h2>
      <form className="mt-3 grid gap-3 lg:grid-cols-[9rem_11rem_minmax(12rem,16rem)_minmax(0,1fr)_auto] lg:items-end" onSubmit={submit}>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="memory-kind">
          Kind
          <select id="memory-kind" className={fieldClass()} onChange={(event) => setKind(event.target.value as MemoryKind)} value={kind}>
            {payload.kinds.map((option) => <option key={option} value={option}>{kindLabel(option)}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="memory-scope">
          Scope
          <select id="memory-scope" className={fieldClass()} onChange={(event) => setScope(event.target.value as MemoryScope)} value={scope}>
            {payload.scopes.map((option) => <option key={option} value={option}>{option === "global" ? "Global" : "Repository"}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="memory-repository">
          Repository
          <select
            disabled={scope !== "repository" || payload.repositories.length === 0}
            id="memory-repository"
            className={fieldClass()}
            onChange={(event) => setScopeId(event.target.value)}
            required={scope === "repository"}
            value={scopeId}
          >
            {payload.repositories.length === 0 ? <option value="">No repositories</option> : null}
            {payload.repositories.map((repository) => <option key={repository.id} value={repository.id}>{repository.name}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="memory-content">
          Content
          <textarea
            id="memory-content"
            className={`${fieldClass()} min-h-10`}
            maxLength={2000}
            onChange={(event) => setContent(event.target.value)}
            required
            value={content}
          />
        </label>
        <button className="rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300" disabled={create.isPending} type="submit">
          {create.isPending ? "Creating..." : "Create"}
        </button>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(create.error, "Unable to create memory.")}</p> : null}
    </section>
  )
}

function MemoryFilters({ kinds, scopes }: { kinds: MemoryKind[]; scopes: MemoryScope[] }) {
  const location = useLocation()
  const navigate = useNavigate()
  const params = useMemo(() => new URLSearchParams(location.search), [location.search])
  const [q, setQ] = useState(params.get("q") || "")

  useEffect(() => {
    setQ(params.get("q") || "")
  }, [params])

  function setFilter(key: string, value: string) {
    const next = new URLSearchParams(location.search)
    if (value) next.set(key, value)
    else next.delete(key)
    next.delete("page")
    navigate({ pathname: location.pathname, search: next.toString() ? `?${next.toString()}` : "" })
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setFilter("q", q.trim())
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <form className="flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="filter-scope">
          Scope
          <select id="filter-scope" className={fieldClass()} onChange={(event) => setFilter("scope", event.target.value)} value={params.get("scope") || ""}>
            <option value="">All scopes</option>
            {scopes.map((scope) => <option key={scope} value={scope}>{scope === "global" ? "Global" : "Repository"}</option>)}
          </select>
        </label>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="filter-kind">
          Kind
          <select id="filter-kind" className={fieldClass()} onChange={(event) => setFilter("kind", event.target.value)} value={params.get("kind") || ""}>
            <option value="">All kinds</option>
            {kinds.map((kind) => <option key={kind} value={kind}>{kindLabel(kind)}</option>)}
          </select>
        </label>
        <label className="block min-w-64 text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="filter-q">
          Search
          <input id="filter-q" className={fieldClass()} onChange={(event) => setQ(event.target.value)} type="search" value={q} />
        </label>
        <button className="rounded border border-gray-300 px-3.5 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800" type="submit">Search</button>
      </form>
    </section>
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
            <MemoryRowView key={memory.id} memory={memory} onNotice={onNotice} showOwner={showOwner} />
          ))}
        </tbody>
      </table>
    </section>
  )
}

function MemoryRowView({ memory, showOwner, onNotice }: { memory: MemoryRow; showOwner: boolean; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [content, setContent] = useState(memory.content)
  const [kind, setKind] = useState<MemoryKind>(memory.kind)
  const [expanded, setExpanded] = useState(false)
  const update = useMutation({
    mutationFn: () => updateMemory(memory.paths.app_memory_path, { content, kind }),
    onSuccess: (payload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(payload.message || "Memory updated.")
      setEditing(false)
    }
  })
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

  function save() {
    if (!memory.permissions.can_manage) return
    if (update.isPending) return
    const trimmed = content.trim()
    if (trimmed && (trimmed !== memory.content || kind !== memory.kind)) update.mutate()
    else setEditing(false)
  }

  function keyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      save()
    } else if (event.key === "Escape") {
      setContent(memory.content)
      setKind(memory.kind)
      setEditing(false)
    }
  }

  return (
    <tr className="align-top">
      <td className="px-4 py-3">
        {editing ? (
          <select className={fieldClass()} onChange={(event) => setKind(event.target.value as MemoryKind)} value={kind}>
            {Object.keys(kindLabels).map((option) => <option key={option} value={option}>{kindLabel(option)}</option>)}
          </select>
        ) : <KindBadge kind={memory.kind} />}
      </td>
      <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{memory.scope === "global" ? "Global" : memory.repository_name || `Repository #${memory.scope_id}`}</td>
      {showOwner ? <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{memory.owner.name}</td> : null}
      <td className="max-w-2xl px-4 py-3">
        {editing ? (
          <>
            <textarea
              aria-label={`Content for memory ${memory.id}`}
              className={`${fieldClass()} min-h-24`}
              maxLength={2000}
              onBlur={save}
              onChange={(event) => setContent(event.target.value)}
              onKeyDown={keyDown}
              value={content}
            />
            {update.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, "Unable to update memory.")}</p> : null}
          </>
        ) : (
          <button
            className="block max-w-full text-left text-gray-800 hover:text-blue-700 disabled:hover:text-gray-800 dark:text-gray-200 dark:hover:text-blue-300"
            disabled={!memory.permissions.can_manage}
            onClick={() => memory.permissions.can_manage && setEditing(true)}
            type="button"
          >
            <span className={expanded ? "whitespace-pre-wrap" : "line-clamp-2 whitespace-pre-wrap"}>{memory.content}</span>
          </button>
        )}
        {!editing && memory.content.length > 160 ? (
          <button className="mt-1 text-xs text-blue-700 underline hover:no-underline dark:text-blue-300" onClick={() => setExpanded(!expanded)} type="button">
            {expanded ? "Collapse" : "Expand"}
          </button>
        ) : null}
      </td>
      <td className="px-4 py-3">
        <span className={memory.published ? "text-green-700 dark:text-green-300" : "text-gray-500 dark:text-gray-400"}>{memory.published ? "Published" : "Private"}</span>
      </td>
      <td className="px-4 py-3 text-gray-600 dark:text-gray-400">{formatDate(memory.created_at)}</td>
      <td className="px-4 py-3">
        <div className="flex justify-end gap-2">
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
      </td>
    </tr>
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
