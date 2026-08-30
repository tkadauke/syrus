import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useRef, useState, type ChangeEvent } from "react"
import { useLocation, useNavigate, useParams } from "react-router-dom"
import { Button } from "@app/components/Button"
import { Input } from "@app/components/Input"
import { Select } from "@app/components/Select"
import { PageHeading, SectionHeading } from "@app/components/Heading"
import { Markdown } from "@app/lib/Markdown"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { fetchRepositories } from "@app/api/repositories"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix } from "@app/lib/routing"
import {
  acceptDesignDocSuggestion,
  createDesignDoc,
  createDesignDocComment,
  createDesignDocSuggestion,
  fetchDesignDoc,
  fetchDesignDocs,
  fetchDesignDocVersions,
  fetchRepositoryDesignDocs,
  rejectDesignDocSuggestion,
  resolveDesignDocThread,
  updateDesignDoc,
  type DesignDocDetail,
  type DesignDocSummary
} from "../api/designDocs"

type SurfaceMode = "index" | "repository" | "chat"
type SelectionRange = { start: number; end: number; text: string }

export function DesignDocsSurface({ chatId, compact = false, designDocIds, mode, repositoryId }: { chatId?: number; compact?: boolean; designDocIds?: number[]; mode: SurfaceMode; repositoryId?: string | number }) {
  const params = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const id = params.id
  const [selectedId, setSelectedId] = useState<string | number | null>(id || null)
  const effectiveId = id || selectedId
  const queryClient = useQueryClient()
  const indexQuery = useQuery({
    queryKey: mode === "repository" ? ["design_docs", "repository", String(repositoryId)] : ["design_docs"],
    queryFn: () => mode === "repository" && repositoryId ? fetchRepositoryDesignDocs(repositoryId) : fetchDesignDocs()
  })
  const detailQuery = useQuery({
    queryKey: ["design_docs", "detail", String(effectiveId || "")],
    queryFn: () => fetchDesignDoc(effectiveId || ""),
    enabled: Boolean(effectiveId)
  })
  const repositoriesQuery = useQuery({
    queryKey: ["repositories"],
    queryFn: fetchRepositories,
    staleTime: 60_000
  })
  const [filters, setFilters] = useState({ repository: mode === "repository" && repositoryId ? String(repositoryId) : "all", owner: "all", state: "all", visibility: "all", updated: "all" })
  const [notice, setNotice] = useState<string | null>(null)
  const docs = useMemo(() => filterDocs(indexQuery.data?.design_docs ?? [], filters, chatId, designDocIds), [chatId, designDocIds, filters, indexQuery.data])
  const selectedDoc = detailQuery.data?.design_doc ?? null
  const repositoryOptions = repositoriesQuery.data?.active_repositories ?? []

  const createMutation = useMutation({
    mutationFn: () => createDesignDoc({
      title: "Untitled design doc",
      markdown: "# Untitled design doc\n\n",
      visibility: "private",
      state: "draft",
      origin_chat_session_id: chatId,
      repository_ids: repositoryId ? [Number(repositoryId)] : []
    }),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey: ["design_docs"] })
      setNotice("Design doc created.")
      if (mode === "chat") setSelectedId(payload.design_doc.id)
      else navigate(`${prefix}/design_docs/${payload.design_doc.id}`)
    }
  })

  return (
    <main aria-label="Design docs" className={compact ? "space-y-4" : "mx-auto max-w-[100rem] space-y-6 p-6"}>
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          {compact ? <SectionHeading>Design Docs</SectionHeading> : <PageHeading>Design Docs</PageHeading>}
          <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
            {mode === "chat" ? "Docs from this chat workspace." : mode === "repository" ? "Docs associated with this repository." : "Collaborative Markdown design documents."}
          </p>
        </div>
        <Button disabled={createMutation.isPending} onClick={() => createMutation.mutate()} size="sm">
          New doc
        </Button>
      </header>
      {notice ? <div className="rounded border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200">{notice}</div> : null}
      <div className={`grid min-h-0 gap-4 ${compact ? "xl:grid-cols-[18rem_minmax(0,1fr)]" : "lg:grid-cols-[20rem_minmax(0,1fr)]"}`}>
        <DesignDocList
          docs={docs}
          filters={filters}
          loading={indexQuery.isPending}
          mode={mode}
          repositoryOptions={repositoryOptions}
          selectedId={effectiveId}
          setFilters={setFilters}
          onSelect={(docId) => mode === "chat" ? setSelectedId(docId) : navigate(`${prefix}/design_docs/${docId}`)}
        />
        <section className="min-w-0">
          {detailQuery.isError ? <Panel tone="error">{errorMessage(detailQuery.error, "Unable to load design doc.")}</Panel> : null}
          {!effectiveId && !detailQuery.isError ? <Panel>Select a design doc to review or edit.</Panel> : null}
          {detailQuery.isPending && effectiveId ? <Panel>Loading design doc...</Panel> : null}
          {selectedDoc ? (
            <DesignDocEditor
              doc={selectedDoc}
              key={selectedDoc.id}
              mode={mode}
              repositories={repositoryOptions.map((repository) => ({ id: repository.id, slug: repository.slug }))}
              onDocChange={(nextDoc, message) => {
                queryClient.setQueryData(["design_docs", "detail", String(nextDoc.id)], { design_doc: nextDoc })
                void queryClient.invalidateQueries({ queryKey: ["design_docs"] })
                setNotice(message)
              }}
            />
          ) : null}
        </section>
      </div>
    </main>
  )
}

function DesignDocList({ docs, filters, loading, mode, repositoryOptions, selectedId, setFilters, onSelect }: {
  docs: DesignDocSummary[]
  filters: { repository: string; owner: string; state: string; visibility: string; updated: string }
  loading: boolean
  mode: SurfaceMode
  repositoryOptions: Array<{ id: number; slug: string }>
  selectedId: string | number | null
  setFilters: (filters: { repository: string; owner: string; state: string; visibility: string; updated: string }) => void
  onSelect: (id: number) => void
}) {
  const owners = Array.from(new Set(docs.map((doc) => doc.owner?.name).filter(Boolean))).sort()
  return (
    <aside className="min-w-0 space-y-3">
      <div className="grid gap-2 rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900">
        {mode === "repository" ? null : (
          <Select aria-label="Repository filter" value={filters.repository} onChange={(event) => setFilters({ ...filters, repository: event.target.value })}>
            <option value="all">All repositories</option>
            {repositoryOptions.map((repository) => <option key={repository.id} value={repository.id}>{repository.slug}</option>)}
          </Select>
        )}
        <Select aria-label="Owner filter" value={filters.owner} onChange={(event) => setFilters({ ...filters, owner: event.target.value })}>
          <option value="all">All owners</option>
          {owners.map((owner) => <option key={owner} value={owner}>{owner}</option>)}
        </Select>
        <div className="grid grid-cols-2 gap-2">
          <Select aria-label="State filter" value={filters.state} onChange={(event) => setFilters({ ...filters, state: event.target.value })}>
            <option value="all">All states</option>
            <option value="draft">Draft</option>
            <option value="accepted">Accepted</option>
            <option value="archived">Archived</option>
          </Select>
          <Select aria-label="Visibility filter" value={filters.visibility} onChange={(event) => setFilters({ ...filters, visibility: event.target.value })}>
            <option value="all">All visibility</option>
            <option value="public">Public</option>
            <option value="private">Private</option>
          </Select>
        </div>
        <Select aria-label="Recently updated filter" value={filters.updated} onChange={(event) => setFilters({ ...filters, updated: event.target.value })}>
          <option value="all">Any update time</option>
          <option value="7">Updated in 7 days</option>
          <option value="30">Updated in 30 days</option>
        </Select>
      </div>
      <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        {loading ? <div className="p-4 text-sm text-gray-600 dark:text-gray-400">Loading design docs...</div> : null}
        {!loading && docs.length === 0 ? <div className="p-4 text-sm text-gray-600 dark:text-gray-400">No visible design docs match these filters.</div> : null}
        {docs.map((doc) => (
          <button
            className={`block w-full border-b border-gray-100 p-3 text-left last:border-b-0 dark:border-gray-800 ${String(selectedId) === String(doc.id) ? "bg-blue-50 dark:bg-blue-950/30" : "hover:bg-gray-50 dark:hover:bg-gray-800/70"}`}
            key={doc.id}
            onClick={() => onSelect(doc.id)}
            type="button"
          >
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{doc.title}</p>
                <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{doc.display_id}</p>
              </div>
              <StatusLabel value={doc.state} />
            </div>
            <p className="mt-2 truncate text-xs text-gray-500 dark:text-gray-400">{doc.repositories.map((repository) => repository.slug).join(", ") || "No repositories"}</p>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">Updated <RelativeTimestamp value={doc.updated_at} /></p>
          </button>
        ))}
      </div>
    </aside>
  )
}

function DesignDocEditor({ doc, mode, repositories, onDocChange }: { doc: DesignDocDetail; mode: SurfaceMode; repositories: Array<{ id: number; slug: string }>; onDocChange: (doc: DesignDocDetail, message: string) => void }) {
  const [draft, setDraft] = useState(doc.markdown)
  const [title, setTitle] = useState(doc.title)
  const [summary, setSummary] = useState("")
  const [selection, setSelection] = useState<SelectionRange>({ start: 0, end: 0, text: "" })
  const [commentBody, setCommentBody] = useState("")
  const [suggestionMarkdown, setSuggestionMarkdown] = useState("")
  const [collaborators, setCollaborators] = useState(doc.collaborator_ids.join(", "))
  const [repoIds, setRepoIds] = useState(doc.repository_ids.map(String))
  const [versionsOpen, setVersionsOpen] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const versions = useQuery({
    queryKey: ["design_docs", "versions", String(doc.id)],
    queryFn: () => fetchDesignDocVersions(doc.id),
    enabled: versionsOpen
  })
  const saveMutation = useMutation({
    mutationFn: () => updateDesignDoc(doc.id, {
      title,
      markdown: draft,
      change_summary: summary,
      visibility: doc.visibility,
      state: doc.state,
      repository_ids: repoIds.map(Number),
      collaborator_user_ids: collaborators.split(",").map((part) => part.trim()).filter(Boolean).map(Number)
    }),
    onSuccess: (payload) => onDocChange(payload.design_doc, payload.mode === "suggestion" ? "Saved as a suggestion for owner review." : "Design doc saved.")
  })
  const metadataMutation = useMutation({
    mutationFn: (input: { visibility?: "private" | "public"; state?: "draft" | "accepted" | "archived"; repository_ids?: number[] }) => updateDesignDoc(doc.id, input),
    onSuccess: (payload) => onDocChange(payload.design_doc, "Design doc controls updated.")
  })
  const commentMutation = useMutation({
    mutationFn: () => createDesignDocComment(doc.id, { body: commentBody, ...anchorPayload(selection) }),
    onSuccess: (payload) => {
      setCommentBody("")
      onDocChange(payload.design_doc, "Comment added.")
    }
  })
  const suggestionMutation = useMutation({
    mutationFn: () => createDesignDocSuggestion(doc.id, { original_markdown: selection.text, proposed_markdown: suggestionMarkdown, change_summary: summary, ...anchorPayload(selection) }),
    onSuccess: (payload) => {
      setSuggestionMarkdown("")
      onDocChange(payload.design_doc, "Suggestion created.")
    }
  })
  const reviewMutation = useMutation({
    mutationFn: ({ id, decision }: { id: number; decision: "accept" | "reject" }) => decision === "accept" ? acceptDesignDocSuggestion(doc.id, id) : rejectDesignDocSuggestion(doc.id, id),
    onSuccess: (payload) => onDocChange(payload.design_doc, payload.message || "Suggestion reviewed.")
  })
  const resolveMutation = useMutation({
    mutationFn: (threadId: number) => resolveDesignDocThread(doc.id, threadId),
    onSuccess: () => onDocChange({ ...doc, threads: doc.threads.map((thread) => thread.state === "open" ? { ...thread, state: "resolved" } : thread) }, "Thread resolved.")
  })

  function updateSelection(event?: ChangeEvent<HTMLTextAreaElement>) {
    const target = event?.target ?? textareaRef.current
    if (!target) return
    const start = target.selectionStart
    const end = target.selectionEnd
    setSelection({ start, end, text: target.value.slice(start, end) })
  }

  return (
    <div className={`grid min-w-0 gap-4 ${mode === "chat" ? "" : "xl:grid-cols-[minmax(0,1fr)_22rem]"}`}>
      <section className="min-w-0 space-y-4">
        <div className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0 flex-1">
              <Input aria-label="Design doc title" value={title} onChange={(event) => setTitle(event.target.value)} />
              <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">
                {doc.display_id} / v{doc.current_version_number ?? "?"} / {doc.visibility} / {doc.state} / saved <RelativeTimestamp value={doc.updated_at} />
              </p>
            </div>
            <Button disabled={saveMutation.isPending} onClick={() => saveMutation.mutate()} size="sm">Save</Button>
          </div>
          <div className="mt-3 grid gap-2 sm:grid-cols-[1fr_auto_auto]">
            <Input aria-label="Change summary" placeholder="Change summary" value={summary} onChange={(event) => setSummary(event.target.value)} />
            <Select aria-label="Visibility" fullWidth={false} value={doc.visibility} onChange={(event) => metadataMutation.mutate({ visibility: event.target.value as "private" | "public" })}>
              <option value="private">Private</option>
              <option value="public">Public</option>
            </Select>
            <Select aria-label="State" fullWidth={false} value={doc.state} onChange={(event) => metadataMutation.mutate({ state: event.target.value as "draft" | "accepted" | "archived" })}>
              <option value="draft">Draft</option>
              <option value="accepted">Accepted</option>
              <option value="archived">Archived</option>
            </Select>
          </div>
        </div>
        <div className="grid min-h-[36rem] gap-4 lg:grid-cols-2">
          <label className="flex min-h-0 flex-col rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
            <span className="border-b border-gray-200 px-3 py-2 text-xs font-semibold uppercase text-gray-500 dark:border-gray-700 dark:text-gray-400">Editor</span>
            <textarea
              aria-label="Markdown editor"
              className="min-h-[30rem] flex-1 resize-y bg-transparent p-4 font-mono text-sm leading-6 text-gray-900 outline-none dark:text-gray-100"
              onBlur={() => updateSelection()}
              onChange={(event) => setDraft(event.target.value)}
              onKeyUp={() => updateSelection()}
              onMouseUp={() => updateSelection()}
              ref={textareaRef}
              value={draft}
            />
          </label>
          <div className="min-h-0 rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
            <div className="border-b border-gray-200 px-3 py-2 text-xs font-semibold uppercase text-gray-500 dark:border-gray-700 dark:text-gray-400">Preview</div>
            <DocumentPreview doc={doc} markdown={draft} />
          </div>
        </div>
        <FloatingComposer
          commentBody={commentBody}
          disabled={selection.end <= selection.start}
          selection={selection}
          setCommentBody={setCommentBody}
          setSuggestionMarkdown={setSuggestionMarkdown}
          suggestionMarkdown={suggestionMarkdown}
          onComment={() => commentMutation.mutate()}
          onSuggestion={() => suggestionMutation.mutate()}
        />
      </section>
      <aside className="space-y-4">
        <ThreadPanel doc={doc} onResolve={(threadId) => resolveMutation.mutate(threadId)} />
        <SuggestionPanel doc={doc} onReview={(id, decision) => reviewMutation.mutate({ id, decision })} />
        <ControlsPanel collaborators={collaborators} doc={doc} repoIds={repoIds} repositories={repositories} setCollaborators={setCollaborators} setRepoIds={setRepoIds} onSave={() => metadataMutation.mutate({ repository_ids: repoIds.map(Number) })} />
        <VersionPanel open={versionsOpen} versions={versions.data?.versions ?? []} loading={versions.isPending} onToggle={() => setVersionsOpen(!versionsOpen)} />
      </aside>
    </div>
  )
}

function DocumentPreview({ doc, markdown }: { doc: DesignDocDetail; markdown: string }) {
  const anchors = [
    ...doc.threads.filter((thread) => thread.state === "open").map((thread) => ({ kind: "comment", start: thread.anchor.last_known_start_offset ?? thread.anchor.start_offset, end: thread.anchor.last_known_end_offset ?? thread.anchor.end_offset })),
    ...doc.suggestions.filter((suggestion) => suggestion.state === "pending").map((suggestion) => ({ kind: "suggestion", start: suggestion.anchor.last_known_start_offset ?? suggestion.anchor.start_offset, end: suggestion.anchor.last_known_end_offset ?? suggestion.anchor.end_offset }))
  ].filter((anchor): anchor is { kind: string; start: number; end: number } => anchor.start != null && anchor.end != null && anchor.end > anchor.start)
  const text = stripMarkers(markdown)
  if (anchors.length === 0) return <Markdown className="max-w-none p-4 text-sm" text={text} />

  return <div className="whitespace-pre-wrap p-4 text-sm leading-6 text-gray-800 dark:text-gray-100">{highlightText(text, anchors)}</div>
}

function FloatingComposer({ commentBody, disabled, selection, setCommentBody, setSuggestionMarkdown, suggestionMarkdown, onComment, onSuggestion }: {
  commentBody: string
  disabled: boolean
  selection: SelectionRange
  setCommentBody: (value: string) => void
  setSuggestionMarkdown: (value: string) => void
  suggestionMarkdown: string
  onComment: () => void
  onSuggestion: () => void
}) {
  return (
    <div className="rounded border border-gray-200 bg-white p-3 shadow-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-gray-500 dark:text-gray-400">{disabled ? "Select text in the editor to comment or suggest a replacement." : `Selected ${selection.end - selection.start} characters`}</p>
      </div>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <div className="space-y-2">
          <Input aria-label="Inline comment" disabled={disabled} placeholder="Comment on selection" value={commentBody} onChange={(event) => setCommentBody(event.target.value)} />
          <Button disabled={disabled || commentBody.trim().length === 0} onClick={onComment} size="sm" variant="secondary">Comment</Button>
        </div>
        <div className="space-y-2">
          <Input aria-label="Suggested replacement" disabled={disabled} placeholder="Suggested replacement" value={suggestionMarkdown} onChange={(event) => setSuggestionMarkdown(event.target.value)} />
          <Button disabled={disabled || suggestionMarkdown.trim().length === 0} onClick={onSuggestion} size="sm" variant="secondary">Suggest</Button>
        </div>
      </div>
    </div>
  )
}

function ThreadPanel({ doc, onResolve }: { doc: DesignDocDetail; onResolve: (threadId: number) => void }) {
  return (
    <Panel>
      <SectionHeading as="h3">Threads</SectionHeading>
      <div className="mt-3 space-y-3">
        {doc.threads.length === 0 ? <p className="text-sm text-gray-500 dark:text-gray-400">No inline comments.</p> : null}
        {doc.threads.map((thread) => (
          <div className="rounded border border-gray-200 p-3 dark:border-gray-700" key={thread.id}>
            <div className="flex items-center justify-between gap-2">
              <StatusLabel value={thread.state} />
              {thread.state === "open" ? <Button onClick={() => onResolve(thread.id)} size="sm" variant="secondary">Resolve</Button> : null}
            </div>
            <p className="mt-2 rounded bg-gray-50 p-2 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{thread.anchor.selected_text || thread.anchor.selected_markdown || "Selection"}</p>
            {thread.comments.map((comment) => <p className="mt-2 text-sm text-gray-800 dark:text-gray-200" key={comment.id}>{comment.body}</p>)}
          </div>
        ))}
      </div>
    </Panel>
  )
}

function SuggestionPanel({ doc, onReview }: { doc: DesignDocDetail; onReview: (id: number, decision: "accept" | "reject") => void }) {
  return (
    <Panel>
      <SectionHeading as="h3">Suggestions</SectionHeading>
      <div className="mt-3 space-y-3">
        {doc.suggestions.length === 0 ? <p className="text-sm text-gray-500 dark:text-gray-400">No suggestions.</p> : null}
        {doc.suggestions.map((suggestion) => (
          <div className="rounded border border-gray-200 p-3 dark:border-gray-700" key={suggestion.id}>
            <div className="flex items-center justify-between gap-2">
              <StatusLabel value={suggestion.state} />
              <p className="text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={suggestion.created_at} /></p>
            </div>
            <div className="mt-2 grid gap-2 text-xs">
              <del className="rounded bg-red-50 p-2 text-red-800 dark:bg-red-950/40 dark:text-red-200">{suggestion.original_markdown}</del>
              <ins className="rounded bg-emerald-50 p-2 text-emerald-800 no-underline dark:bg-emerald-950/40 dark:text-emerald-200">{suggestion.proposed_markdown}</ins>
            </div>
            {suggestion.change_summary ? <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{suggestion.change_summary}</p> : null}
            {suggestion.conflict_reason ? <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">{suggestion.conflict_reason}</p> : null}
            {suggestion.state === "pending" ? (
              <div className="mt-3 flex gap-2">
                <Button onClick={() => onReview(suggestion.id, "accept")} size="sm" variant="success">Accept</Button>
                <Button onClick={() => onReview(suggestion.id, "reject")} size="sm" variant="secondary">Reject</Button>
              </div>
            ) : null}
          </div>
        ))}
      </div>
    </Panel>
  )
}

function ControlsPanel({ collaborators, doc, repoIds, repositories, setCollaborators, setRepoIds, onSave }: {
  collaborators: string
  doc: DesignDocDetail
  repoIds: string[]
  repositories: Array<{ id: number; slug: string }>
  setCollaborators: (value: string) => void
  setRepoIds: (value: string[]) => void
  onSave: () => void
}) {
  return (
    <Panel>
      <SectionHeading as="h3">Controls</SectionHeading>
      <label className="mt-3 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
        Repositories
        <select
          aria-label="Repository associations"
          className="mt-1 block min-h-24 w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text-primary"
          multiple
          value={repoIds}
          onChange={(event) => setRepoIds(Array.from(event.target.selectedOptions).map((option) => option.value))}
        >
          {repositories.map((repository) => <option key={repository.id} value={repository.id}>{repository.slug}</option>)}
        </select>
      </label>
      <label className="mt-3 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
        Collaborator user IDs
        <Input className="mt-1" value={collaborators} onChange={(event) => setCollaborators(event.target.value)} />
      </label>
      <Button className="mt-3" onClick={onSave} size="sm" variant="secondary">Save controls</Button>
      <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">Owner: {doc.owner?.name || doc.owner?.email_address || "Unknown"}</p>
    </Panel>
  )
}

function VersionPanel({ loading, open, versions, onToggle }: { loading: boolean; open: boolean; versions: Array<{ id: number; version_number: number; change_summary: string | null; created_at: string }>; onToggle: () => void }) {
  return (
    <Panel>
      <div className="flex items-center justify-between gap-2">
        <SectionHeading as="h3">Versions</SectionHeading>
        <Button onClick={onToggle} size="sm" variant="secondary">{open ? "Hide" : "Show"}</Button>
      </div>
      {open && loading ? <p className="mt-3 text-sm text-gray-500 dark:text-gray-400">Loading versions...</p> : null}
      {open ? versions.map((version) => (
        <div className="mt-3 rounded border border-gray-200 p-3 text-sm dark:border-gray-700" key={version.id}>
          <p className="font-medium text-gray-900 dark:text-gray-100">Version {version.version_number}</p>
          <p className="text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={version.created_at} /></p>
          {version.change_summary ? <p className="mt-1 text-gray-600 dark:text-gray-300">{version.change_summary}</p> : null}
        </div>
      )) : null}
    </Panel>
  )
}

function Panel({ children, tone = "default" }: { children: React.ReactNode; tone?: "default" | "error" }) {
  const colors = tone === "error" ? "border-red-200 bg-red-50 text-red-800 dark:border-red-800 dark:bg-red-950/40 dark:text-red-200" : "border-gray-200 bg-white text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200"
  return <div className={`rounded border p-4 ${colors}`}>{children}</div>
}

function StatusLabel({ value }: { value: string }) {
  return <span className="shrink-0 rounded border border-gray-200 px-2 py-0.5 text-xs font-medium capitalize text-gray-600 dark:border-gray-700 dark:text-gray-300">{value}</span>
}

function filterDocs(docs: DesignDocSummary[], filters: { repository: string; owner: string; state: string; visibility: string; updated: string }, chatId?: number, designDocIds: number[] = []) {
  const cutoff = filters.updated === "all" ? null : Date.now() - Number(filters.updated) * 24 * 60 * 60 * 1000
  const scopedIds = new Set(designDocIds.map(String))
  return docs.filter((doc) => {
    if (chatId && doc.origin_chat_session_id !== chatId && !scopedIds.has(String(doc.id))) return false
    if (filters.repository !== "all" && !doc.repository_ids.map(String).includes(filters.repository)) return false
    if (filters.owner !== "all" && doc.owner?.name !== filters.owner) return false
    if (filters.state !== "all" && doc.state !== filters.state) return false
    if (filters.visibility !== "all" && doc.visibility !== filters.visibility) return false
    if (cutoff && new Date(doc.updated_at).getTime() < cutoff) return false
    return true
  })
}

function anchorPayload(selection: SelectionRange) {
  return {
    start_offset: selection.start,
    end_offset: selection.end,
    selected_markdown: selection.text,
    selected_text: selection.text
  }
}

function stripMarkers(markdown: string) {
  return markdown.replace(/<!--\s*syrus:(?:range-start|range-end|point)\s+id="[^"]+"\s*-->/g, "")
}

function highlightText(text: string, anchors: Array<{ kind: string; start: number; end: number }>) {
  const sorted = [...anchors].sort((a, b) => a.start - b.start)
  const nodes: React.ReactNode[] = []
  let cursor = 0
  sorted.forEach((anchor, index) => {
    if (anchor.start < cursor) return
    if (anchor.start > cursor) nodes.push(text.slice(cursor, anchor.start))
    nodes.push(<mark className={anchor.kind === "suggestion" ? "rounded bg-emerald-100 px-0.5 text-gray-900 dark:bg-emerald-900/60 dark:text-emerald-50" : "rounded bg-amber-100 px-0.5 text-gray-900 dark:bg-amber-900/60 dark:text-amber-50"} key={`${anchor.kind}-${index}`}>{text.slice(anchor.start, anchor.end)}</mark>)
    cursor = anchor.end
  })
  if (cursor < text.length) nodes.push(text.slice(cursor))
  return nodes
}
