import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState, type ChangeEvent } from "react"
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
  type DesignDocThread,
  type DesignDocSummary,
  type DesignDocVersion
} from "../api/designDocs"

type SurfaceMode = "index" | "repository" | "chat"
type EditorMode = "markdown" | "wysiwyg"
type SelectionRange = { start: number; end: number; text: string; selectedText: string; rect: SelectionRect | null }
type SelectionRect = { top: number; left: number }
type PopoverAlignment = "start" | "end"
type AnchorHighlight = {
  id: string
  kind: "thread" | "suggestion"
  threadId?: number
  proposedMarkdown?: string
  suggestionState?: string
  status: string
  start: number
  end: number
}

const SHARE_POPOVER_WIDTH = 320
const POPOVER_VIEWPORT_MARGIN = 16

export function DesignDocsSurface({ chatId, compact = false, designDocIds, initialDesignDocId, initialDesignDocs = [], mode, repositoryId }: {
  chatId?: number
  compact?: boolean
  designDocIds?: number[]
  initialDesignDocId?: number
  initialDesignDocs?: DesignDocSummary[]
  mode: SurfaceMode
  repositoryId?: string | number
}) {
  const params = useParams()
  const { t } = useT("nav")
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const id = mode === "chat" ? null : params.id
  const search = location.search
  const [selectedId, setSelectedId] = useState<string | number | null>(id || initialDesignDocId || null)
  const effectiveId = id || selectedId
  const queryClient = useQueryClient()
  const indexQuery = useQuery({
    queryKey: mode === "repository" ? ["design_docs", "repository", String(repositoryId), search] : ["design_docs", search],
    queryFn: () => mode === "repository" && repositoryId ? fetchRepositoryDesignDocs(repositoryId, search) : fetchDesignDocs(search),
    enabled: mode !== "chat"
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
  const docs = useMemo(
    () => mode === "chat" ? scopeDocs(initialDesignDocs, chatId, designDocIds) : scopeDocs(indexQuery.data?.design_docs ?? [], chatId, designDocIds),
    [chatId, designDocIds, indexQuery.data, initialDesignDocs, mode]
  )
  const docsLoading = mode === "chat" ? false : indexQuery.isPending
  const selectedDoc = detailQuery.data?.design_doc ?? null
  const repositoryOptions = repositoriesQuery.data?.active_repositories ?? []
  const currentFilter = indexQuery.data?.filter ?? { and: [] }
  const activeSmartFolderId = smartFolderIdFromSearch(search) ?? indexQuery.data?.active_smart_folder_id ?? null
  const docPath = (docId: string | number) => `${prefix}/design_docs/${docId}${search}`
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const showIndexControls = mode !== "chat"
  const showDocList = mode !== "chat"
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

  useEffect(() => {
    if (mode !== "chat") return

    setSelectedId(initialDesignDocId || null)
  }, [initialDesignDocId, mode])

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
      else navigate(docPath(payload.design_doc.id))
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
      <div className={`grid min-h-0 gap-4 ${compact && showDocList ? "xl:grid-cols-[18rem_minmax(0,1fr)]" : showDesktopInlineFolders ? "lg:grid-cols-[16rem_20rem_minmax(0,1fr)]" : showDocList ? "lg:grid-cols-[20rem_minmax(0,1fr)]" : "grid-cols-1"}`}>
        {showDesktopInlineFolders ? smartFolders : null}
        {showDocList ? <DesignDocList
          docs={docs}
          loading={docsLoading}
          selectedId={effectiveId}
          onSelect={(docId) => navigate(docPath(docId))}
        /> : null}
        <section className="min-w-0">
          {detailQuery.isError ? <Panel tone="error">{errorMessage(detailQuery.error, "Unable to load design doc.")}</Panel> : null}
          {!effectiveId && !detailQuery.isError ? <Panel>{mode === "chat" ? "No design docs are attached to this chat." : "Select a design doc to review or edit."}</Panel> : null}
          {detailQuery.isPending && effectiveId ? <Panel>Loading design doc...</Panel> : null}
          {selectedDoc ? (
            <DesignDocEditor
              doc={selectedDoc}
              key={selectedDoc.id}
              mode={mode}
              repositories={repositoryOptions.map((repository) => ({ id: repository.id, slug: repository.slug }))}
              onDocChange={(nextDoc, message) => {
                queryClient.setQueryData(["design_docs", "detail", String(nextDoc.id)], { design_doc: nextDoc })
                void queryClient.invalidateQueries({
                  predicate: (query) => query.queryKey[0] === "design_docs" && query.queryKey[1] !== "detail" && query.queryKey[1] !== "versions"
                })
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
  const [draft, setDraft] = useState(doc.rendered_markdown || doc.markdown)
  const [editorMode, setEditorMode] = useState<EditorMode>("markdown")
  const [title, setTitle] = useState(doc.title)
  const [summary, setSummary] = useState("")
  const [selection, setSelection] = useState<SelectionRange>({ start: 0, end: 0, text: "", selectedText: "", rect: null })
  const [commentBody, setCommentBody] = useState("")
  const [suggestionMarkdown, setSuggestionMarkdown] = useState("")
  const [focusedThreadId, setFocusedThreadId] = useState<number | null>(null)
  const [replyBodies, setReplyBodies] = useState<Record<number, string>>({})
  const [collaborators, setCollaborators] = useState(doc.collaborator_ids.join(", "))
  const [repoIds, setRepoIds] = useState(doc.repository_ids.map(String))
  const [repositoryPickerOpen, setRepositoryPickerOpen] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [versionsOpen, setVersionsOpen] = useState(false)
  const [selectedVersionId, setSelectedVersionId] = useState("current")
  const [markdownScrollTop, setMarkdownScrollTop] = useState(0)
  const canWriteCanonical = doc.permissions.can_write_canonical
  const canSuggest = doc.permissions.can_suggest
  const saveLabel = canWriteCanonical ? "Save" : "Propose changes"
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const wysiwygRef = useRef<HTMLDivElement | null>(null)
  const editorShellRef = useRef<HTMLDivElement | null>(null)
  const threadRefs = useRef<Record<number, HTMLDivElement | null>>({})
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
      setSelection({ start: 0, end: 0, text: "", selectedText: "", rect: null })
      onDocChange(payload.design_doc, "Comment added.")
    }
  })
  const replyMutation = useMutation({
    mutationFn: ({ threadId, body }: { threadId: number; body: string }) => createDesignDocComment(doc.id, { thread_id: threadId, body }),
    onSuccess: (payload, variables) => {
      setReplyBodies((current) => ({ ...current, [variables.threadId]: "" }))
      onDocChange(payload.design_doc, "Reply added.")
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
  const highlights = useMemo(() => buildAnchorHighlights(doc), [doc])
  const activeHighlights = useMemo(
    () => draft === (doc.rendered_markdown || doc.markdown) ? highlights : [],
    [doc.markdown, doc.rendered_markdown, draft, highlights]
  )

  function updateSelection(event?: ChangeEvent<HTMLTextAreaElement>) {
    const target = event?.target ?? textareaRef.current
    if (!target) return
    const start = target.selectionStart
    const end = target.selectionEnd
    const text = target.value.slice(start, end)
    setSelection({ start, end, text, selectedText: text, rect: textareaSelectionRect(target, start, end) })
  }

  function updateWysiwygSelection() {
    if (!wysiwygRef.current) return

    const range = document.getSelection()
    if (!range || range.rangeCount === 0 || range.isCollapsed) return
    const selectedRange = range.getRangeAt(0)
    if (!wysiwygRef.current.contains(selectedRange.commonAncestorContainer)) return

    const preRange = selectedRange.cloneRange()
    preRange.selectNodeContents(wysiwygRef.current)
    preRange.setEnd(selectedRange.startContainer, selectedRange.startOffset)
    const renderedStart = preRange.toString().length
    const selectedText = selectedRange.toString()
    const start = markdownOffsetForRenderedOffset(draft, renderedStart, "start")
    const end = markdownOffsetForRenderedOffset(draft, renderedStart + selectedText.length, "end")
    setSelection({
      start,
      end,
      text: draft.slice(start, end),
      selectedText,
      rect: rangeSelectionRect(selectedRange, editorShellRef.current)
    })
  }

  useEffect(() => {
    if (editorMode !== "wysiwyg" || !wysiwygRef.current) return
    if (document.activeElement === wysiwygRef.current) return

    const nextHtml = markdownToWysiwygHtml(draft, activeHighlights, focusedThreadId)
    if (wysiwygRef.current.innerHTML !== nextHtml) wysiwygRef.current.innerHTML = nextHtml
  }, [draft, editorMode, focusedThreadId, activeHighlights])

  useEffect(() => {
    if (!focusedThreadId) return

    threadRefs.current[focusedThreadId]?.scrollIntoView?.({ block: "nearest", behavior: "smooth" })
  }, [focusedThreadId])

  function selectVersion(versionId: string) {
    setVersionsOpen(true)
    setSelectedVersionId(versionId)
    if (versionId === "current") {
      setDraft(doc.rendered_markdown || doc.markdown)
      return
    }

    const version = versions.data?.versions.find((candidate) => String(candidate.id) === versionId)
    if (!version) return

    setDraft(version.markdown)
    setSummary(version.change_summary ?? "")
  }

  const selectedRepositories = repositories.filter((repository) => repoIds.includes(String(repository.id)))

  function focusThread(threadId: number) {
    setFocusedThreadId(threadId)
    const thread = doc.threads.find((candidate) => candidate.id === threadId)
    const anchor = thread?.anchor
    const start = anchor?.last_known_start_offset ?? anchor?.start_offset
    const end = anchor?.last_known_end_offset ?? anchor?.end_offset
    if (start == null || end == null) return

    if (editorMode === "markdown" && textareaRef.current) {
      textareaRef.current.focus()
      textareaRef.current.setSelectionRange(start, end)
      const nextScrollTop = Math.max(0, Math.floor(start / 80) * 24 - 80)
      textareaRef.current.scrollTop = nextScrollTop
      setMarkdownScrollTop(nextScrollTop)
      return
    }

    const marker = wysiwygRef.current?.querySelector(`[data-thread-id="${threadId}"]`) as HTMLElement | null
    marker?.scrollIntoView?.({ block: "center", behavior: "smooth" })
  }

  function focusThreadAtOffset(offset: number) {
    const match = activeHighlights.find((highlight) => highlight.kind === "thread" && offset >= highlight.start && offset <= highlight.end)
    if (match?.threadId) focusThread(match.threadId)
  }

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
        selectedVersionId={selectedVersionId}
        versions={versions.data?.versions ?? []}
        versionsLoading={versions.isPending}
        versionsOpen={versionsOpen}
        onMetadataSave={() => metadataMutation.mutate({ repository_ids: repoIds.map(Number), collaborator_user_ids: collaborators.split(",").map((part) => part.trim()).filter(Boolean).map(Number) })}
        onSave={() => saveMutation.mutate()}
        saveLabel={saveLabel}
        canManageMetadata={canWriteCanonical}
        onVersionChange={selectVersion}
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
          <div className="relative" ref={editorShellRef}>
          {editorMode === "markdown" ? (
            <label className="relative flex min-h-[36rem] flex-col overflow-hidden">
              <span className="sr-only">Markdown editor</span>
              <MarkdownHighlightMirror draft={draft} focusedThreadId={focusedThreadId} highlights={activeHighlights} scrollTop={markdownScrollTop} />
              <textarea
                aria-label="Markdown editor"
                className="relative z-10 min-h-[36rem] flex-1 resize-y bg-transparent p-4 font-mono text-sm leading-6 text-transparent caret-gray-900 outline-none selection:bg-brand/20 dark:caret-gray-100"
                onBlur={() => updateSelection()}
                onClick={(event) => focusThreadAtOffset(event.currentTarget.selectionStart)}
                onChange={(event) => setDraft(event.target.value)}
                onKeyUp={() => updateSelection()}
                onMouseUp={() => updateSelection()}
                onScroll={(event) => setMarkdownScrollTop(event.currentTarget.scrollTop)}
                ref={textareaRef}
                value={draft}
              />
            </label>
          ) : (
            <div
              aria-label="WYSIWYG editor"
              className="chat-prose min-h-[36rem] max-w-none p-4 text-sm leading-6 text-gray-900 outline-none focus:ring-2 focus:ring-brand dark:text-gray-100"
              contentEditable
              onBlur={() => setDraft(wysiwygHtmlToMarkdown(wysiwygRef.current))}
              onClick={(event) => {
                const target = event.target as HTMLElement
                const marker = target.closest("[data-thread-id]") as HTMLElement | null
                if (marker?.dataset.threadId) focusThread(Number(marker.dataset.threadId))
              }}
              onInput={() => setDraft(wysiwygHtmlToMarkdown(wysiwygRef.current))}
              onKeyUp={updateWysiwygSelection}
              onMouseUp={updateWysiwygSelection}
              ref={wysiwygRef}
              role="textbox"
              suppressContentEditableWarning
              tabIndex={0}
            />
          )}
          <FloatingComposer
            commentBody={commentBody}
            disabled={selection.end <= selection.start}
            selection={selection}
            setCommentBody={setCommentBody}
            setSuggestionMarkdown={setSuggestionMarkdown}
            suggestionMarkdown={suggestionMarkdown}
            canSuggest={canSuggest}
            onComment={() => commentMutation.mutate()}
            onSuggestion={() => suggestionMutation.mutate()}
          />
          </div>
        </div>
      </section>
      <aside className="space-y-4">
        <ThreadPanel
          doc={doc}
          focusedThreadId={focusedThreadId}
          replyBodies={replyBodies}
          threadRefs={threadRefs}
          onFocus={focusThread}
          onReply={(threadId) => {
            const body = replyBodies[threadId]?.trim()
            if (body) replyMutation.mutate({ threadId, body })
          }}
          onReplyChange={(threadId, body) => setReplyBodies((current) => ({ ...current, [threadId]: body }))}
          onResolve={(threadId) => resolveMutation.mutate(threadId)}
        />
        <SuggestionPanel doc={doc} onReview={(id, decision) => reviewMutation.mutate({ id, decision })} />
      </aside>
      </div>
    </div>
  )
}

function DesignDocTitleBar({ collaborators, doc, repoIds, repositories, repositoryPickerOpen, selectedRepositories, selectedVersionId, setCollaborators, setRepoIds, setRepositoryPickerOpen, setShareOpen, setTitle, shareOpen, title, versions, versionsLoading, versionsOpen, canManageMetadata, onMetadataSave, onSave, saveLabel, onVersionChange, onVersionsOpen, onVisibilityChange }: {
  collaborators: string
  canManageMetadata: boolean
  doc: DesignDocDetail
  repoIds: string[]
  repositories: Array<{ id: number; slug: string }>
  repositoryPickerOpen: boolean
  selectedRepositories: Array<{ id: number; slug: string }>
  selectedVersionId: string
  setCollaborators: (value: string) => void
  setRepoIds: (value: string[]) => void
  setRepositoryPickerOpen: (value: boolean) => void
  setShareOpen: (value: boolean) => void
  setTitle: (value: string) => void
  shareOpen: boolean
  title: string
  versions: DesignDocVersion[]
  versionsLoading: boolean
  versionsOpen: boolean
  onMetadataSave: () => void
  onSave: () => void
  saveLabel: string
  onVersionChange: (versionId: string) => void
  onVersionsOpen: () => void
  onVisibilityChange: (visibility: "private" | "public") => void
}) {
  const titleBarRef = useRef<HTMLElement | null>(null)
  const shareButtonRef = useRef<HTMLButtonElement | null>(null)
  const [sharePopoverAlignment, setSharePopoverAlignment] = useState<PopoverAlignment>("start")

  useEffect(() => {
    if (!shareOpen) return

    function updateSharePopoverAlignment() {
      if (!shareButtonRef.current) return

      setSharePopoverAlignment(popoverAlignmentForTrigger(
        shareButtonRef.current.getBoundingClientRect(),
        SHARE_POPOVER_WIDTH,
        titleBarRef.current?.getBoundingClientRect() ?? null
      ))
    }

    updateSharePopoverAlignment()
    window.addEventListener("resize", updateSharePopoverAlignment)
    window.visualViewport?.addEventListener("resize", updateSharePopoverAlignment)
    return () => {
      window.removeEventListener("resize", updateSharePopoverAlignment)
      window.visualViewport?.removeEventListener("resize", updateSharePopoverAlignment)
    }
  }, [shareOpen])

  return (
    <section aria-label="Design doc title bar" className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900" ref={titleBarRef}>
      <div className="flex flex-wrap items-center gap-3">
        <div className="min-w-[14rem] flex-1">
          <Input aria-label="Design doc title" disabled={!canManageMetadata} value={title} onChange={(event) => setTitle(event.target.value)} />
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
            {canManageMetadata ? (
            <Button aria-expanded={repositoryPickerOpen} aria-label="Add repository" className="h-7 w-7" onClick={() => setRepositoryPickerOpen(!repositoryPickerOpen)} size="icon" variant="secondary">
              <span aria-hidden="true" className="text-base leading-none">+</span>
            </Button>
            ) : null}
          </div>
          {repositoryPickerOpen && canManageMetadata ? (
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
          {canManageMetadata ? <Button aria-expanded={shareOpen} onClick={() => setShareOpen(!shareOpen)} ref={shareButtonRef} size="sm" variant="secondary">Share</Button> : <StatusLabel value="review only" />}
          {shareOpen && canManageMetadata ? (
            <div
              className={`absolute ${sharePopoverAlignment === "start" ? "left-0" : "right-0"} z-20 mt-2 w-80 max-w-[calc(100vw-2rem)] rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-950`}
              data-design-doc-share-popover
            >
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
        <Button onClick={onSave} size="sm">{saveLabel}</Button>
        <Select
          aria-label="Version selection"
          className="ml-auto max-w-[12rem]"
          fullWidth={false}
          onFocus={onVersionsOpen}
          onMouseDown={onVersionsOpen}
          value={selectedVersionId}
          onChange={(event) => onVersionChange(event.target.value)}
        >
          <option value="current">Current v{doc.current_version_number ?? "?"}</option>
          {versionsOpen && versionsLoading ? <option value="loading">Loading...</option> : null}
          {versions.map((version) => (
            <option key={version.id} value={version.id}>v{version.version_number}{version.change_summary ? ` - ${version.change_summary}` : ""}</option>
          ))}
        </Select>
      </div>
    </section>
  )
}

function MarkdownHighlightMirror({ draft, focusedThreadId, highlights, scrollTop }: { draft: string; focusedThreadId: number | null; highlights: AnchorHighlight[]; scrollTop: number }) {
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 z-0 min-h-[36rem] whitespace-pre-wrap break-words p-4 font-mono text-sm leading-6 text-gray-900 dark:text-gray-100"
      data-testid="markdown-highlight-mirror"
      style={{ transform: scrollTop > 0 ? `translateY(-${scrollTop}px)` : undefined }}
    >
      {highlightTextSegments(draft, highlights).map((segment, index) => {
        if (!segment.highlight) return <span key={index}>{segment.text}</span>

        const focused = segment.highlight.threadId === focusedThreadId
        if (segment.highlight.kind === "suggestion") {
          return (
            <span className="rounded-sm bg-surface-raised px-0.5" data-anchor-status={segment.highlight.status} data-inline-suggestion-state={segment.highlight.suggestionState} key={index}>
              <del className="text-warning decoration-warning decoration-2">{segment.text}</del>
              <ins className="ml-1 text-success no-underline">{segment.highlight.proposedMarkdown}</ins>
            </span>
          )
        }

        return (
          <mark
            className={`rounded-sm px-0.5 ${focused ? "bg-amber-300/70 ring-1 ring-amber-500 dark:bg-amber-500/50" : "bg-yellow-200/70 dark:bg-yellow-500/30"}`}
            data-anchor-status={segment.highlight.status}
            key={index}
          >
            {segment.text}
          </mark>
        )
      })}
    </div>
  )
}

function FloatingComposer({ commentBody, disabled, selection, setCommentBody, setSuggestionMarkdown, suggestionMarkdown, canSuggest, onComment, onSuggestion }: {
  commentBody: string
  disabled: boolean
  selection: SelectionRange
  setCommentBody: (value: string) => void
  setSuggestionMarkdown: (value: string) => void
  suggestionMarkdown: string
  canSuggest: boolean
  onComment: () => void
  onSuggestion: () => void
}) {
  if (disabled) return null

  return (
    <div
      className="absolute z-30 w-[min(28rem,calc(100%-2rem))] rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900"
      style={{
        left: selection.rect ? `${Math.min(Math.max(selection.rect.left, 8), 360)}px` : "1rem",
        top: selection.rect ? `${Math.max(selection.rect.top - 8, 8)}px` : "1rem"
      }}
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-gray-500 dark:text-gray-400">Selected {selection.selectedText.length} characters</p>
      </div>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <div className="space-y-2">
          <Input aria-label="Inline comment" disabled={disabled} placeholder="Comment on selection" value={commentBody} onChange={(event) => setCommentBody(event.target.value)} />
          <Button disabled={disabled || commentBody.trim().length === 0} onClick={onComment} size="sm" variant="secondary">Comment</Button>
        </div>
        {canSuggest ? <div className="space-y-2">
          <Input aria-label="Suggested replacement" disabled={disabled} placeholder="Suggested replacement" value={suggestionMarkdown} onChange={(event) => setSuggestionMarkdown(event.target.value)} />
          <Button disabled={disabled || suggestionMarkdown.trim().length === 0} onClick={onSuggestion} size="sm" variant="secondary">Suggest</Button>
        </div> : null}
      </div>
    </div>
  )
}

function ThreadPanel({ doc, focusedThreadId, replyBodies, threadRefs, onFocus, onReply, onReplyChange, onResolve }: {
  doc: DesignDocDetail
  focusedThreadId: number | null
  replyBodies: Record<number, string>
  threadRefs: React.MutableRefObject<Record<number, HTMLDivElement | null>>
  onFocus: (threadId: number) => void
  onReply: (threadId: number) => void
  onReplyChange: (threadId: number, body: string) => void
  onResolve: (threadId: number) => void
}) {
  return (
    <Panel className="relative min-h-[36rem]">
      <SectionHeading as="h3">Threads</SectionHeading>
      <div className="relative mt-3 space-y-3">
        {doc.threads.length === 0 ? <p className="text-sm text-gray-500 dark:text-gray-400">No inline comments.</p> : null}
        {doc.threads.map((thread) => (
          <div
            className={`rounded border p-3 transition ${focusedThreadId === thread.id ? "border-amber-400 bg-amber-50 dark:border-amber-500 dark:bg-amber-950/30" : "border-gray-200 dark:border-gray-700"}`}
            data-anchor-offset={thread.anchor.last_known_start_offset ?? thread.anchor.start_offset}
            key={thread.id}
            onClick={() => onFocus(thread.id)}
            ref={(element) => { threadRefs.current[thread.id] = element }}
            style={{ marginTop: railOffset(thread) }}
          >
            <div className="flex items-center justify-between gap-2">
              <div className="flex flex-wrap items-center gap-2">
                <StatusLabel value={thread.state} />
                {thread.anchor.status !== "active" ? <StatusLabel value={thread.anchor.status} /> : null}
              </div>
              {thread.state === "open" ? (
                <Button
                  onClick={(event) => {
                    event.stopPropagation()
                    onResolve(thread.id)
                  }}
                  size="sm"
                  variant="secondary"
                >
                  Resolve
                </Button>
              ) : null}
            </div>
            <p className="mt-2 rounded bg-gray-50 p-2 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{thread.anchor.selected_text || thread.anchor.selected_markdown || "Selection"}</p>
            <div className="mt-2 space-y-2 border-l-2 border-gray-200 pl-3 dark:border-gray-700">
              {thread.comments.map((comment) => (
                <div className="text-sm text-gray-800 dark:text-gray-200" key={comment.id}>
                  <p>{comment.body}</p>
                  <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{comment.author?.name || comment.author_kind}</p>
                </div>
              ))}
            </div>
            {thread.state === "open" ? (
              <div className="mt-3 flex gap-2">
                <Input
                  aria-label={`Reply to thread ${thread.id}`}
                  onClick={(event) => event.stopPropagation()}
                  onChange={(event) => onReplyChange(thread.id, event.target.value)}
                  placeholder="Reply"
                  value={replyBodies[thread.id] ?? ""}
                />
                <Button
                  disabled={(replyBodies[thread.id] ?? "").trim().length === 0}
                  onClick={(event) => {
                    event.stopPropagation()
                    onReply(thread.id)
                  }}
                  size="sm"
                  variant="secondary"
                >
                  Reply
                </Button>
              </div>
            ) : null}
          </div>
        ))}
      </div>
    </Panel>
  )
}

function SuggestionPanel({ doc, onReview }: { doc: DesignDocDetail; onReview: (id: number, decision: "accept" | "reject") => void }) {
  const canReview = doc.permissions.can_review_suggestions
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
              <del className="rounded bg-warning/10 p-2 text-warning">{suggestion.original_markdown}</del>
              <ins className="rounded bg-success/10 p-2 text-success no-underline">{suggestion.proposed_markdown}</ins>
            </div>
            {suggestion.change_summary ? <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{suggestion.change_summary}</p> : null}
            {suggestion.conflict_reason ? <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">{suggestion.conflict_reason}</p> : null}
            {suggestion.state === "pending" && canReview ? (
              <div className="mt-3 flex gap-2">
                <Button onClick={() => onReview(suggestion.id, "accept")} size="sm" variant="success">Accept</Button>
                <Button onClick={() => onReview(suggestion.id, "reject")} size="sm" variant="secondary">Reject</Button>
              </div>
            ) : suggestion.state === "pending" ? <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">Pending owner review.</p> : null}
          </div>
        ))}
      </div>
    </Panel>
  )
}

function Panel({ children, className = "", tone = "default" }: { children: React.ReactNode; className?: string; tone?: "default" | "error" }) {
  const colors = tone === "error" ? "border-red-200 bg-red-50 text-red-800 dark:border-red-800 dark:bg-red-950/40 dark:text-red-200" : "border-gray-200 bg-white text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200"
  return <div className={`rounded border p-4 ${colors} ${className}`}>{children}</div>
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

function popoverAlignmentForTrigger(triggerRect: DOMRect, popoverWidth: number, containerRect: DOMRect | null = null): PopoverAlignment {
  const clippingRect = containerRect && containerRect.width > 0 ? containerRect : null
  const viewport = window.visualViewport && window.visualViewport.width > 0 ? window.visualViewport : null
  const viewportLeft = viewport?.offsetLeft ?? 0
  const viewportRight = viewport ? viewportLeft + viewport.width : window.innerWidth
  const boundaryLeft = Math.max(POPOVER_VIEWPORT_MARGIN, clippingRect?.left ?? POPOVER_VIEWPORT_MARGIN, viewportLeft + POPOVER_VIEWPORT_MARGIN)
  const boundaryRight = Math.min(viewportRight - POPOVER_VIEWPORT_MARGIN, clippingRect?.right ?? viewportRight - POPOVER_VIEWPORT_MARGIN)
  const startOverflow = Math.max(0, triggerRect.left + popoverWidth - boundaryRight)
  const endOverflow = Math.max(0, boundaryLeft - (triggerRect.right - popoverWidth))

  if (startOverflow === 0 || startOverflow <= endOverflow) return "start"

  return "end"
}

function anchorPayload(selection: SelectionRange) {
  return {
    start_offset: selection.start,
    end_offset: selection.end,
    selected_markdown: selection.text,
    selected_text: selection.selectedText
  }
}

function markdownToWysiwygHtml(markdown: string, highlights: AnchorHighlight[] = [], focusedThreadId: number | null = null) {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n")
  const blocks: string[] = []
  let index = 0
  let offset = 0

  while (index < lines.length) {
    const line = lines[index]
    if (line.trim() === "") {
      offset += line.length + 1
      index += 1
      continue
    }

    const heading = line.match(/^(#{1,3})\s+(.+)$/)
    if (heading) {
      const level = heading[1].length
      const headingOffset = offset + heading[1].length + 1
      blocks.push(`<h${level}>${renderWysiwygInline(heading[2], highlights, headingOffset, focusedThreadId)}</h${level}>`)
      offset += line.length + 1
      index += 1
      continue
    }

    const unordered = line.match(/^\s*[-*+]\s+(.+)$/)
    if (unordered) {
      const items: string[] = []
      while (index < lines.length) {
        const itemLine = lines[index]
        const item = itemLine.match(/^(\s*[-*+]\s+)(.+)$/)
        if (!item) break
        items.push(`<li>${renderWysiwygInline(item[2], highlights, offset + item[1].length, focusedThreadId)}</li>`)
        offset += itemLine.length + 1
        index += 1
      }
      blocks.push(`<ul>${items.join("")}</ul>`)
      continue
    }

    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/)
    if (ordered) {
      const items: string[] = []
      while (index < lines.length) {
        const itemLine = lines[index]
        const item = itemLine.match(/^(\s*\d+[.)]\s+)(.+)$/)
        if (!item) break
        items.push(`<li>${renderWysiwygInline(item[2], highlights, offset + item[1].length, focusedThreadId)}</li>`)
        offset += itemLine.length + 1
        index += 1
      }
      blocks.push(`<ol>${items.join("")}</ol>`)
      continue
    }

    const paragraph: string[] = []
    while (index < lines.length && lines[index].trim() !== "" && !/^(#{1,3})\s+/.test(lines[index]) && !/^\s*(?:[-*+]|\d+[.)])\s+/.test(lines[index])) {
      const paragraphLine = lines[index]
      const leading = paragraphLine.length - paragraphLine.trimStart().length
      paragraph.push(renderWysiwygInline(paragraphLine.trim(), highlights, offset + leading, focusedThreadId))
      offset += paragraphLine.length + 1
      index += 1
    }
    blocks.push(`<p>${paragraph.join("<br>")}</p>`)
  }

  return blocks.join("")
}

function renderWysiwygInline(markdown: string, highlights: AnchorHighlight[] = [], baseOffset = 0, focusedThreadId: number | null = null) {
  return renderHighlightedHtml(markdown, highlights, baseOffset, focusedThreadId)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
}

function wysiwygHtmlToMarkdown(element: HTMLElement | null) {
  if (!element) return ""

  return Array.from(element.childNodes)
    .map((node) => nodeToMarkdown(node))
    .filter((block) => block.trim().length > 0)
    .join("\n\n")
}

function nodeToMarkdown(node: ChildNode): string {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent?.trim() ?? ""
  if (!(node instanceof HTMLElement)) return ""
  if (node.dataset.inlineSuggestionState) return node.querySelector("del")?.textContent?.trim() ?? ""

  const text = inlineMarkdownText(node).trim()
  if (text.length === 0) return ""

  if (/^H[1-3]$/.test(node.tagName)) return `${"#".repeat(Number(node.tagName.slice(1)))} ${text}`
  if (node.tagName === "LI") return `- ${text}`
  if (node.tagName === "UL") return Array.from(node.children).map((child) => nodeToMarkdown(child)).join("\n")
  if (node.tagName === "OL") return Array.from(node.children).map((child, childIndex) => `${childIndex + 1}. ${inlineMarkdownText(child).trim()}`).join("\n")
  if (node.tagName === "BLOCKQUOTE") return text.split("\n").map((line) => `> ${line}`).join("\n")

  return text
}

function inlineMarkdownText(node: ChildNode): string {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent ?? ""
  if (!(node instanceof HTMLElement)) return ""
  if (node.dataset.inlineSuggestionState) return node.querySelector("del")?.textContent ?? ""
  if (node.tagName === "BR") return "\n"
  if (node.childNodes.length === 0) return node.textContent ?? ""

  return Array.from(node.childNodes).map((child) => inlineMarkdownText(child)).join("")
}

function escapeHtml(value: string) {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function buildAnchorHighlights(doc: DesignDocDetail): AnchorHighlight[] {
  const threadHighlights = doc.threads
    .filter((thread) => thread.anchor.anchor_kind === "range")
    .map((thread) => {
      const start = thread.anchor.last_known_start_offset ?? thread.anchor.start_offset
      const end = thread.anchor.last_known_end_offset ?? thread.anchor.end_offset
      return {
        id: `thread-${thread.id}`,
        kind: "thread" as const,
        threadId: thread.id,
        status: thread.anchor.status,
        start: start ?? 0,
        end: end ?? start ?? 0
      }
    })

  const suggestionHighlights = doc.suggestions
    .filter((suggestion) => suggestion.state === "pending" && suggestion.anchor.anchor_kind === "range")
    .map((suggestion) => {
      const start = suggestion.anchor.last_known_start_offset ?? suggestion.anchor.start_offset
      const end = suggestion.anchor.last_known_end_offset ?? suggestion.anchor.end_offset
      return {
        id: `suggestion-${suggestion.id}`,
        kind: "suggestion" as const,
        proposedMarkdown: suggestion.proposed_markdown,
        suggestionState: suggestion.state,
        status: suggestion.anchor.status,
        start: start ?? 0,
        end: end ?? start ?? 0
      }
    })

  return [...threadHighlights, ...suggestionHighlights]
    .filter((highlight) => highlight.status === "active" && highlight.end > highlight.start)
    .sort((a, b) => a.start - b.start || b.end - a.end)
}

function highlightTextSegments(text: string, highlights: AnchorHighlight[]) {
  const segments: Array<{ text: string; highlight: AnchorHighlight | null }> = []
  let cursor = 0

  for (const highlight of highlights) {
    const start = Math.max(0, Math.min(text.length, highlight.start))
    const end = Math.max(start, Math.min(text.length, highlight.end))
    if (end <= cursor) continue
    if (start > cursor) segments.push({ text: text.slice(cursor, start), highlight: null })
    segments.push({ text: text.slice(Math.max(start, cursor), end), highlight })
    cursor = end
  }

  if (cursor < text.length) segments.push({ text: text.slice(cursor), highlight: null })
  return segments
}

function renderHighlightedHtml(text: string, highlights: AnchorHighlight[], baseOffset: number, focusedThreadId: number | null) {
  return highlightTextSegments(text, highlights.map((highlight) => ({
    ...highlight,
    start: highlight.start - baseOffset,
    end: highlight.end - baseOffset
  })).filter((highlight) => highlight.end > 0 && highlight.start < text.length))
    .map((segment) => {
      if (!segment.highlight) return escapeHtml(segment.text)

      const focused = segment.highlight.threadId === focusedThreadId
      if (segment.highlight.kind === "suggestion") {
        return [
          `<mark class="rounded-sm bg-surface-raised px-0.5" data-anchor-highlight="${segment.highlight.id}" data-anchor-status="${escapeHtml(segment.highlight.status)}" data-inline-suggestion-state="${escapeHtml(segment.highlight.suggestionState || "")}">`,
          `<del class="text-warning decoration-warning decoration-2">${escapeHtml(segment.text)}</del>`,
          `<ins class="ml-1 text-success no-underline">${escapeHtml(segment.highlight.proposedMarkdown || "")}</ins>`,
          "</mark>"
        ].join("")
      }

      const className = focused
        ? "rounded-sm bg-amber-300/70 px-0.5 ring-1 ring-amber-500 dark:bg-amber-500/50"
        : "rounded-sm bg-yellow-200/80 px-0.5 dark:bg-yellow-500/30"
      const threadAttrs = segment.highlight.threadId ? ` data-thread-id="${segment.highlight.threadId}"` : ""
      return `<mark class="${className}" data-anchor-highlight="${segment.highlight.id}" data-anchor-status="${escapeHtml(segment.highlight.status)}"${threadAttrs}>${escapeHtml(segment.text)}</mark>`
    })
    .join("")
}

function markdownOffsetForRenderedOffset(markdown: string, renderedOffset: number, affinity: "start" | "end") {
  const mapping = renderedToMarkdownMap(markdown)
  if (renderedOffset <= 0) return 0
  if (affinity === "end") {
    const previous = mapping[Math.min(renderedOffset - 1, mapping.length - 1)]
    return previous == null ? markdown.length : previous + 1
  }

  return mapping[renderedOffset] ?? markdown.length
}

function renderedToMarkdownMap(markdown: string) {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n")
  const mapping: number[] = []
  let sourceOffset = 0
  let lineIndex = 0

  while (lineIndex < lines.length) {
    const line = lines[lineIndex]
    if (line.trim() === "") {
      sourceOffset += line.length + 1
      lineIndex += 1
      continue
    }

    const heading = line.match(/^(#{1,3})\s+(.+)$/)
    if (heading) {
      appendInlineRenderedMap(heading[2], sourceOffset + heading[1].length + 1, mapping)
      sourceOffset += line.length + 1
      lineIndex += 1
      continue
    }

    if (/^\s*[-*+]\s+/.test(line)) {
      while (lineIndex < lines.length) {
        const itemLine = lines[lineIndex]
        const item = itemLine.match(/^(\s*[-*+]\s+)(.+)$/)
        if (!item) break
        appendInlineRenderedMap(item[2], sourceOffset + item[1].length, mapping)
        sourceOffset += itemLine.length + 1
        lineIndex += 1
      }
      continue
    }

    if (/^\s*\d+[.)]\s+/.test(line)) {
      while (lineIndex < lines.length) {
        const itemLine = lines[lineIndex]
        const item = itemLine.match(/^(\s*\d+[.)]\s+)(.+)$/)
        if (!item) break
        appendInlineRenderedMap(item[2], sourceOffset + item[1].length, mapping)
        sourceOffset += itemLine.length + 1
        lineIndex += 1
      }
      continue
    }

    while (lineIndex < lines.length && lines[lineIndex].trim() !== "" && !/^(#{1,3})\s+/.test(lines[lineIndex]) && !/^\s*(?:[-*+]|\d+[.)])\s+/.test(lines[lineIndex])) {
      const paragraphLine = lines[lineIndex]
      const leading = paragraphLine.length - paragraphLine.trimStart().length
      appendInlineRenderedMap(paragraphLine.trim(), sourceOffset + leading, mapping)
      sourceOffset += paragraphLine.length + 1
      lineIndex += 1
    }
  }

  return mapping
}

function appendInlineRenderedMap(markdown: string, baseOffset: number, mapping: number[]) {
  let index = 0

  while (index < markdown.length) {
    const strong = markdown.slice(index).match(/^\*\*([^*]+)\*\*/)
    if (strong) {
      appendRangeMap(baseOffset + index + 2, strong[1].length, mapping)
      index += strong[0].length
      continue
    }

    const emphasis = markdown.slice(index).match(/^\*([^*]+)\*/)
    if (emphasis) {
      appendRangeMap(baseOffset + index + 1, emphasis[1].length, mapping)
      index += emphasis[0].length
      continue
    }

    const code = markdown.slice(index).match(/^`([^`]+)`/)
    if (code) {
      appendRangeMap(baseOffset + index + 1, code[1].length, mapping)
      index += code[0].length
      continue
    }

    const link = markdown.slice(index).match(/^\[([^\]]+)\]\([^)]+\)/)
    if (link) {
      appendRangeMap(baseOffset + index + 1, link[1].length, mapping)
      index += link[0].length
      continue
    }

    mapping.push(baseOffset + index)
    index += 1
  }
}

function appendRangeMap(startOffset: number, length: number, mapping: number[]) {
  for (let index = 0; index < length; index += 1) {
    mapping.push(startOffset + index)
  }
}

function textareaSelectionRect(textarea: HTMLTextAreaElement, start: number, end: number): SelectionRect {
  const rect = textarea.getBoundingClientRect()
  const textBefore = textarea.value.slice(0, Math.max(start, end))
  const lines = textBefore.split("\n")
  const lineHeight = 24
  const charWidth = 8
  return {
    left: Math.min(rect.width - 32, 16 + lines.at(-1)!.length * charWidth),
    top: Math.min(rect.height - 80, 16 + (lines.length - 1) * lineHeight - textarea.scrollTop)
  }
}

function rangeSelectionRect(range: Range, container: HTMLElement | null): SelectionRect | null {
  if (!container) return null
  if (!("getBoundingClientRect" in range) || typeof range.getBoundingClientRect !== "function") return null

  const rangeRect = range.getBoundingClientRect()
  const containerRect = container.getBoundingClientRect()
  if (rangeRect.width === 0 && rangeRect.height === 0) return null

  return {
    left: rangeRect.left - containerRect.left,
    top: rangeRect.bottom - containerRect.top
  }
}

function railOffset(thread: DesignDocThread) {
  const offset = thread.anchor.last_known_start_offset ?? thread.anchor.start_offset ?? 0
  return `${Math.min(Math.max(Math.floor(offset / 8), 0), 96)}px`
}
