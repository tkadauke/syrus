import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useRef, useState, type ChangeEvent } from "react"
import { useLocation, useNavigate, useParams } from "react-router-dom"
import { Button } from "@app/components/Button"
import { AdminSmartFolderNav } from "@app/components/AdminSmartFolderNav"
import { FilterBar } from "@app/components/FilterBar"
import { Input } from "@app/components/Input"
import { Select } from "@app/components/Select"
import { PageHeading, SectionHeading } from "@app/components/Heading"
import { useMediaQuery } from "@app/routes/dashboard/components"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { fetchRepositories } from "@app/api/repositories"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
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
type EditorMode = "markdown" | "wysiwyg"
type SelectionRange = { start: number; end: number; text: string }

export function DesignDocsSurface({ chatId, compact = false, designDocIds, mode, repositoryId }: { chatId?: number; compact?: boolean; designDocIds?: number[]; mode: SurfaceMode; repositoryId?: string | number }) {
  const params = useParams()
  const { t } = useT("nav")
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const id = params.id
  const search = location.search
  const [selectedId, setSelectedId] = useState<string | number | null>(id || null)
  const effectiveId = id || selectedId
  const queryClient = useQueryClient()
  const indexQuery = useQuery({
    queryKey: mode === "repository" ? ["design_docs", "repository", String(repositoryId), search] : ["design_docs", search],
    queryFn: () => mode === "repository" && repositoryId ? fetchRepositoryDesignDocs(repositoryId, search) : fetchDesignDocs(search)
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
  const [notice, setNotice] = useState<string | null>(null)
  const docs = useMemo(() => scopeDocs(indexQuery.data?.design_docs ?? [], chatId, designDocIds), [chatId, designDocIds, indexQuery.data])
  const selectedDoc = detailQuery.data?.design_doc ?? null
  const repositoryOptions = repositoriesQuery.data?.active_repositories ?? []
  const currentFilter = indexQuery.data?.filter ?? { and: [] }
  const activeSmartFolderId = smartFolderIdFromSearch(search) ?? indexQuery.data?.active_smart_folder_id ?? null
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const showIndexControls = mode !== "chat"
  const sidebarOwnsDesktopFolders = mode === "index" && isDesktop
  const showDesktopInlineFolders = showIndexControls && isDesktop && !sidebarOwnsDesktopFolders
  const filterBar = showIndexControls ? (
    <div data-testid="design-docs-filter-bar">
      <FilterBar
        filter={currentFilter}
        filterSchema={indexQuery.data?.filter_schema ?? []}
        pathname={location.pathname}
        search={search}
        suggestionSearch={{ surface: "dashboard", subject: "design_doc" }}
      />
    </div>
  ) : null
  const smartFolders = showIndexControls ? (
    <AdminSmartFolderNav
      activeFolderId={activeSmartFolderId}
      allLabel="All design docs"
      allPath={mode === "repository" ? location.pathname : "/design_docs"}
      allowSaveWithoutActiveFolder
      ariaLabel="Design Docs smart folders"
      currentFilter={currentFilter}
      folders={indexQuery.data?.smart_folders ?? []}
      heading="Folders"
      onMutationSuccess={() => {
        void queryClient.invalidateQueries({ queryKey: ["design_docs"] })
      }}
      prefix={prefix}
      queryKey={["design_docs"]}
      subjectType="design_doc"
    />
  ) : null

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
      {isDesktop ? filterBar : showIndexControls ? (
        <div className="px-0">
          <details className="group rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
            <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium text-gray-700 dark:text-gray-200">
              <span>{t("filters_layout.folders_and_filters")}</span>
              <span className="text-gray-400 group-open:hidden dark:text-gray-500">{t("filters_layout.show")}</span>
              <span className="hidden text-gray-400 group-open:inline dark:text-gray-500">{t("filters_layout.hide")}</span>
            </summary>
            <div className="space-y-4 border-t border-gray-200 p-4 dark:border-gray-700">
              {filterBar}
              {smartFolders}
            </div>
          </details>
        </div>
      ) : null}
      <div className={`grid min-h-0 gap-4 ${compact ? "xl:grid-cols-[18rem_minmax(0,1fr)]" : showDesktopInlineFolders ? "lg:grid-cols-[16rem_20rem_minmax(0,1fr)]" : "lg:grid-cols-[20rem_minmax(0,1fr)]"}`}>
        {showDesktopInlineFolders ? smartFolders : null}
        <DesignDocList
          docs={docs}
          loading={indexQuery.isPending}
          selectedId={effectiveId}
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

function DesignDocList({ docs, loading, selectedId, onSelect }: {
  docs: DesignDocSummary[]
  loading: boolean
  selectedId: string | number | null
  onSelect: (id: number) => void
}) {
  return (
    <aside className="min-w-0 space-y-3">
      <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        {loading ? <div className="p-4 text-sm text-gray-600 dark:text-gray-400">Loading design docs...</div> : null}
        {!loading && docs.length === 0 ? <div className="p-4 text-sm text-gray-600 dark:text-gray-400">No visible design docs match these filters.</div> : null}
        {docs.map((doc) => (
          <button
            className={`block w-full border-b border-gray-100 p-3 text-left last:border-b-0 dark:border-gray-800 ${String(selectedId) === String(doc.id) ? "bg-brand/10" : "hover:bg-gray-50 dark:hover:bg-gray-800/70"}`}
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
  const [editorMode, setEditorMode] = useState<EditorMode>("markdown")
  const [title, setTitle] = useState(doc.title)
  const [summary, setSummary] = useState("")
  const [selection, setSelection] = useState<SelectionRange>({ start: 0, end: 0, text: "" })
  const [commentBody, setCommentBody] = useState("")
  const [suggestionMarkdown, setSuggestionMarkdown] = useState("")
  const [collaborators, setCollaborators] = useState(doc.collaborator_ids.join(", "))
  const [repoIds, setRepoIds] = useState(doc.repository_ids.map(String))
  const [repositoryPickerOpen, setRepositoryPickerOpen] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
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
    mutationFn: (input: { visibility?: "private" | "public"; state?: "draft" | "accepted" | "archived"; repository_ids?: number[]; collaborator_user_ids?: number[] }) => updateDesignDoc(doc.id, input),
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

  const selectedRepositories = repositories.filter((repository) => repoIds.includes(String(repository.id)))

  return (
    <div className="min-w-0 space-y-4">
      <DesignDocTitleBar
        collaborators={collaborators}
        doc={doc}
        repoIds={repoIds}
        repositories={repositories}
        repositoryPickerOpen={repositoryPickerOpen}
        selectedRepositories={selectedRepositories}
        setCollaborators={setCollaborators}
        setRepoIds={setRepoIds}
        setRepositoryPickerOpen={setRepositoryPickerOpen}
        setShareOpen={setShareOpen}
        setTitle={setTitle}
        shareOpen={shareOpen}
        title={title}
        versions={versions.data?.versions ?? []}
        versionsLoading={versions.isPending}
        versionsOpen={versionsOpen}
        onMetadataSave={() => metadataMutation.mutate({ repository_ids: repoIds.map(Number), collaborator_user_ids: collaborators.split(",").map((part) => part.trim()).filter(Boolean).map(Number) })}
        onSave={() => saveMutation.mutate()}
        onVersionsOpen={() => setVersionsOpen(true)}
        onVisibilityChange={(visibility) => metadataMutation.mutate({ visibility })}
      />
      <div className={`grid min-w-0 gap-4 ${mode === "chat" ? "" : "xl:grid-cols-[minmax(0,1fr)_22rem]"}`}>
      <section className="min-w-0 space-y-4">
        <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
            <div aria-label="Editor mode" className="inline-flex overflow-hidden rounded border border-border bg-surface text-sm" role="tablist">
              {(["markdown", "wysiwyg"] as EditorMode[]).map((candidate) => (
                <button
                  aria-selected={editorMode === candidate}
                  className={`px-3 py-1.5 font-medium capitalize ${editorMode === candidate ? "bg-brand text-on-brand" : "text-text-secondary hover:bg-surface-raised"}`}
                  key={candidate}
                  onClick={() => setEditorMode(candidate)}
                  role="tab"
                  type="button"
                >
                  {candidate === "markdown" ? "Markdown" : "WYSIWYG"}
                </button>
              ))}
            </div>
            <Input aria-label="Change summary" className="min-w-[12rem] flex-1" placeholder="Change summary" value={summary} onChange={(event) => setSummary(event.target.value)} />
          </div>
          {editorMode === "markdown" ? (
            <label className="flex min-h-[36rem] flex-col">
              <span className="sr-only">Markdown editor</span>
              <textarea
                aria-label="Markdown editor"
                className="min-h-[36rem] flex-1 resize-y bg-transparent p-4 font-mono text-sm leading-6 text-gray-900 outline-none dark:text-gray-100"
                onBlur={() => updateSelection()}
                onChange={(event) => setDraft(event.target.value)}
                onKeyUp={() => updateSelection()}
                onMouseUp={() => updateSelection()}
                ref={textareaRef}
                value={draft}
              />
            </label>
          ) : (
            <label className="flex min-h-[36rem] flex-col">
              <span className="sr-only">WYSIWYG editor</span>
              <textarea
                aria-label="WYSIWYG editor"
                className="chat-prose min-h-[36rem] max-w-none flex-1 resize-y bg-transparent p-4 text-sm leading-6 text-gray-900 outline-none dark:text-gray-100"
                onChange={(event) => setDraft(event.target.value)}
                value={draft}
              />
            </label>
          )}
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
      </aside>
      </div>
    </div>
  )
}

function DesignDocTitleBar({ collaborators, doc, repoIds, repositories, repositoryPickerOpen, selectedRepositories, setCollaborators, setRepoIds, setRepositoryPickerOpen, setShareOpen, setTitle, shareOpen, title, versions, versionsLoading, versionsOpen, onMetadataSave, onSave, onVersionsOpen, onVisibilityChange }: {
  collaborators: string
  doc: DesignDocDetail
  repoIds: string[]
  repositories: Array<{ id: number; slug: string }>
  repositoryPickerOpen: boolean
  selectedRepositories: Array<{ id: number; slug: string }>
  setCollaborators: (value: string) => void
  setRepoIds: (value: string[]) => void
  setRepositoryPickerOpen: (value: boolean) => void
  setShareOpen: (value: boolean) => void
  setTitle: (value: string) => void
  shareOpen: boolean
  title: string
  versions: Array<{ id: number; version_number: number; change_summary: string | null; created_at: string }>
  versionsLoading: boolean
  versionsOpen: boolean
  onMetadataSave: () => void
  onSave: () => void
  onVersionsOpen: () => void
  onVisibilityChange: (visibility: "private" | "public") => void
}) {
  return (
    <section aria-label="Design doc title bar" className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center gap-3">
        <div className="min-w-[14rem] flex-1">
          <Input aria-label="Design doc title" value={title} onChange={(event) => setTitle(event.target.value)} />
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            <span className="font-medium text-gray-700 dark:text-gray-300">{doc.display_id}</span>
            <span> / saved <RelativeTimestamp value={doc.updated_at} /></span>
          </p>
        </div>
        <StatusLabel value={doc.visibility} />
        <StatusLabel value={doc.state} />
        <div className="relative min-w-0">
          <div className="flex max-w-full flex-wrap items-center gap-1.5">
            {selectedRepositories.length === 0 ? <span className="text-xs text-gray-500 dark:text-gray-400">No repositories</span> : null}
            {selectedRepositories.map((repository) => (
              <span className="max-w-[11rem] truncate rounded border border-gray-200 px-2 py-1 text-xs text-gray-700 dark:border-gray-700 dark:text-gray-300" key={repository.id}>
                {repository.slug}
              </span>
            ))}
            <Button aria-expanded={repositoryPickerOpen} aria-label="Add repository" className="h-7 w-7" onClick={() => setRepositoryPickerOpen(!repositoryPickerOpen)} size="icon" variant="secondary">
              <span aria-hidden="true" className="text-base leading-none">+</span>
            </Button>
          </div>
          {repositoryPickerOpen ? (
            <div className="absolute left-0 z-20 mt-2 w-72 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-950">
              <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
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
              <div className="mt-3 flex justify-end">
                <Button onClick={onMetadataSave} size="sm" variant="secondary">Save repositories</Button>
              </div>
            </div>
          ) : null}
        </div>
        <div className="relative">
          <Button aria-expanded={shareOpen} onClick={() => setShareOpen(!shareOpen)} size="sm" variant="secondary">Share</Button>
          {shareOpen ? (
            <div className="absolute right-0 z-20 mt-2 w-80 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-950">
              <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
                Visibility
                <Select aria-label="Share visibility" className="mt-1" value={doc.visibility} onChange={(event) => onVisibilityChange(event.target.value as "private" | "public")}>
                  <option value="private">Private</option>
                  <option value="public">Public</option>
                </Select>
              </label>
              <label className="mt-3 block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
                Explicit collaborators
                <Input aria-label="Collaborator user IDs" className="mt-1" value={collaborators} onChange={(event) => setCollaborators(event.target.value)} />
              </label>
              <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">Owner: {doc.owner?.name || doc.owner?.email_address || "Unknown"}</p>
              <div className="mt-3 flex justify-end">
                <Button onClick={onMetadataSave} size="sm" variant="secondary">Save sharing</Button>
              </div>
            </div>
          ) : null}
        </div>
        <Button onClick={onSave} size="sm">Save</Button>
        <Select
          aria-label="Version selection"
          className="ml-auto max-w-[12rem]"
          fullWidth={false}
          onFocus={onVersionsOpen}
          onMouseDown={onVersionsOpen}
          value={doc.current_version_number ?? ""}
          onChange={() => undefined}
        >
          <option value={doc.current_version_number ?? ""}>v{doc.current_version_number ?? "?"}</option>
          {versionsOpen && versionsLoading ? <option value="loading">Loading...</option> : null}
          {versions.filter((version) => version.version_number !== doc.current_version_number).map((version) => (
            <option key={version.id} value={version.version_number}>v{version.version_number}{version.change_summary ? ` - ${version.change_summary}` : ""}</option>
          ))}
        </Select>
      </div>
    </section>
  )
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

function Panel({ children, tone = "default" }: { children: React.ReactNode; tone?: "default" | "error" }) {
  const colors = tone === "error" ? "border-red-200 bg-red-50 text-red-800 dark:border-red-800 dark:bg-red-950/40 dark:text-red-200" : "border-gray-200 bg-white text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200"
  return <div className={`rounded border p-4 ${colors}`}>{children}</div>
}

function StatusLabel({ value }: { value: string }) {
  return <span className="shrink-0 rounded border border-gray-200 px-2 py-0.5 text-xs font-medium capitalize text-gray-600 dark:border-gray-700 dark:text-gray-300">{value}</span>
}

function scopeDocs(docs: DesignDocSummary[], chatId?: number, designDocIds: number[] = []) {
  const scopedIds = new Set(designDocIds.map(String))
  return docs.filter((doc) => {
    if (chatId && doc.origin_chat_session_id !== chatId && !scopedIds.has(String(doc.id))) return false
    return true
  })
}

function smartFolderIdFromSearch(search: string) {
  const raw = new URLSearchParams(search).get("smart_folder_id")
  if (!raw) return null

  const id = Number(raw)
  return Number.isInteger(id) ? id : null
}

function anchorPayload(selection: SelectionRange) {
  return {
    start_offset: selection.start,
    end_offset: selection.end,
    selected_markdown: selection.text,
    selected_text: selection.text
  }
}
