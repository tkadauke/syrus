import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState, type ChangeEvent, type KeyboardEvent, type ReactNode } from "react"
import { useLocation, useNavigate, useParams } from "react-router-dom"
import { Button } from "@app/components/Button"
import { AdminSmartFolderNav } from "@app/components/AdminSmartFolderNav"
import { FilterBar } from "@app/components/FilterBar"
import { Input } from "@app/components/Input"
import { Select } from "@app/components/Select"
import { PageHeading, SectionHeading } from "@app/components/Heading"
import { NoticeToast } from "@app/components/NoticeToast"
import { useMediaQuery } from "@app/routes/dashboard/components"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { fetchRepositories } from "@app/api/repositories"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix } from "@app/lib/routing"
import { useDismissiblePopup } from "@app/lib/useDismissiblePopup"
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
  type DesignDocSuggestion,
  type DesignDocThread,
  type DesignDocSummary,
  type DesignDocVersion
} from "../api/designDocs"
import {
  applyDesignDocFormattingCommand,
  canApplyDesignDocFormattingCommand,
  type DesignDocFormattingCommand,
  type DesignDocFormattingSelection
} from "./designDocFormattingCommands"

type SurfaceMode = "index" | "repository" | "show" | "chat"
type EditorMode = "rich_text" | "markdown"
type ChangeMode = "edit" | "suggest"
type SelectionRange = { start: number; end: number; text: string; selectedText: string; rect: SelectionRect | null }
type SelectionRect = { top: number; left: number; containerWidth: number }
type InlineToken = { kind: "text" | "code" | "strong" | "emphasis" | "strike" | "link"; text: string; sourceStart: number; href?: string }
type ToolbarBlockCommand = "paragraph" | "heading_1" | "heading_2" | "heading_3" | "heading_4" | "blockquote" | "fenced_code"
type AnchorHighlight = {
  id: string
  kind: "thread" | "suggestion"
  threadId?: number
  suggestionId?: number
  proposedMarkdown?: string
  suggestionState?: string
  status: string
  start: number
  end: number
}

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
  const showIndexControls = mode === "index" || mode === "repository"
  const showDocList = showIndexControls
  const showPageHeader = showIndexControls
  const indexQuery = useQuery({
    queryKey: mode === "repository" ? ["design_docs", "repository", String(repositoryId), search] : ["design_docs", search],
    queryFn: () => mode === "repository" && repositoryId ? fetchRepositoryDesignDocs(repositoryId, search) : fetchDesignDocs(search),
    enabled: showIndexControls
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
      {showPageHeader ? (
        <header className="flex flex-wrap items-center justify-between gap-3">
          <div>
            {compact ? <SectionHeading>Design Docs</SectionHeading> : <PageHeading>Design Docs</PageHeading>}
            <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
              {mode === "repository" ? "Docs associated with this repository." : "Collaborative Markdown design documents."}
            </p>
          </div>
          <Button disabled={createMutation.isPending} onClick={() => createMutation.mutate()} size="sm">
            New doc
          </Button>
        </header>
      ) : null}
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
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
                if (message) setNotice(message)
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

function persistedDraftFingerprint(docId: string | number, title: string, markdown: string) {
  return `${docId}:${title}:${markdown}`
}

function emptySelection(): SelectionRange {
  return { start: 0, end: 0, text: "", selectedText: "", rect: null }
}

function DesignDocEditor({ doc, mode, repositories, onDocChange }: { doc: DesignDocDetail; mode: SurfaceMode; repositories: Array<{ id: number; slug: string }>; onDocChange: (doc: DesignDocDetail, message?: string) => void }) {
  const [draft, setDraft] = useState(doc.rendered_markdown || doc.markdown)
  const [editorMode, setEditorMode] = useState<EditorMode>("rich_text")
  const [title, setTitle] = useState(doc.title)
  const [summary, setSummary] = useState("")
  const [summaryVisible, setSummaryVisible] = useState(false)
  const [selection, setSelection] = useState<SelectionRange>(emptySelection)
  const [commentBody, setCommentBody] = useState("")
  const [focusedThreadId, setFocusedThreadId] = useState<number | null>(null)
  const [focusedSuggestionId, setFocusedSuggestionId] = useState<number | null>(null)
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
  const [changeMode, setChangeMode] = useState<ChangeMode>(canWriteCanonical ? "edit" : "suggest")
  const effectiveChangeMode: ChangeMode = canWriteCanonical ? changeMode : "suggest"
  const saveLabel = effectiveChangeMode === "edit" ? "Save" : "Suggest changes"
  const saveDisabled = effectiveChangeMode === "suggest" && !canSuggest
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const wysiwygRef = useRef<HTMLDivElement | null>(null)
  const editorShellRef = useRef<HTMLDivElement | null>(null)
  const newThreadComposerRef = useRef<HTMLInputElement | null>(null)
  const threadRefs = useRef<Record<number, HTMLDivElement | null>>({})
  const suggestionRefs = useRef<Record<number, HTMLDivElement | null>>({})
  const persistedDraftRef = useRef(persistedDraftFingerprint(doc.id, doc.title, doc.rendered_markdown || doc.markdown))
  const versions = useQuery({
    queryKey: ["design_docs", "versions", String(doc.id)],
    queryFn: () => fetchDesignDocVersions(doc.id),
    enabled: versionsOpen
  })
  const saveMutation = useMutation({
    mutationFn: () => effectiveChangeMode === "edit"
      ? updateDesignDoc(doc.id, {
        title,
        markdown: draft,
        change_summary: summary,
        checkpoint: true,
        visibility: doc.visibility,
        state: doc.state,
        repository_ids: repoIds.map(Number),
        collaborator_user_ids: collaborators.split(",").map((part) => part.trim()).filter(Boolean).map(Number)
      })
      : createDesignDocSuggestion(doc.id, {
        start_offset: 0,
        end_offset: doc.rendered_markdown.length,
        original_markdown: doc.rendered_markdown,
        proposed_markdown: draft,
        change_summary: summary
      }),
    onSuccess: (payload) => {
      persistedDraftRef.current = persistedDraftFingerprint(doc.id, title, draft)
      setSummary("")
      setSummaryVisible(false)
      onDocChange(payload.design_doc, effectiveChangeMode === "suggest" || payload.mode === "suggestion" ? "Saved as a suggestion for owner review." : "Design doc saved.")
    }
  })
  const autosaveMutation = useMutation({
    mutationFn: () => effectiveChangeMode === "edit"
      ? updateDesignDoc(doc.id, {
        title,
        markdown: draft,
        visibility: doc.visibility,
        state: doc.state,
        repository_ids: repoIds.map(Number),
        collaborator_user_ids: collaborators.split(",").map((part) => part.trim()).filter(Boolean).map(Number)
      })
      : createDesignDocSuggestion(doc.id, {
        start_offset: 0,
        end_offset: doc.rendered_markdown.length,
        original_markdown: doc.rendered_markdown,
        proposed_markdown: draft,
        autosave: true
      }),
    onSuccess: (payload) => {
      persistedDraftRef.current = persistedDraftFingerprint(doc.id, title, draft)
      onDocChange(payload.design_doc)
    }
  })
  const metadataMutation = useMutation({
    mutationFn: (input: { visibility?: "private" | "public"; state?: "draft" | "accepted" | "archived"; repository_ids?: number[]; collaborator_user_ids?: number[] }) => updateDesignDoc(doc.id, input),
    onSuccess: (payload) => onDocChange(payload.design_doc, "Design doc controls updated.")
  })
  const commentMutation = useMutation({
    mutationFn: () => createDesignDocComment(doc.id, { body: commentBody, ...anchorPayload(selection) }),
    onSuccess: (payload) => {
      setCommentBody("")
      setSelection(emptySelection())
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
  const reviewMutation = useMutation({
    mutationFn: ({ id, decision }: { id: number; decision: "accept" | "reject" }) => decision === "accept" ? acceptDesignDocSuggestion(doc.id, id) : rejectDesignDocSuggestion(doc.id, id),
    onSuccess: (payload) => onDocChange(payload.design_doc, payload.message || "Suggestion reviewed.")
  })
  const resolveMutation = useMutation({
    mutationFn: (threadId: number) => resolveDesignDocThread(doc.id, threadId),
    onSuccess: (_payload, threadId) => onDocChange({ ...doc, threads: doc.threads.map((thread) => thread.id === threadId ? { ...thread, state: "resolved" } : thread) }, "Thread resolved.")
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
    if (start === end) {
      setSelection({ start, end, text: "", selectedText: "", rect: null })
      return
    }

    const text = target.value.slice(start, end)
    setSelection({ start, end, text, selectedText: text, rect: textareaSelectionRect(target, start, end) })
  }

  function updateWysiwygSelection() {
    if (!wysiwygRef.current) return

    const range = document.getSelection()
    if (!range || range.rangeCount === 0) {
      setSelection(emptySelection())
      return
    }

    const selectedRange = range.getRangeAt(0)
    if (!wysiwygRef.current.contains(selectedRange.commonAncestorContainer)) {
      setSelection(emptySelection())
      return
    }

    const selectedText = selectedRange.toString()
    const sourceStart = sourceOffsetForSelectionBoundary(wysiwygRef.current, selectedRange.startContainer, selectedRange.startOffset, "start")
    const sourceEnd = sourceOffsetForSelectionBoundary(wysiwygRef.current, selectedRange.endContainer, selectedRange.endOffset, "end")
    if (sourceStart == null || sourceEnd == null) {
      setSelection(emptySelection())
      return
    }

    const start = Math.max(0, Math.min(draft.length, sourceStart))
    const end = Math.max(start, Math.min(draft.length, sourceEnd))
    if (range.isCollapsed || start === end) {
      setSelection({ start, end, text: "", selectedText: "", rect: null })
      return
    }

    setSelection({
      start,
      end,
      text: draft.slice(start, end),
      selectedText,
      rect: rangeSelectionRect(selectedRange, editorShellRef.current)
    })
  }

  function applyFormattingCommand(command: DesignDocFormattingCommand) {
    const activeSelection = selection.end >= selection.start ? selection : { start: 0, end: 0, text: "", selectedText: "", rect: null }
    const options = command === "link" ? { href: window.prompt("Link URL", "https://example.com") || "" } : {}
    const result = applyDesignDocFormattingCommand(draft, activeSelection, command, options)
    if (!result.applied) return

    setDraft(result.markdown)
    setSelection({
      start: result.selection.start,
      end: result.selection.end,
      text: result.markdown.slice(result.selection.start, result.selection.end),
      selectedText: result.markdown.slice(result.selection.start, result.selection.end),
      rect: null
    })
    if (editorMode === "markdown") {
      window.setTimeout(() => {
        textareaRef.current?.focus()
        textareaRef.current?.setSelectionRange(result.selection.start, result.selection.end)
      }, 0)
    } else {
      window.setTimeout(() => {
        if (!wysiwygRef.current) return

        const nextHighlights = result.markdown === (doc.rendered_markdown || doc.markdown) ? activeHighlights : []
        wysiwygRef.current.innerHTML = markdownToWysiwygHtml(result.markdown, nextHighlights, focusedThreadId, focusedSuggestionId)
        wysiwygRef.current.focus()
      }, 0)
    }
  }

  useEffect(() => {
    if (editorMode !== "rich_text" || !wysiwygRef.current) return
    if (document.activeElement === wysiwygRef.current) return

    const nextHtml = markdownToWysiwygHtml(draft, activeHighlights, focusedThreadId, focusedSuggestionId)
    if (wysiwygRef.current.innerHTML !== nextHtml) wysiwygRef.current.innerHTML = nextHtml
  }, [draft, editorMode, focusedThreadId, focusedSuggestionId, activeHighlights])

  useEffect(() => {
    if (!canWriteCanonical) setChangeMode("suggest")
  }, [canWriteCanonical, doc.id])

  useEffect(() => {
    persistedDraftRef.current = persistedDraftFingerprint(doc.id, doc.title, doc.rendered_markdown || doc.markdown)
  }, [canWriteCanonical, doc.id])

  useEffect(() => {
    const fingerprint = persistedDraftFingerprint(doc.id, title, draft)
    if (fingerprint === persistedDraftRef.current) return
    if (autosaveMutation.isPending) return

    const timeout = window.setTimeout(() => autosaveMutation.mutate(), 800)
    return () => window.clearTimeout(timeout)
  }, [autosaveMutation, doc.id, draft, effectiveChangeMode, title])

  useEffect(() => {
    if (!focusedThreadId) return

    threadRefs.current[focusedThreadId]?.scrollIntoView?.({ block: "nearest", behavior: "smooth" })
  }, [focusedThreadId])

  useEffect(() => {
    if (!focusedSuggestionId) return

    suggestionRefs.current[focusedSuggestionId]?.scrollIntoView?.({ block: "nearest", behavior: "smooth" })
  }, [focusedSuggestionId])

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
    setFocusedSuggestionId(null)
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

  function focusSuggestion(suggestionId: number) {
    setFocusedSuggestionId(suggestionId)
    setFocusedThreadId(null)
    const suggestion = doc.suggestions.find((candidate) => candidate.id === suggestionId)
    const anchor = suggestion?.anchor
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

    const marker = wysiwygRef.current?.querySelector(`[data-suggestion-id="${suggestionId}"]`) as HTMLElement | null
    marker?.scrollIntoView?.({ block: "center", behavior: "smooth" })
  }

  function focusThreadAtOffset(offset: number) {
    const match = activeHighlights.find((highlight) => offset >= highlight.start && offset <= highlight.end)
    if (match?.threadId) focusThread(match.threadId)
    if (match?.suggestionId) focusSuggestion(match.suggestionId)
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
        onSave={() => {
          if (effectiveChangeMode === "edit" && !summaryVisible) {
            setSummaryVisible(true)
            return
          }

          saveMutation.mutate()
        }}
        saveLabel={saveLabel}
        saveDisabled={saveDisabled}
        canManageMetadata={canWriteCanonical}
        onVersionChange={selectVersion}
        onVersionsOpen={() => setVersionsOpen(true)}
        onVisibilityChange={(visibility) => metadataMutation.mutate({ visibility })}
      />
      <div className={`grid min-w-0 gap-4 ${mode === "chat" ? "" : "xl:grid-cols-[minmax(0,1fr)_22rem]"}`}>
      <section className="min-w-0 space-y-4">
        <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          {summaryVisible ? (
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
            {summaryVisible ? <Input aria-label="Change summary" className="min-w-[12rem] flex-1" placeholder="Optional change summary" value={summary} onChange={(event) => setSummary(event.target.value)} /> : null}
          </div>
          ) : null}
          <DesignDocFormattingToolbar
            canWriteCanonical={canWriteCanonical}
            changeMode={effectiveChangeMode}
            draft={draft}
            editorMode={editorMode}
            selection={selection}
            setChangeMode={setChangeMode}
            setEditorMode={setEditorMode}
            onCommand={applyFormattingCommand}
          />
          <div className="relative" ref={editorShellRef}>
          {editorMode === "markdown" ? (
            <label className="relative flex min-h-[36rem] flex-col overflow-hidden">
              <span className="sr-only">Markdown editor</span>
              <MarkdownHighlightMirror draft={draft} focusedSuggestionId={focusedSuggestionId} focusedThreadId={focusedThreadId} highlights={activeHighlights} scrollTop={markdownScrollTop} />
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
              aria-label="Rich Text editor"
              className="chat-prose min-h-[36rem] max-w-none p-4 text-sm leading-6 text-gray-900 outline-none focus:ring-2 focus:ring-brand dark:text-gray-100"
              contentEditable
              onBlur={() => {
                setDraft(wysiwygHtmlToMarkdown(wysiwygRef.current))
                window.setTimeout(() => {
                  if (document.activeElement === newThreadComposerRef.current) return
                  updateWysiwygSelection()
                }, 0)
              }}
              onClick={(event) => {
                const target = event.target as HTMLElement
                const suggestionMarker = target.closest("[data-suggestion-id]") as HTMLElement | null
                if (suggestionMarker?.dataset.suggestionId) {
                  focusSuggestion(Number(suggestionMarker.dataset.suggestionId))
                  return
                }
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
          <SelectionCommentAffordance
            disabled={selection.end <= selection.start}
            selection={selection}
            onOpenComposer={() => {
              setFocusedThreadId(null)
              setFocusedSuggestionId(null)
              window.setTimeout(() => newThreadComposerRef.current?.focus(), 0)
            }}
          />
          </div>
        </div>
      </section>
      <aside className="space-y-4">
          <ThreadPanel
          commentBody={commentBody}
          commentPending={commentMutation.isPending}
          composerRef={newThreadComposerRef}
          doc={doc}
          focusedThreadId={focusedThreadId}
          focusedSuggestionId={focusedSuggestionId}
          replyBodies={replyBodies}
          selection={selection}
          suggestionRefs={suggestionRefs}
          threadRefs={threadRefs}
          onFocus={focusThread}
          onFocusSuggestion={focusSuggestion}
          onComment={() => commentMutation.mutate()}
          onCommentChange={setCommentBody}
          onReply={(threadId) => {
            const body = replyBodies[threadId]?.trim()
            if (body) replyMutation.mutate({ threadId, body })
          }}
          onReplyChange={(threadId, body) => setReplyBodies((current) => ({ ...current, [threadId]: body }))}
          onResolve={(threadId) => resolveMutation.mutate(threadId)}
          onReview={(id, decision) => reviewMutation.mutate({ id, decision })}
        />
      </aside>
      </div>
    </div>
  )
}

function DesignDocTitleBar({ collaborators, doc, repoIds, repositories, repositoryPickerOpen, selectedRepositories, selectedVersionId, setCollaborators, setRepoIds, setRepositoryPickerOpen, setShareOpen, setTitle, shareOpen, title, versions, versionsLoading, versionsOpen, canManageMetadata, onMetadataSave, onSave, saveLabel, saveDisabled, onVersionChange, onVersionsOpen, onVisibilityChange }: {
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
  saveDisabled: boolean
  onVersionChange: (versionId: string) => void
  onVersionsOpen: () => void
  onVisibilityChange: (visibility: "private" | "public") => void
}) {
  const titleBarRef = useRef<HTMLElement | null>(null)
  const shareButtonRef = useRef<HTMLButtonElement | null>(null)
  const [shareMenuAlignment, setShareMenuAlignment] = useState<"left" | "right">("left")

  function toggleShareMenu() {
    const nextOpen = !shareOpen
    if (nextOpen) {
      const rect = shareButtonRef.current?.getBoundingClientRect()
      if (rect) {
        const menuWidth = 320
        const edgePadding = 16
        const boundary = titleBarRef.current?.getBoundingClientRect()
        const boundaryLeft = boundary?.left ?? 0
        const boundaryRight = boundary?.right ?? window.innerWidth
        const fitsLeftAligned = rect.left + menuWidth <= boundaryRight - edgePadding
        const fitsRightAligned = rect.right - menuWidth >= boundaryLeft + edgePadding
        const spaceToRight = boundaryRight - rect.left
        const spaceToLeft = rect.right - boundaryLeft

        setShareMenuAlignment(fitsLeftAligned || (!fitsRightAligned && spaceToRight >= spaceToLeft) ? "left" : "right")
      }
    }
    setShareOpen(nextOpen)
  }

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
          {canManageMetadata ? <Button aria-expanded={shareOpen} onClick={toggleShareMenu} ref={shareButtonRef} size="sm" variant="secondary">Share</Button> : <StatusLabel value="review only" />}
          {shareOpen && canManageMetadata ? (
            <div
              className={`absolute z-20 mt-2 w-80 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-950 ${shareMenuAlignment === "left" ? "left-0" : "right-0"}`}
              data-testid="design-doc-share-menu"
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
        <Button disabled={saveDisabled} onClick={onSave} size="sm">{saveLabel}</Button>
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

function MarkdownHighlightMirror({ draft, focusedSuggestionId, focusedThreadId, highlights, scrollTop }: { draft: string; focusedSuggestionId: number | null; focusedThreadId: number | null; highlights: AnchorHighlight[]; scrollTop: number }) {
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 z-0 min-h-[36rem] whitespace-pre-wrap break-words p-4 font-mono text-sm leading-6 text-gray-900 dark:text-gray-100"
      data-testid="markdown-highlight-mirror"
      style={{ transform: scrollTop > 0 ? `translateY(-${scrollTop}px)` : undefined }}
    >
      {highlightTextSegments(draft, highlights).map((segment, index) => {
        if (!segment.highlight) return <span key={index}>{segment.text}</span>

        const focused = segment.highlight.threadId === focusedThreadId || segment.highlight.suggestionId === focusedSuggestionId
        if (segment.highlight.kind === "suggestion") {
          return (
            <span
              className={`rounded-sm px-0.5 ${focused ? "bg-amber-300/70 ring-1 ring-amber-500 dark:bg-amber-500/50" : "bg-surface-raised"}`}
              data-anchor-status={segment.highlight.status}
              data-inline-suggestion-state={segment.highlight.suggestionState}
              key={index}
            >
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

function DesignDocFormattingToolbar({ canWriteCanonical, changeMode, draft, editorMode, selection, setChangeMode, setEditorMode, onCommand }: {
  canWriteCanonical: boolean
  changeMode: ChangeMode
  draft: string
  editorMode: EditorMode
  selection: SelectionRange
  setChangeMode: (mode: ChangeMode) => void
  setEditorMode: (mode: EditorMode) => void
  onCommand: (command: DesignDocFormattingCommand) => void
}) {
  const wideToolbar = useMediaQuery("(min-width: 768px)", true)
  const [moreOpen, setMoreOpen] = useState(false)
  const moreMenuRef = useDismissiblePopup<HTMLDivElement>(moreOpen, () => setMoreOpen(false))
  const range = selection.end >= selection.start ? selection : { start: 0, end: 0 }
  const blockOptions: Array<{ command: ToolbarBlockCommand; label: string }> = [
    { command: "paragraph", label: "Paragraph" },
    { command: "heading_1", label: "H1" },
    { command: "heading_2", label: "H2" },
    { command: "heading_3", label: "H3" },
    { command: "heading_4", label: "H4" },
    { command: "blockquote", label: "Quote" },
    { command: "fenced_code", label: "Code block" }
  ]
  const inlineItems: Array<{ command: DesignDocFormattingCommand; icon: string; label: string; className?: string }> = [
    { command: "bold", icon: "B", label: "Bold", className: "font-black" },
    { command: "italic", icon: "I", label: "Italic", className: "font-serif italic" },
    { command: "inline_code", icon: "`", label: "Inline code", className: "font-mono" },
    { command: "link", icon: "[]", label: "Link" },
    { command: "strikethrough", icon: "S", label: "Strikethrough", className: "line-through" }
  ]
  const listItems: Array<{ command: DesignDocFormattingCommand; icon: string; label: string }> = [
    { command: "unordered_list", icon: "-.", label: "Bulleted list" },
    { command: "ordered_list", icon: "1.", label: "Numbered list" }
  ]
  const moreItems: Array<{ command: DesignDocFormattingCommand; label: string }> = [
    { command: "table", label: "Table" },
    { command: "horizontal_rule", label: "Divider" },
    { command: "nested_list", label: "Indent list item" }
  ]
  const selectedBlock = currentBlockCommand(draft, range)

  function commandDisabled(command: DesignDocFormattingCommand) {
    return !canApplyDesignDocFormattingCommand(draft, range, command)
  }

  function runCommand(command: DesignDocFormattingCommand) {
    if (commandDisabled(command)) return
    setMoreOpen(false)
    onCommand(command)
  }

  return (
    <div
      aria-label="Formatting toolbar"
      className="flex min-w-0 items-center gap-2 border-b border-gray-200 bg-gray-50 px-3 py-2 dark:border-gray-700 dark:bg-gray-950/40"
      data-testid="design-doc-formatting-toolbar"
      role="toolbar"
    >
      <div className="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto" data-testid="design-doc-formatting-toolbar-scroll">
        <div aria-label="Editor mode" className="inline-flex shrink-0 overflow-hidden rounded border border-border bg-surface text-sm" role="tablist">
          {(["rich_text", "markdown"] as EditorMode[]).map((candidate) => (
            <button
              aria-selected={editorMode === candidate}
              className={`px-3 py-1.5 font-medium capitalize ${editorMode === candidate ? "bg-brand text-on-brand" : "text-text-secondary hover:bg-surface-raised"}`}
              key={candidate}
              onClick={() => setEditorMode(candidate)}
              role="tab"
              type="button"
            >
              {candidate === "markdown" ? "Markdown" : "Rich Text"}
            </button>
          ))}
        </div>

        <div aria-label="Change mode" className="inline-flex shrink-0 overflow-hidden rounded border border-border bg-surface text-sm" role="group">
          {canWriteCanonical ? (
            (["edit", "suggest"] as ChangeMode[]).map((candidate) => (
              <button
                aria-pressed={changeMode === candidate}
                className={`px-3 py-1.5 font-medium capitalize ${changeMode === candidate ? "bg-brand text-on-brand" : "text-text-secondary hover:bg-surface-raised"}`}
                key={candidate}
                onClick={() => setChangeMode(candidate)}
                type="button"
              >
                {candidate === "edit" ? "Edit" : "Suggest"}
              </button>
            ))
          ) : (
            <span className="px-3 py-1.5 text-sm font-medium text-text-secondary">Suggest</span>
          )}
        </div>

        <Select
          aria-label="Block type"
          className="h-8 min-w-[8.5rem] shrink-0 py-1 text-xs"
          fullWidth={false}
          value={selectedBlock}
          onChange={(event) => runCommand(event.target.value as ToolbarBlockCommand)}
        >
          {blockOptions.map((option) => (
            <option disabled={commandDisabled(option.command)} key={option.command} value={option.command}>{option.label}</option>
          ))}
        </Select>

        <ToolbarButtonGroup label="Inline formatting">
          {inlineItems.map((item) => (
            <ToolbarIconButton disabled={commandDisabled(item.command)} icon={item.icon} iconClassName={item.className} key={item.command} label={item.label} onClick={() => runCommand(item.command)} />
          ))}
        </ToolbarButtonGroup>

        {wideToolbar ? (
          <ToolbarButtonGroup label="List formatting">
            {listItems.map((item) => (
              <ToolbarIconButton disabled={commandDisabled(item.command)} icon={item.icon} key={item.command} label={item.label} onClick={() => runCommand(item.command)} />
            ))}
          </ToolbarButtonGroup>
        ) : null}
      </div>

      <div className="relative shrink-0" ref={moreMenuRef}>
        <ToolbarIconButton ariaExpanded={moreOpen} icon="..." label="More formatting" onClick={() => setMoreOpen((open) => !open)} />
        {moreOpen ? (
          <div className="absolute right-0 z-20 mt-2 w-56 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900" role="menu">
            {!wideToolbar ? listItems.map((item) => (
              <button
                className="block w-full px-3 py-2 text-left text-sm text-text-primary hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"
                disabled={commandDisabled(item.command)}
                key={item.command}
                onClick={() => runCommand(item.command)}
                role="menuitem"
                type="button"
              >
                {item.label}
              </button>
            )) : null}
            {moreItems.map((item) => (
              <button
                className="block w-full px-3 py-2 text-left text-sm text-text-primary hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"
                disabled={commandDisabled(item.command)}
                key={item.command}
                onClick={() => runCommand(item.command)}
                role="menuitem"
                type="button"
              >
                {item.label}
              </button>
            ))}
            <button className="block w-full border-t border-border px-3 py-2 text-left text-sm text-text-secondary disabled:cursor-not-allowed disabled:opacity-50" disabled role="menuitem" type="button">Table row actions</button>
            <button className="block w-full px-3 py-2 text-left text-sm text-text-secondary disabled:cursor-not-allowed disabled:opacity-50" disabled role="menuitem" type="button">Table column actions</button>
          </div>
        ) : null}
      </div>
    </div>
  )
}

function ToolbarButtonGroup({ children, label }: { children: ReactNode; label: string }) {
  return (
    <div aria-label={label} className="inline-flex shrink-0 overflow-hidden rounded border border-border bg-surface" role="group">
      {children}
    </div>
  )
}

function ToolbarIconButton({ ariaExpanded, disabled = false, icon, iconClassName = "", label, onClick }: {
  ariaExpanded?: boolean
  disabled?: boolean
  icon: string
  iconClassName?: string
  label: string
  onClick: () => void
}) {
  return (
    <button
      aria-expanded={ariaExpanded}
      aria-label={label}
      className="flex h-8 w-8 items-center justify-center border-r border-border text-xs font-semibold text-text-secondary last:border-r-0 hover:bg-surface-raised hover:text-text-primary focus:outline-none focus-visible:ring-2 focus-visible:ring-brand disabled:cursor-not-allowed disabled:opacity-50"
      disabled={disabled}
      onClick={onClick}
      onMouseDown={(event) => event.preventDefault()}
      title={label}
      type="button"
    >
      <span aria-hidden="true" className={iconClassName}>{icon}</span>
    </button>
  )
}

function currentBlockCommand(markdown: string, selection: DesignDocFormattingSelection): ToolbarBlockCommand {
  const start = Math.max(0, Math.min(markdown.length, selection.start))
  const lineStart = markdown.lastIndexOf("\n", Math.max(0, start - 1)) + 1
  const lineEnd = markdown.indexOf("\n", start)
  const line = markdown.slice(lineStart, lineEnd === -1 ? markdown.length : lineEnd)
  const heading = line.match(/^\s{0,3}(#{1,4})\s+/)
  if (heading) return `heading_${heading[1].length}` as ToolbarBlockCommand
  if (/^\s{0,3}>\s?/.test(line)) return "blockquote"
  if (/^\s*```/.test(line)) return "fenced_code"
  return "paragraph"
}

function SelectionCommentAffordance({ disabled, selection, onOpenComposer }: {
  disabled: boolean
  selection: SelectionRange
  onOpenComposer: () => void
}) {
  if (disabled) return null

  return (
    <div
      className="absolute z-30"
      style={{
        left: selection.rect ? `${clampAffordanceLeft(selection.rect)}px` : "1rem",
        top: selection.rect ? `${Math.max(selection.rect.top - 44, 8)}px` : "1rem"
      }}
    >
      <Button
        aria-label="Comment on selection"
        className="h-9 w-9 rounded-full shadow-lg"
        onClick={onOpenComposer}
        onMouseDown={(event) => event.preventDefault()}
        size="icon"
        title="Comment on selection"
        variant="secondary"
      >
        <CommentIcon />
      </Button>
    </div>
  )
}

function ThreadPanel({ commentBody, commentPending, composerRef, doc, focusedSuggestionId, focusedThreadId, replyBodies, selection, suggestionRefs, threadRefs, onComment, onCommentChange, onFocus, onFocusSuggestion, onReply, onReplyChange, onResolve, onReview }: {
  commentBody: string
  commentPending: boolean
  composerRef: React.MutableRefObject<HTMLInputElement | null>
  doc: DesignDocDetail
  focusedSuggestionId: number | null
  focusedThreadId: number | null
  replyBodies: Record<number, string>
  selection: SelectionRange
  suggestionRefs: React.MutableRefObject<Record<number, HTMLDivElement | null>>
  threadRefs: React.MutableRefObject<Record<number, HTMLDivElement | null>>
  onComment: () => void
  onCommentChange: (body: string) => void
  onFocus: (threadId: number) => void
  onFocusSuggestion: (suggestionId: number) => void
  onReply: (threadId: number) => void
  onReplyChange: (threadId: number, body: string) => void
  onResolve: (threadId: number) => void
  onReview: (id: number, decision: "accept" | "reject") => void
}) {
  const hasSelection = selection.end > selection.start
  const activeSuggestions = doc.suggestions.filter((suggestion) => suggestion.state === "pending")
  const suggestionThreadIds = new Set(doc.suggestions.map((suggestion) => suggestion.thread?.id).filter((id): id is number => id != null))
  const activeCommentThreads = doc.threads.filter((thread) => thread.state === "open" && !suggestionThreadIds.has(thread.id))
  const activeCount = activeCommentThreads.length + activeSuggestions.length

  function submitCommentOnShortcut(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key !== "Enter" || (!event.metaKey && !event.ctrlKey)) return
    if (commentPending || commentBody.trim().length === 0) return

    event.preventDefault()
    onComment()
  }

  return (
    <Panel className="relative min-h-[36rem]">
      <SectionHeading as="h3">Threads</SectionHeading>
      <div className="relative mt-3 space-y-3">
        {hasSelection ? (
          <div className="rounded border border-brand/30 bg-brand/5 p-3 dark:border-brand/40 dark:bg-brand/10">
            <p className="text-xs font-medium text-text-secondary">New comment on selection</p>
            <p className="mt-2 line-clamp-3 rounded bg-surface p-2 text-xs text-text-secondary ring-1 ring-border">
              {selection.selectedText || selection.text}
            </p>
            <div className="mt-3 flex gap-2">
              <Input
                aria-label="New thread comment"
                onChange={(event) => onCommentChange(event.target.value)}
                onKeyDown={submitCommentOnShortcut}
                placeholder="Comment"
                ref={composerRef}
                value={commentBody}
              />
              <Button
                disabled={commentPending || commentBody.trim().length === 0}
                onClick={onComment}
                size="sm"
                variant="secondary"
              >
                Comment
              </Button>
            </div>
          </div>
        ) : null}
        {activeCount === 0 ? <p className="text-sm text-gray-500 dark:text-gray-400">No active threads.</p> : null}
        {activeCommentThreads.map((thread) => (
          <CommentThreadCard
            focused={focusedThreadId === thread.id}
            key={`thread-${thread.id}`}
            replyBody={replyBodies[thread.id] ?? ""}
            thread={thread}
            threadRefs={threadRefs}
            onFocus={onFocus}
            onReply={onReply}
            onReplyChange={onReplyChange}
            onResolve={onResolve}
          />
        ))}
        {activeSuggestions.map((suggestion) => (
          <SuggestionThreadCard
            canReview={doc.permissions.can_review_suggestions}
            focused={focusedSuggestionId === suggestion.id}
            key={`suggestion-${suggestion.id}`}
            replyBody={suggestion.thread ? replyBodies[suggestion.thread.id] ?? "" : ""}
            suggestion={suggestion}
            suggestionRefs={suggestionRefs}
            onFocus={onFocusSuggestion}
            onReply={onReply}
            onReplyChange={onReplyChange}
            onReview={onReview}
          />
        ))}
      </div>
    </Panel>
  )
}

function CommentThreadCard({ focused, replyBody, thread, threadRefs, onFocus, onReply, onReplyChange, onResolve }: {
  focused: boolean
  replyBody: string
  thread: DesignDocThread
  threadRefs: React.MutableRefObject<Record<number, HTMLDivElement | null>>
  onFocus: (threadId: number) => void
  onReply: (threadId: number) => void
  onReplyChange: (threadId: number, body: string) => void
  onResolve: (threadId: number) => void
}) {
  return (
    <div
      className={`rounded border p-3 transition ${focused ? "border-amber-400 bg-amber-50 dark:border-amber-500 dark:bg-amber-950/30" : "border-gray-200 dark:border-gray-700"}`}
      data-anchor-offset={thread.anchor.last_known_start_offset ?? thread.anchor.start_offset}
      onClick={() => onFocus(thread.id)}
      ref={(element) => { threadRefs.current[thread.id] = element }}
      style={{ marginTop: railOffset(thread) }}
    >
      <ThreadCardHeader labels={<><StatusLabel value="comment" />{thread.anchor.status !== "active" ? <StatusLabel value={thread.anchor.status} /> : null}</>} action={(
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
      )} />
      <p className="mt-2 rounded bg-gray-50 p-2 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{thread.anchor.selected_text || thread.anchor.selected_markdown || "Selection"}</p>
      <ThreadComments comments={thread.comments} />
      <ThreadReplyForm
        label={`Reply to thread ${thread.id}`}
        replyBody={replyBody}
        threadId={thread.id}
        onReply={onReply}
        onReplyChange={onReplyChange}
      />
    </div>
  )
}

function SuggestionThreadCard({ canReview, focused, replyBody, suggestion, suggestionRefs, onFocus, onReply, onReplyChange, onReview }: {
  canReview: boolean
  focused: boolean
  replyBody: string
  suggestion: DesignDocSuggestion
  suggestionRefs: React.MutableRefObject<Record<number, HTMLDivElement | null>>
  onFocus: (suggestionId: number) => void
  onReply: (threadId: number) => void
  onReplyChange: (threadId: number, body: string) => void
  onReview: (id: number, decision: "accept" | "reject") => void
}) {
  const thread = suggestion.thread

  return (
    <div
      className={`rounded border p-3 transition ${focused ? "border-amber-400 bg-amber-50 dark:border-amber-500 dark:bg-amber-950/30" : "border-gray-200 dark:border-gray-700"}`}
      data-anchor-offset={suggestion.anchor.last_known_start_offset ?? suggestion.anchor.start_offset}
      onClick={() => onFocus(suggestion.id)}
      ref={(element) => { suggestionRefs.current[suggestion.id] = element }}
      style={{ marginTop: railOffset(suggestion) }}
    >
      <ThreadCardHeader labels={<><StatusLabel value="suggestion" />{suggestion.anchor.status !== "active" ? <StatusLabel value={suggestion.anchor.status} /> : null}</>} action={<p className="text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={suggestion.created_at} /></p>} />
      <div className="mt-2 grid gap-2 text-xs">
        <del className="rounded bg-warning/10 p-2 text-warning">{suggestion.original_markdown}</del>
        <ins className="rounded bg-success/10 p-2 text-success no-underline">{suggestion.proposed_markdown}</ins>
      </div>
      {suggestion.change_summary ? <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{suggestion.change_summary}</p> : null}
      {thread ? <ThreadComments comments={thread.comments} /> : null}
      {thread ? (
        <ThreadReplyForm
          label={`Reply to suggestion ${suggestion.id}`}
          replyBody={replyBody}
          threadId={thread.id}
          onReply={onReply}
          onReplyChange={onReplyChange}
        />
      ) : null}
      {canReview ? (
        <div className="mt-3 flex gap-2">
          <Button
            onClick={(event) => {
              event.stopPropagation()
              onReview(suggestion.id, "accept")
            }}
            size="sm"
            variant="success"
          >
            Accept
          </Button>
          <Button
            onClick={(event) => {
              event.stopPropagation()
              onReview(suggestion.id, "reject")
            }}
            size="sm"
            variant="secondary"
          >
            Reject
          </Button>
        </div>
      ) : <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">Pending owner review.</p>}
    </div>
  )
}

function ThreadCardHeader({ action, labels }: { action: React.ReactNode; labels: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <div className="flex flex-wrap items-center gap-2">{labels}</div>
      {action}
    </div>
  )
}

function ThreadComments({ comments }: { comments: DesignDocThread["comments"] }) {
  if (comments.length === 0) return null

  return (
    <div className="mt-2 space-y-2 border-l-2 border-gray-200 pl-3 dark:border-gray-700">
      {comments.map((comment) => (
        <div className="text-sm text-gray-800 dark:text-gray-200" key={comment.id}>
          <p>{comment.body}</p>
          <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{comment.author?.name || comment.author_kind}</p>
        </div>
      ))}
    </div>
  )
}

function ThreadReplyForm({ label, replyBody, threadId, onReply, onReplyChange }: {
  label: string
  replyBody: string
  threadId: number
  onReply: (threadId: number) => void
  onReplyChange: (threadId: number, body: string) => void
}) {
  function submitReplyOnShortcut(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key !== "Enter" || (!event.metaKey && !event.ctrlKey)) return
    if (replyBody.trim().length === 0) return

    event.preventDefault()
    event.stopPropagation()
    onReply(threadId)
  }

  return (
    <div className="mt-3 flex gap-2">
      <Input
        aria-label={label}
        onClick={(event) => event.stopPropagation()}
        onChange={(event) => onReplyChange(threadId, event.target.value)}
        onKeyDown={submitReplyOnShortcut}
        placeholder="Reply"
        value={replyBody}
      />
      <Button
        disabled={replyBody.trim().length === 0}
        onClick={(event) => {
          event.stopPropagation()
          onReply(threadId)
        }}
        size="sm"
        variant="secondary"
      >
        Reply
      </Button>
    </div>
  )
}

function CommentIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z" />
    </svg>
  )
}

function clampAffordanceLeft(rect: SelectionRect) {
  const iconWidth = 36
  const inset = 8
  const maxLeft = Math.max(inset, rect.containerWidth - iconWidth - inset)
  return Math.min(Math.max(rect.left, inset), maxLeft)
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

function anchorPayload(selection: SelectionRange) {
  return {
    start_offset: selection.start,
    end_offset: selection.end,
    selected_markdown: selection.text,
    selected_text: selection.selectedText
  }
}

function markdownToWysiwygHtml(markdown: string, highlights: AnchorHighlight[] = [], focusedThreadId: number | null = null, focusedSuggestionId: number | null = null) {
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

    const fence = line.match(/^\s*```([\w.-]+)?\s*$/)
    if (fence) {
      const codeLines: string[] = []
      offset += line.length + 1
      index += 1
      while (index < lines.length && !lines[index].match(/^\s*```\s*$/)) {
        codeLines.push(lines[index])
        offset += lines[index].length + 1
        index += 1
      }
      if (index < lines.length) {
        offset += lines[index].length + 1
        index += 1
      }
      const languageAttr = fence[1] ? ` data-code-language="${escapeHtml(fence[1])}"` : ""
      blocks.push(`<pre${languageAttr}><code>${escapeHtml(codeLines.join("\n"))}</code></pre>`)
      continue
    }

    if (/^\s*(?:---+|\*\*\*+)\s*$/.test(line)) {
      blocks.push("<hr>")
      offset += line.length + 1
      index += 1
      continue
    }

    const heading = line.match(/^(#{1,4})\s+(.+)$/)
    if (heading) {
      const level = heading[1].length
      const headingOffset = offset + heading[1].length + 1
      blocks.push(`<h${level}>${renderWysiwygInline(heading[2], highlights, headingOffset, focusedThreadId, focusedSuggestionId)}</h${level}>`)
      offset += line.length + 1
      index += 1
      continue
    }

    if (/^\s*>\s?/.test(line)) {
      const quoteLines: string[] = []
      while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
        quoteLines.push(lines[index].replace(/^\s*>\s?/, ""))
        offset += lines[index].length + 1
        index += 1
      }
      blocks.push(`<blockquote>${markdownToWysiwygHtml(quoteLines.join("\n"), [], null, null)}</blockquote>`)
      continue
    }

    if (isWysiwygTableStart(lines, index)) {
      const table = renderWysiwygTable(lines, index, offset, highlights, focusedThreadId, focusedSuggestionId)
      blocks.push(table.html)
      index = table.nextIndex
      offset = table.nextOffset
      continue
    }

    if (wysiwygListMarker(line)) {
      const list = renderWysiwygList(lines, index, offset, highlights, focusedThreadId, focusedSuggestionId)
      blocks.push(list.html)
      index = list.nextIndex
      offset = list.nextOffset
      continue
    }

    const paragraph: string[] = []
    while (index < lines.length && lines[index].trim() !== "" && !startsWysiwygBlock(lines, index)) {
      const paragraphLine = lines[index]
      const leading = paragraphLine.length - paragraphLine.trimStart().length
      paragraph.push(renderWysiwygInline(paragraphLine.trim(), highlights, offset + leading, focusedThreadId, focusedSuggestionId))
      offset += paragraphLine.length + 1
      index += 1
    }
    blocks.push(`<p>${paragraph.join("<br>")}</p>`)
  }

  return blocks.join("")
}

function renderWysiwygInline(markdown: string, highlights: AnchorHighlight[] = [], baseOffset = 0, focusedThreadId: number | null = null, focusedSuggestionId: number | null = null) {
  return inlineTokens(markdown, baseOffset)
    .map((token) => {
      const content = renderHighlightedHtml(token.text, highlights, token.sourceStart, focusedThreadId, focusedSuggestionId)
      if (token.kind === "code") return `<code>${content}</code>`
      if (token.kind === "strong") return `<strong>${content}</strong>`
      if (token.kind === "emphasis") return `<em>${content}</em>`
      if (token.kind === "strike") return `<del>${content}</del>`
      if (token.kind === "link") {
        const href = safeWysiwygHref(token.href || "")
        return href ? `<a href="${escapeHtml(href)}">${content}</a>` : content
      }

      return content
    })
    .join("")
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

  if (node.tagName === "HR") return "---"
  if (node.tagName === "PRE") return fencedCodeMarkdown(node)
  if (node.tagName === "TABLE") return tableMarkdown(node)
  if (node.tagName === "UL") return listMarkdown(node, 0)
  if (node.tagName === "OL") return listMarkdown(node, 0)
  if (node.tagName === "BLOCKQUOTE") return blockquoteMarkdown(node)

  const text = inlineMarkdownText(node).trim()
  if (text.length === 0) return ""

  if (/^H[1-4]$/.test(node.tagName)) return `${"#".repeat(Number(node.tagName.slice(1)))} ${text}`
  if (node.tagName === "LI") return listItemMarkdown(node, "-", 0)

  return text
}

function inlineMarkdownText(node: ChildNode): string {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent ?? ""
  if (!(node instanceof HTMLElement)) return ""
  if (node.dataset.inlineSuggestionState) return node.querySelector("del")?.textContent ?? ""
  if (node.tagName === "BR") return "\n"
  if (node.tagName === "STRONG" || node.tagName === "B") return `**${inlineMarkdownChildren(node)}**`
  if (node.tagName === "EM" || node.tagName === "I") return `*${inlineMarkdownChildren(node)}*`
  if (node.tagName === "DEL" || node.tagName === "S") return `~~${inlineMarkdownChildren(node)}~~`
  if (node.tagName === "CODE" && node.parentElement?.tagName !== "PRE") return `\`${node.textContent ?? ""}\``
  if (node.tagName === "A") {
    const text = inlineMarkdownChildren(node)
    const href = safeWysiwygHref(node.getAttribute("href") ?? "")
    return href ? `[${text}](${href})` : text
  }
  if (node.childNodes.length === 0) return node.textContent ?? ""

  return inlineMarkdownChildren(node)
}

function inlineMarkdownChildren(node: HTMLElement) {
  return Array.from(node.childNodes).map((child) => inlineMarkdownText(child)).join("")
}

function fencedCodeMarkdown(node: HTMLElement) {
  const code = node.querySelector("code")?.textContent ?? node.textContent ?? ""
  const longestFence = code.match(/`{3,}/g)?.reduce((longest, fence) => Math.max(longest, fence.length), 2) ?? 2
  const fence = "`".repeat(longestFence + 1)
  const language = node.dataset.codeLanguage ?? ""
  return `${fence}${language}\n${code}\n${fence}`
}

function tableMarkdown(node: HTMLElement) {
  const headers = Array.from(node.querySelectorAll("thead th")).map((cell) => inlineMarkdownText(cell).trim())
  if (headers.length === 0) return inlineMarkdownText(node).trim()

  const rows = Array.from(node.querySelectorAll("tbody tr")).map((row) => {
    const cells = Array.from(row.querySelectorAll("td")).map((cell) => inlineMarkdownText(cell).trim())
    while (cells.length < headers.length) cells.push("")
    return cells.slice(0, headers.length)
  })

  return [
    tableRowMarkdown(headers),
    tableRowMarkdown(headers.map(() => "---")),
    ...rows.map((row) => tableRowMarkdown(row))
  ].join("\n")
}

function tableRowMarkdown(cells: string[]) {
  return `| ${cells.join(" | ")} |`
}

function listMarkdown(node: HTMLElement, depth: number): string {
  return Array.from(node.children)
    .filter((child): child is HTMLElement => child instanceof HTMLElement && child.tagName === "LI")
    .map((item, index) => {
      const marker = node.tagName === "OL" ? `${Number(item.getAttribute("value")) || index + 1}.` : "-"
      return listItemMarkdown(item, marker, depth)
    })
    .join("\n")
}

function listItemMarkdown(node: HTMLElement, marker: string, depth: number): string {
  const nestedLists: HTMLElement[] = []
  const inlineParts: string[] = []

  Array.from(node.childNodes).forEach((child) => {
    if (child instanceof HTMLElement && (child.tagName === "UL" || child.tagName === "OL")) {
      nestedLists.push(child)
      return
    }

    inlineParts.push(inlineMarkdownText(child))
  })

  const indent = "   ".repeat(depth)
  const firstLine = `${indent}${marker} ${inlineParts.join("").trim()}`
  const nested: string[] = nestedLists.map((list) => listMarkdown(list, depth + 1)).filter(Boolean)
  return [firstLine, ...nested].join("\n")
}

function blockquoteMarkdown(node: HTMLElement) {
  const markdown = Array.from(node.childNodes)
    .map((child) => nodeToMarkdown(child))
    .filter((block) => block.trim().length > 0)
    .join("\n\n")

  return markdown.split("\n").map((line) => `> ${line}`).join("\n")
}

function startsWysiwygBlock(lines: string[], index: number) {
  return (
    /^\s*```/.test(lines[index]) ||
    /^(#{1,4})\s+/.test(lines[index]) ||
    /^\s*>\s?/.test(lines[index]) ||
    /^\s*(?:---+|\*\*\*+)\s*$/.test(lines[index]) ||
    Boolean(wysiwygListMarker(lines[index])) ||
    isWysiwygTableStart(lines, index)
  )
}

function isWysiwygTableStart(lines: string[], index: number) {
  return index + 1 < lines.length && lines[index].includes("|") && /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(lines[index + 1])
}

function splitWysiwygTableRow(line: string) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim())
}

function splitWysiwygTableRowWithOffsets(line: string, rowOffset: number) {
  const cells = splitWysiwygTableRow(line)
  let searchFrom = 0

  return cells.map((cell) => {
    const sourceIndex = cell.length === 0 ? -1 : line.indexOf(cell, searchFrom)
    if (sourceIndex >= 0) searchFrom = sourceIndex + cell.length

    return {
      text: cell,
      sourceStart: rowOffset + (sourceIndex >= 0 ? sourceIndex : searchFrom)
    }
  })
}

function renderWysiwygTable(lines: string[], index: number, offset: number, highlights: AnchorHighlight[], focusedThreadId: number | null, focusedSuggestionId: number | null) {
  const headers = splitWysiwygTableRowWithOffsets(lines[index], offset)
  offset += lines[index].length + 1
  offset += lines[index + 1].length + 1
  index += 2

  const rows: Array<Array<{ text: string; sourceStart: number }>> = []
  while (index < lines.length && lines[index].includes("|") && lines[index].trim() !== "") {
    rows.push(splitWysiwygTableRowWithOffsets(lines[index], offset))
    offset += lines[index].length + 1
    index += 1
  }

  const headerHtml = headers
    .map((header) => `<th>${renderWysiwygInline(header.text, highlights, header.sourceStart, focusedThreadId, focusedSuggestionId)}</th>`)
    .join("")
  const bodyHtml = rows
    .map((row) => {
      const cells = headers.map((_header, cellIndex) => {
        const cell = row[cellIndex] || { text: "", sourceStart: offset }
        return `<td>${renderWysiwygInline(cell.text, highlights, cell.sourceStart, focusedThreadId, focusedSuggestionId)}</td>`
      })
      return `<tr>${cells.join("")}</tr>`
    })
    .join("")

  return {
    html: `<table><thead><tr>${headerHtml}</tr></thead><tbody>${bodyHtml}</tbody></table>`,
    nextIndex: index,
    nextOffset: offset
  }
}

function wysiwygListMarker(line: string) {
  const marker = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.+)$/)
  if (!marker) return null

  return {
    content: marker[3],
    indent: marker[1].replace(/\t/g, "    ").length,
    ordered: /^\d/.test(marker[2]),
    prefixLength: marker[1].length + marker[2].length + 1,
    value: /^\d/.test(marker[2]) ? Number.parseInt(marker[2], 10) : undefined
  }
}

function renderWysiwygList(lines: string[], index: number, offset: number, highlights: AnchorHighlight[], focusedThreadId: number | null, focusedSuggestionId: number | null) {
  const firstMarker = wysiwygListMarker(lines[index])
  if (!firstMarker) return { html: "", nextIndex: index, nextOffset: offset }

  const items: string[] = []
  const { indent, ordered } = firstMarker

  while (index < lines.length) {
    const marker = wysiwygListMarker(lines[index])
    if (!marker || marker.indent !== indent || marker.ordered !== ordered) break

    let itemHtml = renderWysiwygInline(marker.content, highlights, offset + marker.prefixLength, focusedThreadId, focusedSuggestionId)
    offset += lines[index].length + 1
    index += 1

    while (index < lines.length) {
      const nestedMarker = wysiwygListMarker(lines[index])
      if (!nestedMarker || nestedMarker.indent <= indent) break

      const nested = renderWysiwygList(lines, index, offset, highlights, focusedThreadId, focusedSuggestionId)
      itemHtml += nested.html
      index = nested.nextIndex
      offset = nested.nextOffset
    }

    items.push(`<li${ordered && marker.value ? ` value="${marker.value}"` : ""}>${itemHtml}</li>`)
  }

  return {
    html: ordered ? `<ol start="${firstMarker.value ?? 1}">${items.join("")}</ol>` : `<ul>${items.join("")}</ul>`,
    nextIndex: index,
    nextOffset: offset
  }
}

function escapeHtml(value: string) {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function safeWysiwygHref(href: string) {
  if (href.startsWith("/") || href.startsWith("#")) return href

  try {
    const url = new URL(href, window.location.origin)
    return ["http:", "https:", "mailto:"].includes(url.protocol) ? href : null
  } catch (_error) {
    return null
  }
}

function buildAnchorHighlights(doc: DesignDocDetail): AnchorHighlight[] {
  const suggestionThreadIds = new Set(doc.suggestions.map((suggestion) => suggestion.thread?.id).filter((id): id is number => id != null))
  const threadHighlights = doc.threads
    .filter((thread) => thread.state === "open" && thread.anchor.anchor_kind === "range" && !suggestionThreadIds.has(thread.id))
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
        suggestionId: suggestion.id,
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
  const segments: Array<{ text: string; start: number; end: number; highlight: AnchorHighlight | null }> = []
  let cursor = 0

  for (const highlight of highlights) {
    const start = Math.max(0, Math.min(text.length, highlight.start))
    const end = Math.max(start, Math.min(text.length, highlight.end))
    if (end <= cursor) continue
    if (start > cursor) segments.push({ text: text.slice(cursor, start), start: cursor, end: start, highlight: null })
    segments.push({ text: text.slice(Math.max(start, cursor), end), start: Math.max(start, cursor), end, highlight })
    cursor = end
  }

  if (cursor < text.length) segments.push({ text: text.slice(cursor), start: cursor, end: text.length, highlight: null })
  return segments
}

function inlineTokens(markdown: string, baseOffset: number): InlineToken[] {
  const tokens: InlineToken[] = []
  let index = 0

  while (index < markdown.length) {
    const strong = markdown.slice(index).match(/^\*\*([^*]+)\*\*/)
    if (strong) {
      tokens.push({ kind: "strong", text: strong[1], sourceStart: baseOffset + index + 2 })
      index += strong[0].length
      continue
    }

    const emphasis = markdown.slice(index).match(/^\*([^*]+)\*/)
    if (emphasis) {
      tokens.push({ kind: "emphasis", text: emphasis[1], sourceStart: baseOffset + index + 1 })
      index += emphasis[0].length
      continue
    }

    const strike = markdown.slice(index).match(/^~~([^~]+)~~/)
    if (strike) {
      tokens.push({ kind: "strike", text: strike[1], sourceStart: baseOffset + index + 2 })
      index += strike[0].length
      continue
    }

    const code = markdown.slice(index).match(/^`([^`]+)`/)
    if (code) {
      tokens.push({ kind: "code", text: code[1], sourceStart: baseOffset + index + 1 })
      index += code[0].length
      continue
    }

    const link = markdown.slice(index).match(/^\[([^\]]+)\]\(([^)]+)\)/)
    if (link) {
      tokens.push({ kind: "link", text: link[1], href: link[2], sourceStart: baseOffset + index + 1 })
      index += link[0].length
      continue
    }

    const nextSpecial = markdown.slice(index + 1).search(/(?:\*\*|\*|~~|`|\[)/)
    const end = nextSpecial === -1 ? markdown.length : index + 1 + nextSpecial
    tokens.push({ kind: "text", text: markdown.slice(index, end), sourceStart: baseOffset + index })
    index = end
  }

  return tokens
}

function sourceSpan(text: string, sourceStart: number) {
  return `<span data-source-start="${sourceStart}" data-source-end="${sourceStart + text.length}">${escapeHtml(text)}</span>`
}

function sourceOffsetForSelectionBoundary(root: HTMLElement, container: Node, offset: number, affinity: "start" | "end") {
  if (container.nodeType === Node.TEXT_NODE) {
    const sourceElement = sourceElementFor(container)
    if (!sourceElement) return null

    const sourceStart = Number(sourceElement.dataset.sourceStart)
    const sourceEnd = Number(sourceElement.dataset.sourceEnd)
    if (!Number.isFinite(sourceStart) || !Number.isFinite(sourceEnd)) return null

    return Math.max(sourceStart, Math.min(sourceEnd, sourceStart + offset))
  }

  if (!(container instanceof HTMLElement)) return null

  const children = Array.from(container.childNodes)
  if (affinity === "start") {
    const next = children.slice(offset).map((child) => sourceBoundsForNode(child)?.start).find((value) => value != null)
    if (next != null) return next

    const previous = children.slice(0, offset).reverse().map((child) => sourceBoundsForNode(child)?.end).find((value) => value != null)
    return previous ?? sourceBoundsForNode(root)?.start ?? null
  }

  const previous = children.slice(0, offset).reverse().map((child) => sourceBoundsForNode(child)?.end).find((value) => value != null)
  if (previous != null) return previous

  const next = children.slice(offset).map((child) => sourceBoundsForNode(child)?.start).find((value) => value != null)
  return next ?? sourceBoundsForNode(root)?.end ?? null
}

function sourceElementFor(node: Node) {
  const parent = node.parentElement
  return parent?.closest("[data-source-start][data-source-end]") as HTMLElement | null
}

function sourceBoundsForNode(node: Node): { start: number; end: number } | null {
  const element = node.nodeType === Node.TEXT_NODE ? sourceElementFor(node) : node instanceof HTMLElement ? node : null
  if (!element) return null

  const sourceElements = element.matches("[data-source-start][data-source-end]")
    ? [element]
    : Array.from(element.querySelectorAll("[data-source-start][data-source-end]")) as HTMLElement[]
  const starts = sourceElements.map((sourceElement) => Number(sourceElement.dataset.sourceStart)).filter(Number.isFinite)
  const ends = sourceElements.map((sourceElement) => Number(sourceElement.dataset.sourceEnd)).filter(Number.isFinite)
  if (starts.length === 0 || ends.length === 0) return null

  return { start: Math.min(...starts), end: Math.max(...ends) }
}

function renderHighlightedHtml(text: string, highlights: AnchorHighlight[], baseOffset: number, focusedThreadId: number | null, focusedSuggestionId: number | null) {
  return highlightTextSegments(text, highlights.map((highlight) => ({
    ...highlight,
    start: highlight.start - baseOffset,
    end: highlight.end - baseOffset
  })).filter((highlight) => highlight.end > 0 && highlight.start < text.length))
    .map((segment) => {
      const sourceText = sourceSpan(segment.text, baseOffset + segment.start)
      if (!segment.highlight) return sourceText

      const focused = segment.highlight.threadId === focusedThreadId || segment.highlight.suggestionId === focusedSuggestionId
      if (segment.highlight.kind === "suggestion") {
        const suggestionAttrs = segment.highlight.suggestionId ? ` data-suggestion-id="${segment.highlight.suggestionId}"` : ""
        const className = focused
          ? "rounded-sm bg-amber-300/70 px-0.5 ring-1 ring-amber-500 dark:bg-amber-500/50"
          : "rounded-sm bg-surface-raised px-0.5"
        return [
          `<mark class="${className}" data-anchor-highlight="${segment.highlight.id}" data-anchor-status="${escapeHtml(segment.highlight.status)}" data-inline-suggestion-state="${escapeHtml(segment.highlight.suggestionState || "")}"${suggestionAttrs}>`,
          `<del class="text-warning decoration-warning decoration-2">${sourceText}</del>`,
          `<ins class="ml-1 text-success no-underline">${escapeHtml(segment.highlight.proposedMarkdown || "")}</ins>`,
          "</mark>"
        ].join("")
      }

      const className = focused
        ? "rounded-sm bg-amber-300/70 px-0.5 ring-1 ring-amber-500 dark:bg-amber-500/50"
        : "rounded-sm bg-yellow-200/80 px-0.5 dark:bg-yellow-500/30"
      const threadAttrs = segment.highlight.threadId ? ` data-thread-id="${segment.highlight.threadId}"` : ""
      return `<mark class="${className}" data-anchor-highlight="${segment.highlight.id}" data-anchor-status="${escapeHtml(segment.highlight.status)}"${threadAttrs}>${sourceText}</mark>`
    })
    .join("")
}

function textareaSelectionRect(textarea: HTMLTextAreaElement, start: number, end: number): SelectionRect {
  const rect = textarea.getBoundingClientRect()
  const textBefore = textarea.value.slice(0, Math.max(start, end))
  const lines = textBefore.split("\n")
  const lineHeight = 24
  const charWidth = 8
  return {
    left: Math.min(rect.width - 32, 16 + lines.at(-1)!.length * charWidth),
    top: Math.min(rect.height - 80, 16 + (lines.length - 1) * lineHeight - textarea.scrollTop),
    containerWidth: rect.width
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
    top: rangeRect.bottom - containerRect.top,
    containerWidth: containerRect.width
  }
}

function railOffset(item: { anchor: DesignDocThread["anchor"] }) {
  const offset = item.anchor.last_known_start_offset ?? item.anchor.start_offset ?? 0
  return `${Math.min(Math.max(Math.floor(offset / 8), 0), 96)}px`
}
