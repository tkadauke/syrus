import { Fragment, useEffect, useMemo, useReducer, useRef, useState, type MouseEvent, type ReactNode } from "react"
import type { ThemedToken } from "@shikijs/core"
import { useVirtualizer, useWindowVirtualizer } from "@tanstack/react-virtual"
import { Button } from "../Button"
import { CloseIcon } from "../CloseIcon"
import { renderCodeLine } from "../CodeBlock"
import { detectHighlighterLanguage, tokenizeLines, type HighlighterLanguageId } from "../../lib/highlighter"
import { endMarker, measureSync, recordCount, startMarker, type PerformanceMarkerHandle } from "../../lib/performanceMarkers"
import {
  CONTEXT_EXPAND_LINE_INCREMENT,
  DEFAULT_FILE_HEADER_HEIGHT_PX,
  DEFAULT_FILE_PLACEHOLDER_HEIGHT_PX,
  DEFAULT_FILE_ROW_HEIGHT_PX,
  DEFAULT_FILE_UNAVAILABLE_HEIGHT_PX,
  DEFAULT_FILE_VIRTUALIZATION_OVERSCAN,
  DEFAULT_LARGE_FILE_ROW_THRESHOLD,
  DEFAULT_MAX_VISIBLE_FILES,
  contextGapsForHunks,
  countDiffRows,
  diffCoverageBorderClass,
  diffGutterClass,
  diffLineClass,
  diffMarkerClass,
  fullyRevealedGapStates,
  gapSize as contextGapSize,
  hunksFromLines,
  mergeContextIntoLines,
  parseUnifiedDiff,
  remainingInGap,
  splitLines,
  tokenizeCode,
  type ContextGap,
  type DiffLine,
  type DiffLineKind,
  type GapRevealState,
  type LineAnnotation
} from "./diffRendering"

export type ReviewableDiffFile = {
  path: string
  patch: string | null
  status?: string
  additions?: number
  deletions?: number
}

export type DiffLineSelection = {
  file: ReviewableDiffFile
  line: DiffLine
  side: "old" | "new"
}

export type DiffReviewThread = {
  id: number
  body: string
  state: string
  author?: string | null
  workflowState?: string | null
}

export type ReviewableDiffProps = {
  annotations?: Record<string, Record<string, LineAnnotation>> | Record<string, LineAnnotation> | null
  changedFilesPopup?: boolean
  comments?: Record<string, Record<string, DiffReviewThread[]>> | null
  composingBody?: string
  composingError?: Error | null
  composingPending?: boolean
  composingSelection?: DiffLineSelection | null
  editingThreadBody?: string
  editingThreadId?: number | null
  emptyState?: ReactNode
  fileCommentCounts?: Record<string, number>
  files?: ReviewableDiffFile[]
  // Per-file gate: files whose rendered diff row count exceeds this are hidden
  // behind a placeholder until explicitly loaded. Named/configurable rather
  // than hardcoded so call sites can tune it without touching the component.
  largeFileRowThreshold?: number
  // Cap on how many files render up front; a "load more" control reveals the rest.
  maxVisibleFiles?: number
  mode?: "single-file" | "continuous"
  onCancelComposing?: () => void
  onCancelEditThread?: () => void
  onChangeComposingBody?: (body: string) => void
  onChangeEditingThreadBody?: (body: string) => void
  onCommentLine?: (selection: DiffLineSelection) => void
  onDeleteThread?: (thread: DiffReviewThread) => void
  // Fetches the full current file text (at the diff's head ref) so hidden
  // hunk context and "load whole file" can reveal real content. Omit to
  // hide context-expansion affordances entirely (e.g. a standalone patch
  // view with no backing ref to fetch from).
  onLoadFileContext?: (file: ReviewableDiffFile) => Promise<string | null>
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onSelectFile?: (path: string) => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  scroll?: "bounded" | "natural"
  selectedPath?: string | null
  showFileHeaders?: boolean | "continuous"
  unavailableState?: ReactNode
  wordHighlighting?: boolean
}

export type ReviewableUnifiedDiffProps = Omit<ReviewableDiffProps, "files"> & {
  diff: string
}

type FilesPopupPlacement = {
  bottom?: number
  left: number
  maxHeight: number
  openAbove: boolean
  top?: number
  width: number
}

const FILES_POPUP_MARGIN = 8
const FILES_POPUP_MIN_HEIGHT = 200

// Per-file state that must survive a file section unmounting and remounting
// as the user scrolls it out of, then back into, the virtualized window --
// otherwise expanded hidden-context and fetched Shiki tokens would silently
// redo their work (or reset visually) every time a file leaves the overscan
// range. Held in a Map on the parent ReviewableDiff (keyed by file path, not
// component state), so the entry itself survives across DiffFileSection
// mount/unmount cycles; only the whole diff changing (see `fileCache.current
// = new Map()` below) clears it.
type FileCacheEntry = {
  contextState: FileContextState
  forceLoaded: boolean
  tokensByHunk: Map<number, ThemedToken[][]>
}

function createFileCacheEntry(): FileCacheEntry {
  return { contextState: { fullyExpanded: false, gaps: [], lines: null, status: "idle" }, forceLoaded: false, tokensByHunk: new Map() }
}

// Mutates the shared cache entry in place and forces a re-render, rather
// than mirroring it into component state -- so the entry (and thus its
// contents) has one persistent identity per file path regardless of how
// many times its DiffFileSection mounts and unmounts.
function useFileCacheEntry(cache: Map<string, FileCacheEntry>, path: string): [FileCacheEntry, (patch: Partial<FileCacheEntry>) => void] {
  if (!cache.has(path)) cache.set(path, createFileCacheEntry())
  const entry = cache.get(path)!
  const [, forceUpdate] = useReducer((count: number) => count + 1, 0)
  function update(patch: Partial<FileCacheEntry>) {
    Object.assign(entry, patch)
    forceUpdate()
  }
  return [entry, update]
}

// A pixel estimate used only until a file section actually mounts and
// reports its real height (see `virtualizer.measureElement`). Close enough
// that ordinary scrolling doesn't jump once the real measurement lands.
function estimateFileSectionHeight(file: ReviewableDiffFile, { forceLoaded, largeFileRowThreshold, showHeader }: { forceLoaded: boolean; largeFileRowThreshold: number; showHeader: boolean }): number {
  const header = showHeader ? DEFAULT_FILE_HEADER_HEIGHT_PX : 0
  if (file.patch === null) return header + DEFAULT_FILE_UNAVAILABLE_HEIGHT_PX
  const rowCount = countDiffRows(file.patch)
  if (rowCount > largeFileRowThreshold && !forceLoaded) return header + DEFAULT_FILE_PLACEHOLDER_HEIGHT_PX
  return header + rowCount * DEFAULT_FILE_ROW_HEIGHT_PX
}

export function ReviewableDiff({
  annotations,
  changedFilesPopup = false,
  comments,
  composingBody,
  composingError,
  composingPending,
  composingSelection,
  editingThreadBody,
  editingThreadId,
  emptyState = null,
  fileCommentCounts,
  files = [],
  largeFileRowThreshold = DEFAULT_LARGE_FILE_ROW_THRESHOLD,
  maxVisibleFiles = DEFAULT_MAX_VISIBLE_FILES,
  mode = "single-file",
  onCancelComposing,
  onCancelEditThread,
  onChangeComposingBody,
  onChangeEditingThreadBody,
  onCommentLine,
  onDeleteThread,
  onLoadFileContext,
  onSaveComposing,
  onSaveEditThread,
  onSelectFile,
  onStartEditThread,
  scroll = "bounded",
  selectedPath,
  showFileHeaders = "continuous",
  unavailableState = "Diff not available",
  wordHighlighting = true
}: ReviewableDiffProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const scrollContainerRef = useRef<HTMLDivElement>(null)
  const [filesPopupOpen, setFilesPopupOpen] = useState(false)
  const [filesPopupPlacement, setFilesPopupPlacement] = useState<FilesPopupPlacement | null>(null)
  // Started when the Files menu opens, ended once its popup has actually
  // been positioned and rendered -- open-to-render latency, not just the
  // click handler's own (near-zero) synchronous cost.
  const filesMenuMarkerRef = useRef<PerformanceMarkerHandle | null>(null)
  const [highlightedToken, setHighlightedToken] = useState<string | null>(null)
  const isMobileFilesMenu = useIsMobileViewport()
  // Per-file cache (parsed context state, fetched Shiki tokens) keyed by file
  // path -- survives a file section unmounting when it scrolls out of the
  // virtualized window. Reset below whenever the diff itself changes.
  const fileCache = useRef(new Map<string, FileCacheEntry>())

  const renderFiles = filesForMode(files, mode, selectedPath)
  const filesSignature = renderFiles.map((file) => file.path).join("\n")

  // Reset the "how many files are revealed" cap (and the per-file cache)
  // whenever the underlying file list actually changes (not on every
  // re-render, since query refetches can hand back a fresh array reference
  // for the same data).
  const [visibleState, setVisibleState] = useState(() => ({ count: Math.min(renderFiles.length, maxVisibleFiles), signature: filesSignature }))
  let visibleFileCount = visibleState.count
  if (visibleState.signature !== filesSignature) {
    visibleFileCount = Math.min(renderFiles.length, maxVisibleFiles)
    setVisibleState({ count: visibleFileCount, signature: filesSignature })
    fileCache.current = new Map()
  }

  const containerClass = scroll === "natural"
    ? "bg-white font-mono text-xs dark:bg-gray-950"
    : "max-h-[32rem] overflow-y-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950"

  const visibleFiles = renderFiles.slice(0, visibleFileCount)
  const remainingFileCount = renderFiles.length - visibleFiles.length
  const showHeader = showFileHeaders === true || (showFileHeaders === "continuous" && mode === "continuous")

  // Distance from the top of the document to the top of the scroll
  // container, needed to convert `useWindowVirtualizer`'s document-relative
  // offsets back into container-relative ones. Irrelevant (and left at 0)
  // for bounded/element scrolling, where the container itself is the
  // scrollport.
  const scrollMargin = scroll === "natural" ? (scrollContainerRef.current?.offsetTop ?? 0) : 0

  function estimateSize(index: number) {
    const file = visibleFiles[index]
    if (!file) return DEFAULT_FILE_HEADER_HEIGHT_PX
    return estimateFileSectionHeight(file, { forceLoaded: fileCache.current.get(file.path)?.forceLoaded ?? false, largeFileRowThreshold, showHeader })
  }

  function getItemKey(index: number) {
    return visibleFiles[index]?.path ?? index
  }

  // Both variants are constructed unconditionally (hooks can't be called
  // conditionally); only the one matching `scroll` is actually used below.
  // `scroll` is a per-call-site constant in practice, so the unused instance
  // costs a bit of idle bookkeeping, never a real second scrollport.
  // `enabled: false` keeps the inactive instance from touching its scroll
  // element at all (no listeners, no initial-offset sync) -- without it, the
  // unused window virtualizer would still call `window.scrollTo()` on mount
  // even for a "bounded" container diff, since `window` is always available.
  const windowVirtualizer = useWindowVirtualizer({ count: visibleFiles.length, enabled: scroll === "natural", estimateSize, getItemKey, overscan: DEFAULT_FILE_VIRTUALIZATION_OVERSCAN, scrollMargin })
  const elementVirtualizer = useVirtualizer({ count: visibleFiles.length, enabled: scroll === "bounded", estimateSize, getItemKey, getScrollElement: () => scrollContainerRef.current, overscan: DEFAULT_FILE_VIRTUALIZATION_OVERSCAN })
  const virtualizer = scroll === "natural" ? windowVirtualizer : elementVirtualizer

  // Navigates the virtualized list to `selectedPath` whenever it changes
  // (Files menu selection, a header click round-tripping back through
  // `onSelectFile`, or a sidebar comment's "View in diff") -- unlike the old
  // `data-diff-file` DOM query, this works even when the target file isn't
  // currently mounted. `pendingScrollTarget` survives across the render
  // where a beyond-the-cap file first gets included in `visibleFiles`, so
  // the scroll happens once the file is actually part of the virtualized
  // range instead of being silently dropped.
  const pendingScrollTarget = useRef<string | null>(null)
  useEffect(() => {
    if (selectedPath) pendingScrollTarget.current = selectedPath
  }, [selectedPath])
  useEffect(() => {
    const target = pendingScrollTarget.current
    if (!target) return
    const index = renderFiles.findIndex((file) => file.path === target)
    if (index === -1) return
    if (index >= visibleFileCount) {
      setVisibleState({ count: index + 1, signature: filesSignature })
      return
    }
    pendingScrollTarget.current = null
    measureSync("diff_review.anchor_scroll", () => virtualizer.scrollToIndex(index, { align: "start" }), {
      maxPerSession: 200,
      metadata: { selected_path: target, virtualization_mode: scroll }
    })
  })

  const virtualItems = virtualizer.getVirtualItems()

  // Throttled by the effect's own dependency array, not a timer: this only
  // fires when the *count* of virtualized (mounted) files actually changes
  // -- initial mount, "load more files", or files scrolling in/out of the
  // overscan range -- not on every scroll-position pixel.
  useEffect(() => {
    const mountedFiles = virtualItems.map((item) => visibleFiles[item.index]).filter((file): file is ReviewableDiffFile => Boolean(file))
    const mountedRows = mountedFiles.reduce((sum, file) => sum + (file.patch ? countDiffRows(file.patch) : 0), 0)
    recordCount("diff_review.viewport_render", {
      maxPerSession: 300,
      metadata: {
        mounted_files: virtualItems.length,
        mounted_rows: mountedRows,
        total_files: visibleFiles.length,
        virtualization_mode: scroll
      }
    })
  }, [virtualItems.length, visibleFiles.length, scroll])

  useEffect(() => {
    if (!comments) return
    const threadCount = Object.values(comments).reduce(
      (sum, byAnchor) => sum + Object.values(byAnchor).reduce((innerSum, threads) => innerSum + threads.length, 0),
      0
    )
    if (threadCount === 0) return
    recordCount("diff_review.comment_threads_render", {
      maxPerSession: 200,
      metadata: { comment_composer_active: Boolean(composingSelection), thread_count: threadCount }
    })
  }, [comments, composingSelection])

  useEffect(() => {
    const marker = filesMenuMarkerRef.current
    if (!filesPopupOpen || !filesPopupPlacement || !marker) return
    endMarker(marker, { metadata: { total_files: files.length } })
    filesMenuMarkerRef.current = null
  }, [filesPopupOpen, filesPopupPlacement, files.length])

  if (renderFiles.length === 0) return <>{emptyState}</>

  function toggleFilesPopup(event: MouseEvent<HTMLButtonElement>) {
    const buttonRect = event.currentTarget.getBoundingClientRect()
    const containerRect = containerRef.current?.getBoundingClientRect() ?? buttonRect
    setFilesPopupPlacement(computeFilesPopupPlacement(buttonRect, containerRect))
    setFilesPopupOpen((open) => {
      const next = !open
      if (next) filesMenuMarkerRef.current = startMarker("diff_review.files_menu_open", { maxPerSession: 200 })
      return next
    })
  }

  function selectFileFromPopup(path: string) {
    onSelectFile?.(path)
    setFilesPopupOpen(false)
  }

  function toggleHighlightToken(token: string) {
    setHighlightedToken((current) => (current === token ? null : token))
  }

  return (
    <div className="relative" data-testid="agent-diff-viewer" ref={containerRef}>
      {wordHighlighting && highlightedToken ? (
        <div className="sticky top-0 z-20 flex items-center justify-between gap-3 border-b border-amber-200 bg-amber-50 px-4 py-1.5 font-sans text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950/60 dark:text-amber-200">
          <span>Highlighting <code className="font-mono">{highlightedToken}</code></span>
          <button className="font-medium underline hover:no-underline" onClick={() => setHighlightedToken(null)} type="button">Clear highlight</button>
        </div>
      ) : null}
      <div className={containerClass} data-rendered-file-count={virtualItems.length} data-total-file-count={visibleFiles.length} ref={scrollContainerRef}>
        <div style={{ height: virtualizer.getTotalSize(), position: "relative", width: "100%" }}>
          {virtualItems.map((virtualItem) => {
            const file = visibleFiles[virtualItem.index]
            if (!file) return null
            return (
              <div
                data-index={virtualItem.index}
                key={virtualItem.key}
                ref={virtualizer.measureElement}
                style={{ left: 0, position: "absolute", top: 0, transform: `translateY(${virtualItem.start - scrollMargin}px)`, width: "100%" }}
              >
                <section className={virtualItem.index > 0 ? "border-t border-gray-200 dark:border-gray-800" : ""} data-diff-file={file.path}>
                  <DiffFileSection
                    annotations={annotationsForFile(annotations, file.path)}
                    cache={fileCache.current}
                    comments={comments?.[file.path]}
                    composingBody={composingBody}
                    composingError={composingError}
                    composingPending={composingPending}
                    composingSelection={composingSelection?.file.path === file.path ? composingSelection : undefined}
                    editingThreadBody={editingThreadBody}
                    editingThreadId={editingThreadId}
                    file={file}
                    highlightedToken={wordHighlighting ? highlightedToken : null}
                    largeFileRowThreshold={largeFileRowThreshold}
                    onCancelComposing={onCancelComposing}
                    onCancelEditThread={onCancelEditThread}
                    onChangeComposingBody={onChangeComposingBody}
                    onChangeEditingThreadBody={onChangeEditingThreadBody}
                    onCommentLine={onCommentLine}
                    onDeleteThread={onDeleteThread}
                    onLoadFileContext={onLoadFileContext}
                    onSaveComposing={onSaveComposing}
                    onSaveEditThread={onSaveEditThread}
                    onSelectFile={onSelectFile}
                    onStartEditThread={onStartEditThread}
                    onToggleFilesPopup={changedFilesPopup ? toggleFilesPopup : undefined}
                    onToggleHighlightToken={wordHighlighting ? toggleHighlightToken : undefined}
                    selected={selectedPath === file.path}
                    showFilesPopupTrigger={changedFilesPopup}
                    showHeader={showHeader}
                    unavailableState={unavailableState}
                  />
                </section>
              </div>
            )
          })}
        </div>
        {remainingFileCount > 0 ? (
          <div className="border-t border-gray-200 px-4 py-3 text-center font-sans dark:border-gray-800">
            <Button
              onClick={() => setVisibleState({ count: Math.min(renderFiles.length, visibleFileCount + maxVisibleFiles), signature: filesSignature })}
              size="sm"
              variant="secondary"
            >
              Load {Math.min(maxVisibleFiles, remainingFileCount)} more files ({remainingFileCount} remaining)
            </Button>
          </div>
        ) : null}
      </div>
      {changedFilesPopup && filesPopupOpen ? (
        isMobileFilesMenu ? (
          <MobileChangedFilesModal
            commentCounts={fileCommentCounts}
            files={files}
            onClose={() => setFilesPopupOpen(false)}
            onSelectFile={selectFileFromPopup}
            selectedPath={selectedPath}
          />
        ) : (
          <ChangedFilesPopup
            commentCounts={fileCommentCounts}
            files={files}
            onClose={() => setFilesPopupOpen(false)}
            onSelectFile={selectFileFromPopup}
            placement={filesPopupPlacement}
            selectedPath={selectedPath}
          />
        )
      ) : null}
    </div>
  )
}

export function AgentDiff({ annotations, diff, ...props }: ReviewableUnifiedDiffProps & { annotations?: Record<string, LineAnnotation> }) {
  return <ReviewableDiff annotations={annotations} files={filesFromUnifiedDiff(diff)} mode="continuous" {...props} />
}

function useIsMobileViewport() {
  const query = "(max-width: 767px)"
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return false
    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const update = () => setMatches(media.matches)
    update()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", update)
      return () => media.removeEventListener("change", update)
    }

    media.addListener(update)
    return () => media.removeListener(update)
  }, [])

  return matches
}

function computeFilesPopupPlacement(buttonRect: DOMRect, containerRect: DOMRect): FilesPopupPlacement {
  const viewportHeight = typeof window === "undefined" ? 768 : window.innerHeight
  const spaceBelow = Math.max(0, viewportHeight - buttonRect.bottom - FILES_POPUP_MARGIN)
  const spaceAbove = Math.max(0, buttonRect.top - FILES_POPUP_MARGIN)
  const openAbove = spaceBelow < FILES_POPUP_MIN_HEIGHT && spaceAbove > spaceBelow

  return {
    bottom: openAbove ? viewportHeight - buttonRect.top + FILES_POPUP_MARGIN : undefined,
    left: containerRect.left,
    maxHeight: Math.max(FILES_POPUP_MIN_HEIGHT, openAbove ? spaceAbove : spaceBelow),
    openAbove,
    top: openAbove ? undefined : buttonRect.bottom + FILES_POPUP_MARGIN,
    width: containerRect.width
  }
}

function ChangedFilesPopup({
  commentCounts,
  files,
  onClose,
  onSelectFile,
  placement,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  files: ReviewableDiffFile[]
  onClose: () => void
  onSelectFile: (path: string) => void
  placement: FilesPopupPlacement | null
  selectedPath?: string | null
}) {
  return (
    <div className="fixed inset-0 z-30" onClick={onClose}>
      <div
        className="fixed z-30 flex flex-col overflow-hidden rounded border border-gray-200 bg-white font-mono text-xs shadow-lg dark:border-gray-700 dark:bg-gray-900"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
        style={placement ? {
          bottom: placement.bottom,
          left: placement.left,
          maxHeight: placement.maxHeight,
          top: placement.top,
          width: placement.width
        } : { left: 16, maxHeight: 480, top: 56, width: 320 }}
      >
        <p className="shrink-0 border-b border-gray-100 px-3 py-2 font-sans text-xs font-semibold uppercase tracking-wide text-gray-500 dark:border-gray-800 dark:text-gray-400">Changed files</p>
        <div className="min-h-0 flex-1 overflow-auto">
          <ChangedFilesList commentCounts={commentCounts} files={files} onSelectFile={onSelectFile} selectedPath={selectedPath} />
        </div>
      </div>
    </div>
  )
}

function MobileChangedFilesModal({
  commentCounts,
  files,
  onClose,
  onSelectFile,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  files: ReviewableDiffFile[]
  onClose: () => void
  onSelectFile: (path: string) => void
  selectedPath?: string | null
}) {
  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-white font-mono text-xs dark:bg-gray-950" role="dialog">
      <div className="flex shrink-0 items-center justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
        <p className="font-sans text-sm font-semibold text-gray-700 dark:text-gray-200">Changed files</p>
        <button aria-label="Close changed files" className="rounded p-2 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
          <CloseIcon className="h-5 w-5" />
        </button>
      </div>
      <div className="flex-1 overflow-auto">
        <ChangedFilesList commentCounts={commentCounts} files={files} onSelectFile={onSelectFile} selectedPath={selectedPath} />
      </div>
    </div>
  )
}

function ChangedFilesList({
  commentCounts,
  files,
  onSelectFile,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  files: ReviewableDiffFile[]
  onSelectFile: (path: string) => void
  selectedPath?: string | null
}) {
  return (
    <>
      {files.map((file) => (
        <button
          className={`flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-brand/10 ${selectedPath === file.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
          key={file.path}
          onClick={() => onSelectFile(file.path)}
          title={`${file.path} (+${file.additions ?? 0} -${file.deletions ?? 0})`}
          type="button"
        >
          <span className="min-w-0 flex-1 truncate">{file.path}</span>
          {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions}</span> : null}
          {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions}</span> : null}
          {commentCounts?.[file.path] ? <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">{commentCounts[file.path]}</span> : null}
        </button>
      ))}
    </>
  )
}

type HunkContextControl = { loading: boolean; onClick: () => void }
type HunkControls = { down?: HunkContextControl; up?: HunkContextControl }
type FileContextState = {
  fullyExpanded: boolean
  gaps: Array<GapRevealState | undefined>
  lines: string[] | null
  status: "idle" | "loading" | "loaded" | "error"
}

// One changed file's header + gating + hidden-context state. Split out of
// ReviewableDiff so each file's async context-loading/expansion state is
// naturally scoped and reset (via the `key={file.path}` on the parent's
// list) whenever the underlying file actually changes.
function DiffFileSection({
  annotations,
  cache,
  comments,
  composingBody,
  composingError,
  composingPending,
  composingSelection,
  editingThreadBody,
  editingThreadId,
  file,
  highlightedToken,
  largeFileRowThreshold,
  onCancelComposing,
  onCancelEditThread,
  onChangeComposingBody,
  onChangeEditingThreadBody,
  onCommentLine,
  onDeleteThread,
  onLoadFileContext,
  onSaveComposing,
  onSaveEditThread,
  onSelectFile,
  onStartEditThread,
  onToggleFilesPopup,
  onToggleHighlightToken,
  selected,
  showFilesPopupTrigger,
  showHeader,
  unavailableState
}: {
  annotations?: Record<string, LineAnnotation>
  cache: Map<string, FileCacheEntry>
  comments?: Record<string, DiffReviewThread[]>
  composingBody?: string
  composingError?: Error | null
  composingPending?: boolean
  composingSelection?: DiffLineSelection | null
  editingThreadBody?: string
  editingThreadId?: number | null
  file: ReviewableDiffFile
  highlightedToken?: string | null
  largeFileRowThreshold: number
  onCancelComposing?: () => void
  onCancelEditThread?: () => void
  onChangeComposingBody?: (body: string) => void
  onChangeEditingThreadBody?: (body: string) => void
  onCommentLine?: (selection: DiffLineSelection) => void
  onDeleteThread?: (thread: DiffReviewThread) => void
  onLoadFileContext?: (file: ReviewableDiffFile) => Promise<string | null>
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onSelectFile?: (path: string) => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  onToggleFilesPopup?: (event: MouseEvent<HTMLButtonElement>) => void
  onToggleHighlightToken?: (token: string) => void
  selected: boolean
  showFilesPopupTrigger?: boolean
  showHeader: boolean
  unavailableState: ReactNode
}) {
  const lines = useMemo(() => {
    const marker = startMarker("diff_review.parse_diff", { maxPerSession: 300, thresholdMs: 1 })
    const parsed = parseUnifiedDiff(file.patch || "")
    endMarker(marker, { metadata: { path: file.path, rows: parsed.length } })
    return parsed
  }, [file.patch])
  const hunks = useMemo(() => hunksFromLines(lines), [lines])
  const rowCount = lines.length
  const [cacheEntry, updateCacheEntry] = useFileCacheEntry(cache, file.path)
  const forceLoaded = cacheEntry.forceLoaded
  const contextState = cacheEntry.contextState
  function setForceLoaded(value: boolean) {
    updateCacheEntry({ forceLoaded: value })
  }
  function setContextState(updater: (prev: FileContextState) => FileContextState) {
    updateCacheEntry({ contextState: updater(cacheEntry.contextState) })
  }

  const gapsMeta = useMemo<ContextGap[]>(() => contextGapsForHunks(hunks, contextState.lines?.length ?? null), [hunks, contextState.lines])

  const mergedLines = useMemo(() => {
    if (!contextState.lines) return lines
    const states = contextState.fullyExpanded ? fullyRevealedGapStates(gapsMeta) : contextState.gaps
    return mergeContextIntoLines(lines, gapsMeta, states, contextState.lines)
  }, [lines, gapsMeta, contextState.gaps, contextState.lines, contextState.fullyExpanded])

  async function ensureFileLinesLoaded(): Promise<string[] | null> {
    if (contextState.lines) return contextState.lines
    if (!onLoadFileContext || contextState.status === "loading") return null

    setContextState((prev) => ({ ...prev, status: "loading" }))
    let fetchedLines: string[] | null = null
    try {
      const content = await onLoadFileContext(file)
      fetchedLines = content != null ? splitLines(content) : null
    } catch {
      fetchedLines = null
    }
    setContextState((prev) => ({ ...prev, lines: fetchedLines, status: fetchedLines ? "loaded" : "error" }))
    return fetchedLines
  }

  async function expandGap(gapIndex: number, edge: "fromBottom" | "fromTop") {
    const fileLines = await ensureFileLinesLoaded()
    if (!fileLines) return

    const gaps = contextGapsForHunks(hunks, fileLines.length)
    const gap = gaps[gapIndex]
    if (!gap) return
    const size = contextGapSize(gap)

    setContextState((prev) => {
      const existing = prev.gaps[gapIndex] || { fromBottom: 0, fromTop: 0 }
      const other = edge === "fromTop" ? existing.fromBottom : existing.fromTop
      const current = edge === "fromTop" ? existing.fromTop : existing.fromBottom
      const next = Math.min(size - other, current + CONTEXT_EXPAND_LINE_INCREMENT)
      const nextGaps = [...prev.gaps]
      nextGaps[gapIndex] = { ...existing, [edge]: Math.max(current, next) }
      return { ...prev, gaps: nextGaps }
    })
  }

  async function loadWholeFile() {
    const fileLines = await ensureFileLinesLoaded()
    if (!fileLines) return
    setContextState((prev) => ({ ...prev, fullyExpanded: true }))
  }

  // Removed files have no content at the diff's head ref to fetch context
  // from (the file is gone there), so `onLoadFileContext` would only ever
  // resolve null — never show controls that can't do anything.
  const contextExpansionEnabled = Boolean(onLoadFileContext) && file.status !== "removed"

  const hunkControls: HunkControls[] = contextExpansionEnabled ? hunks.map((_, hunkIndex) => {
    const upGap = gapsMeta[hunkIndex]
    const downGap = gapsMeta[hunkIndex + 1]
    const loading = contextState.status === "loading"
    const upVisible = !contextState.fullyExpanded && remainingInGap(upGap, contextState.gaps[hunkIndex]) > 0
    const downVisible = !contextState.fullyExpanded && remainingInGap(downGap, contextState.gaps[hunkIndex + 1]) > 0

    return {
      down: downVisible ? { loading, onClick: () => expandGap(hunkIndex + 1, "fromTop") } : undefined,
      up: upVisible ? { loading, onClick: () => expandGap(hunkIndex, "fromBottom") } : undefined
    }
  }) : []

  if (rowCount > largeFileRowThreshold && !forceLoaded) {
    return (
      <>
        {showHeader ? (
          <DiffFileHeader
            file={file}
            onSelectFile={onSelectFile}
            onToggleFilesPopup={onToggleFilesPopup}
            selected={selected}
            showFilesPopupTrigger={showFilesPopupTrigger}
          />
        ) : null}
        <LargeFilePlaceholder file={file} onLoad={() => setForceLoaded(true)} rowCount={rowCount} />
      </>
    )
  }

  const loadWholeFileState = contextExpansionEnabled ? (contextState.fullyExpanded ? "loaded" : contextState.status === "loading" ? "loading" : "idle") : null

  return (
    <>
      {showHeader ? (
        <DiffFileHeader
          file={file}
          loadWholeFileState={loadWholeFileState}
          onLoadWholeFile={contextExpansionEnabled ? loadWholeFile : undefined}
          onSelectFile={onSelectFile}
          onToggleFilesPopup={onToggleFilesPopup}
          selected={selected}
          showFilesPopupTrigger={showFilesPopupTrigger}
        />
      ) : null}
      {file.patch !== null ? (
        <UnifiedDiffTable
          annotations={annotations}
          comments={comments}
          composingBody={composingBody}
          composingError={composingError}
          composingPending={composingPending}
          composingSelection={composingSelection}
          editingThreadBody={editingThreadBody}
          editingThreadId={editingThreadId}
          file={file}
          highlightedToken={highlightedToken}
          hunkControls={hunkControls}
          lines={mergedLines}
          onCancelComposing={onCancelComposing}
          onCancelEditThread={onCancelEditThread}
          onChangeComposingBody={onChangeComposingBody}
          onChangeEditingThreadBody={onChangeEditingThreadBody}
          onCommentLine={onCommentLine}
          onDeleteThread={onDeleteThread}
          onSaveComposing={onSaveComposing}
          onSaveEditThread={onSaveEditThread}
          onStartEditThread={onStartEditThread}
          onToggleHighlightToken={onToggleHighlightToken}
          tokenCache={cacheEntry.tokensByHunk}
        />
      ) : (
        <div className="px-4 py-8 text-center font-sans text-sm text-gray-400 dark:text-gray-500">{unavailableState}</div>
      )}
    </>
  )
}

function LargeFilePlaceholder({ file, onLoad, rowCount }: { file: ReviewableDiffFile; onLoad: () => void; rowCount: number }) {
  return (
    <div className="space-y-2 border-t border-gray-100 px-4 py-6 font-sans text-sm text-gray-600 dark:border-gray-800 dark:text-gray-300">
      <p className="font-mono text-xs text-gray-500 dark:text-gray-400">{file.path}</p>
      <p>
        {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions} </span> : null}
        {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions} </span> : null}
        This file&rsquo;s diff is large (~{rowCount} rendered lines) and is hidden by default.
      </p>
      <Button onClick={onLoad} size="sm" variant="secondary">Load diff for this file</Button>
    </div>
  )
}

// Tokenizes each hunk's visible lines as one contiguous blob (grouped by
// `hunkId`, see diffRendering.ts) rather than the full source file, since
// only the diff payload -- not full before/after file content -- reaches
// this component. This is a deliberate, documented limitation: a
// multi-line construct (a heredoc, a block comment, a template literal)
// whose opening line falls outside the visible hunk can highlight
// incorrectly at the hunk boundary, because Shiki has no grammar state
// from before the hunk to continue from.
//
// Results are cached in `tokensByHunk`, keyed by hunk id rather than by raw
// line index: hunk ids are stable across hidden-context expansion (expanded
// context lines get hunkId -1, so they never shift an existing hunk's id or
// its cached tokens), and the caller may pass a cache that outlives this
// component's own mount -- see FileCacheEntry -- so a file that scrolls out
// of the virtualized window and back doesn't redo Shiki work it already
// paid for.
function useHighlightedDiffLines(lines: DiffLine[], lang: HighlighterLanguageId | null, tokensByHunk: Map<number, ThemedToken[][]>): (ThemedToken[] | undefined)[] {
  // Bumped after a fetch populates `tokensByHunk` (mutated in place, so its
  // reference never changes on its own) to tell the memo below new entries
  // landed.
  const [version, bumpVersion] = useReducer((count: number) => count + 1, 0)

  const hunkLineIndexes = useMemo(() => {
    const groups = new Map<number, number[]>()
    lines.forEach((line, index) => {
      if (line.hunkId < 0 || !isDiffCodeLine(line.kind)) return
      const indexes = groups.get(line.hunkId) ?? []
      indexes.push(index)
      groups.set(line.hunkId, indexes)
    })
    return groups
  }, [lines])

  useEffect(() => {
    if (!lang) return
    const missing = Array.from(hunkLineIndexes.entries()).filter(([hunkId]) => !tokensByHunk.has(hunkId))
    if (missing.length === 0) return

    let cancelled = false
    const marker = startMarker("diff_review.syntax_highlight", { maxPerSession: 300 })
    Promise.all(
      missing.map(async ([hunkId, indexes]) => {
        const code = indexes.map((index) => lines[index].code).join("\n")
        const tokens = await tokenizeLines(code, lang)
        return [hunkId, tokens] as const
      })
    ).then((results) => {
      if (cancelled) return
      for (const [hunkId, tokens] of results) tokensByHunk.set(hunkId, tokens)
      const tokenSpanCount = results.reduce((sum, [, tokens]) => sum + tokens.reduce((lineSum, lineTokens) => lineSum + lineTokens.length, 0), 0)
      endMarker(marker, { metadata: { hunk_count: missing.length, language: lang, token_span_count: tokenSpanCount } })
      bumpVersion()
    })

    return () => {
      cancelled = true
    }
  }, [hunkLineIndexes, lang, lines, tokensByHunk])

  return useMemo(() => {
    if (!lang) return []
    const result: (ThemedToken[] | undefined)[] = []
    for (const [hunkId, indexes] of hunkLineIndexes) {
      const hunkTokens = tokensByHunk.get(hunkId)
      if (!hunkTokens) continue
      indexes.forEach((lineIndex, tokenIndex) => {
        result[lineIndex] = hunkTokens[tokenIndex]
      })
    }
    return result
    // `version` (not tokensByHunk's identity, which never changes on its own
    // since it's mutated in place) is what signals a completed fetch.
  }, [hunkLineIndexes, lang, tokensByHunk, version])
}

function isDiffCodeLine(kind: DiffLine["kind"]) {
  return kind === "add" || kind === "delete" || kind === "context"
}

export function UnifiedDiffTable({
  annotations,
  comments,
  composingBody,
  composingError,
  composingPending,
  composingSelection,
  editingThreadBody,
  editingThreadId,
  file,
  highlightedToken,
  hunkControls,
  lines: linesProp,
  onCancelComposing,
  onCancelEditThread,
  onChangeComposingBody,
  onChangeEditingThreadBody,
  onCommentLine,
  onDeleteThread,
  onSaveComposing,
  onSaveEditThread,
  onStartEditThread,
  onToggleHighlightToken,
  testId,
  tokenCache: tokenCacheProp
}: {
  annotations?: Record<string, LineAnnotation>
  comments?: Record<string, DiffReviewThread[]>
  composingBody?: string
  composingError?: Error | null
  composingPending?: boolean
  composingSelection?: DiffLineSelection | null
  editingThreadBody?: string
  editingThreadId?: number | null
  file: ReviewableDiffFile
  highlightedToken?: string | null
  hunkControls?: HunkControls[]
  lines?: DiffLine[]
  onCancelComposing?: () => void
  onCancelEditThread?: () => void
  onChangeComposingBody?: (body: string) => void
  onChangeEditingThreadBody?: (body: string) => void
  onCommentLine?: (selection: DiffLineSelection) => void
  onDeleteThread?: (thread: DiffReviewThread) => void
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  onToggleHighlightToken?: (token: string) => void
  testId?: string
  // Optional external Shiki-token cache keyed by hunk id (see
  // useHighlightedDiffLines) -- DiffFileSection passes its per-file cache
  // entry so tokens survive the table unmounting when its file scrolls out
  // of the virtualized window. Standalone callers (e.g. the chat workspace
  // panel) that don't provide one get a component-local cache instead, reset
  // whenever `file.patch` changes so it never serves stale tokens for a
  // different file reusing the same mounted table.
  tokenCache?: Map<number, ThemedToken[][]>
}) {
  const lines = useMemo(() => linesProp ?? parseUnifiedDiff(file.patch || ""), [linesProp, file.patch])
  const lang = detectHighlighterLanguage(file.path)
  const localTokenCache = useRef<{ patch: string | null; tokens: Map<number, ThemedToken[][]> }>({ patch: file.patch, tokens: new Map() })
  if (localTokenCache.current.patch !== file.patch) localTokenCache.current = { patch: file.patch, tokens: new Map() }
  const tokenCache = tokenCacheProp ?? localTokenCache.current.tokens
  const tokensByLine = useHighlightedDiffLines(lines, lang, tokenCache)
  const [localHighlight, setLocalHighlight] = useState<string | null>(null)
  const activeHighlight = highlightedToken !== undefined ? highlightedToken : localHighlight
  const toggleHighlight = onToggleHighlightToken ?? ((token: string) => setLocalHighlight((current) => (current === token ? null : token)))
  const composingKey = composingSelection ? anchorKeyForLine(composingSelection.line, composingSelection.side) : null

  let hunkIndex = -1

  return (
    <div className="overflow-x-auto" data-testid={testId ? `${testId}-scroll` : "diff-file-scroll"}>
      <table className="min-w-full border-separate border-spacing-0 font-mono text-xs" data-testid={testId}>
        <tbody>
          {lines.map((line, index) => {
            if (line.kind === "hunk") {
              hunkIndex += 1
              return <HunkRow controls={hunkControls?.[hunkIndex]} key={`${index}-hunk-${line.hunkNewStart ?? ""}`} line={line} />
            }

            const annotation = line.newLine != null ? annotations?.[String(line.newLine)] : undefined
            const commentSide = line.newLine != null ? "new" : line.oldLine != null ? "old" : null
            const canComment = Boolean(onCommentLine && commentSide)
            const threads = commentSide ? comments?.[anchorKeyForLine(line, commentSide)] || [] : []
            const isComposingHere = Boolean(commentSide && composingKey && composingKey === anchorKeyForLine(line, commentSide))
            return (
              <Fragment key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
              <tr
                className={`group ${diffLineClass(line.kind)}`}
                data-coverage={annotation}
                data-diff-kind={line.kind}
              >
                <td className={`relative ${diffGutterClass(line.kind)}`}>
                  {commentSide === "old" && canComment ? (
                    <GutterCommentButton file={file} line={line} onCommentLine={onCommentLine} side="old" />
                  ) : null}
                  {line.oldLine ?? ""}
                </td>
                <td className={`relative ${diffGutterClass(line.kind)}`}>
                  {commentSide === "new" && canComment ? (
                    <GutterCommentButton file={file} line={line} onCommentLine={onCommentLine} side="new" />
                  ) : null}
                  {line.newLine ?? ""}
                </td>
                <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
                <td className={`min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200 ${diffCoverageBorderClass(annotation)}`}>
                  <DiffCode code={line.code} highlightedToken={activeHighlight} kind={line.kind} onToggleHighlightToken={toggleHighlight} tokens={tokensByLine[index]} />
                </td>
                <td className="w-4 select-none px-1 text-center">
                  {annotation === "covered" ? <span className="text-emerald-600 dark:text-emerald-400">✓</span>
                    : annotation === "uncovered" ? <span className="text-red-600 dark:text-red-400">✗</span>
                    : null}
                </td>
              </tr>
              {threads.length > 0 ? (
                <tr className="bg-amber-50/70 font-sans dark:bg-amber-950/30" data-testid="diff-review-thread">
                  <td className="border-r border-amber-200 dark:border-amber-900" colSpan={2} />
                  <td className="text-amber-700 dark:text-amber-300">*</td>
                  <td className="px-3 py-2 text-xs text-amber-950 dark:text-amber-100" colSpan={2}>
                    <div className="space-y-2">
                      {threads.map((thread) => (
                        <div className="rounded border border-amber-200 bg-white px-3 py-2 dark:border-amber-900 dark:bg-gray-950" key={thread.id}>
                          <div className="mb-1 flex flex-wrap items-center gap-2 text-2xs font-medium uppercase tracking-wide text-amber-700 dark:text-amber-300">
                            <div className="flex flex-wrap items-center gap-2">
                              {thread.author ? <span>{thread.author}</span> : null}
                              <span>{thread.state}</span>
                              {thread.workflowState ? <span>{thread.workflowState}</span> : null}
                            </div>
                            {thread.state === "draft" && onStartEditThread && editingThreadId !== thread.id ? (
                              <button
                                className="normal-case tracking-normal text-amber-700 underline hover:text-amber-900 dark:text-amber-300 dark:hover:text-amber-100"
                                onClick={() => onStartEditThread(thread)}
                                type="button"
                              >
                                Edit
                              </button>
                            ) : null}
                            {thread.state === "draft" && onDeleteThread && editingThreadId !== thread.id ? (
                              <button
                                className="normal-case tracking-normal text-red-700 underline hover:text-red-900 dark:text-red-300 dark:hover:text-red-100"
                                onClick={() => onDeleteThread(thread)}
                                type="button"
                              >
                                Delete
                              </button>
                            ) : null}
                          </div>
                          {editingThreadId === thread.id ? (
                            <div className="space-y-2">
                              <textarea
                                aria-label={`Edit comment ${thread.id}`}
                                className="min-h-20 w-full rounded border border-gray-300 bg-white px-2 py-1 text-sm normal-case tracking-normal text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                                onChange={(event) => onChangeEditingThreadBody?.(event.target.value)}
                                value={editingThreadBody ?? ""}
                              />
                              <div className="flex gap-2">
                                <Button disabled={!editingThreadBody?.trim()} onClick={onSaveEditThread} size="sm">Save</Button>
                                <Button onClick={onCancelEditThread} size="sm" variant="secondary">Cancel</Button>
                              </div>
                            </div>
                          ) : (
                            <p className="whitespace-pre-wrap break-words text-sm normal-case tracking-normal text-gray-800 dark:text-gray-200">{thread.body}</p>
                          )}
                        </div>
                      ))}
                    </div>
                  </td>
                </tr>
              ) : null}
              {isComposingHere ? (
                <tr className="bg-brand/5 font-sans" data-testid="diff-review-composer">
                  <td className="border-r border-brand/20" colSpan={2} />
                  <td className="text-brand">*</td>
                  <td className="px-3 py-2" colSpan={2}>
                    <div className="space-y-2">
                      <textarea
                        aria-label="Comment"
                        autoFocus
                        className="min-h-20 w-full rounded border border-gray-300 bg-white px-2 py-1 text-sm normal-case tracking-normal text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                        onChange={(event) => onChangeComposingBody?.(event.target.value)}
                        value={composingBody ?? ""}
                      />
                      <div className="flex gap-2">
                        <Button disabled={!composingBody?.trim() || composingPending} onClick={onSaveComposing} size="sm">Create comment</Button>
                        <Button onClick={onCancelComposing} size="sm" variant="secondary">Cancel</Button>
                      </div>
                      {composingError ? <p className="text-xs text-red-700 dark:text-red-300">Unable to create diff comment.</p> : null}
                    </div>
                  </td>
                </tr>
              ) : null}
              </Fragment>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

export function DiffHunkSnippet({ highlightLine, hunk }: { highlightLine?: string | null; hunk: string }) {
  const lines = hunk.replace(/\r\n/g, "\n").split("\n")
  return (
    <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-800">
      {lines.map((line, index) => (
        <div
          className={`whitespace-pre px-2 py-0.5 font-mono text-2xs ${diffLineClass(hunkLineKind(line))} ${highlightLine != null && line === highlightLine ? "ring-1 ring-inset ring-brand" : ""}`}
          key={index}
        >
          {line || " "}
        </div>
      ))}
    </div>
  )
}

function hunkLineKind(line: string): DiffLineKind {
  if (line.startsWith("@@")) return "hunk"
  if (line.startsWith("+") && !line.startsWith("+++")) return "add"
  if (line.startsWith("-") && !line.startsWith("---")) return "delete"
  return "context"
}

// Renders one diff line's code cell. When Shiki tokens are available (see
// useHighlightedDiffLines above), each Shiki token is re-split into
// clickable word/number tokens via tokenizeCode so syntax coloring and
// click-to-highlight-matching-occurrences both apply at once; every
// sub-token inherits its parent Shiki token's color. Before tokenization
// resolves (or for an unrecognized language), falls back to plain
// click-to-highlight over the untinted code.
function DiffCode({
  code,
  highlightedToken,
  kind,
  onToggleHighlightToken,
  tokens
}: {
  code: string
  highlightedToken?: string | null
  kind: DiffLineKind
  onToggleHighlightToken: (token: string) => void
  tokens?: ThemedToken[]
}) {
  const highlightable = kind === "add" || kind === "delete" || kind === "context"
  if (!highlightable || !code) return <>{tokens ? renderCodeLine(tokens, code || " ") : (code || " ")}</>

  if (tokens) {
    return (
      <>
        {tokens.map((shikiToken, tokenIndex) => (
          <Fragment key={tokenIndex}>
            {tokenizeCode(shikiToken.content).map((word, wordIndex) => word.highlightable ? (
              <span
                className={`cursor-pointer rounded-sm ${highlightedToken === word.text ? "bg-amber-200 text-amber-950 dark:bg-amber-500/50 dark:text-amber-50" : "hover:bg-amber-100 dark:hover:bg-amber-500/20"}`}
                key={wordIndex}
                onClick={() => onToggleHighlightToken(word.text)}
                style={{ color: shikiToken.color }}
              >
                {word.text}
              </span>
            ) : <span key={wordIndex} style={{ color: shikiToken.color }}>{word.text}</span>)}
          </Fragment>
        ))}
      </>
    )
  }

  const wordTokens = tokenizeCode(code)
  return (
    <>
      {wordTokens.map((token, index) => token.highlightable ? (
        <span
          className={`cursor-pointer rounded-sm ${highlightedToken === token.text ? "bg-amber-200 text-amber-950 dark:bg-amber-500/50 dark:text-amber-50" : "hover:bg-amber-100 dark:hover:bg-amber-500/20"}`}
          key={index}
          onClick={() => onToggleHighlightToken(token.text)}
        >
          {token.text}
        </span>
      ) : <span key={index}>{token.text}</span>)}
    </>
  )
}

function HunkRow({ controls, line }: { controls?: HunkControls; line: DiffLine }) {
  return (
    <tr className={`group ${diffLineClass("hunk")}`} data-diff-kind="hunk">
      <td className={diffGutterClass("hunk")}>
        {controls?.up ? <HunkContextButton direction="up" loading={controls.up.loading} onClick={controls.up.onClick} /> : null}
      </td>
      <td className={diffGutterClass("hunk")}>
        {controls?.down ? <HunkContextButton direction="down" loading={controls.down.loading} onClick={controls.down.onClick} /> : null}
      </td>
      <td className={diffMarkerClass("hunk")}>{line.marker}</td>
      <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200">{line.code}</td>
      <td className="w-4 select-none px-1 text-center" />
    </tr>
  )
}

function HunkContextButton({ direction, loading, onClick }: { direction: "down" | "up"; loading: boolean; onClick: () => void }) {
  return (
    <button
      aria-label={direction === "up" ? `Load ${CONTEXT_EXPAND_LINE_INCREMENT} more lines above` : `Load ${CONTEXT_EXPAND_LINE_INCREMENT} more lines below`}
      className="inline-flex h-4 w-4 items-center justify-center rounded text-info hover:bg-info/10 disabled:opacity-50"
      disabled={loading}
      onClick={onClick}
      type="button"
    >
      {direction === "up" ? "▲" : "▼"}
    </button>
  )
}

function GutterCommentButton({
  file,
  line,
  onCommentLine,
  side
}: {
  file: ReviewableDiffFile
  line: DiffLine
  onCommentLine?: (selection: DiffLineSelection) => void
  side: "old" | "new"
}) {
  return (
    <button
      aria-label={`Comment on ${file.path}:${side}:${line.newLine ?? line.oldLine}`}
      className="absolute left-0.5 top-1/2 flex h-4 w-4 -translate-y-1/2 items-center justify-center rounded-full bg-brand text-2xs leading-none text-on-brand opacity-0 transition-opacity hover:opacity-100 group-hover:opacity-100"
      onClick={() => onCommentLine?.({ file, line, side })}
      type="button"
    >
      +
    </button>
  )
}

function anchorKeyForLine(line: DiffLine, side: "old" | "new") {
  if (side === "old") return `left:${line.oldLine ?? ""}:${line.newLine ?? ""}`
  return `right:${line.oldLine ?? ""}:${line.newLine ?? ""}`
}

function DiffFileHeader({
  file,
  loadWholeFileState,
  onLoadWholeFile,
  onSelectFile,
  onToggleFilesPopup,
  selected,
  showFilesPopupTrigger
}: {
  file: ReviewableDiffFile
  loadWholeFileState?: "error" | "idle" | "loaded" | "loading" | null
  onLoadWholeFile?: () => void
  onSelectFile?: (path: string) => void
  onToggleFilesPopup?: (event: MouseEvent<HTMLButtonElement>) => void
  selected: boolean
  showFilesPopupTrigger?: boolean
}) {
  const content = (
    <>
      <span className="min-w-0 flex-1 truncate">{file.path}</span>
      {typeof file.additions === "number" ? <span>+{file.additions}</span> : null}
      {typeof file.deletions === "number" ? <span>-{file.deletions}</span> : null}
    </>
  )
  // max-lg:top-14 keeps this below the app chrome's own sticky top bar, which
  // stays visible (AppChromeV2's `lg:hidden` bar) up through the `lg` breakpoint,
  // not just `md` — otherwise a tablet-width viewport (768-1023px) sticks this
  // header at the very top, behind that bar, instead of just under it.
  const className = `sticky top-0 z-10 flex w-full items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 text-left font-mono text-xs text-gray-600 max-lg:top-14 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400 ${selected ? "text-brand dark:text-brand-emphasis" : ""}`

  return (
    <div className={className} title={file.path}>
      {onSelectFile ? (
        <button className="flex min-w-0 flex-1 items-center gap-3 text-left" onClick={() => onSelectFile(file.path)} type="button">
          {content}
        </button>
      ) : (
        <div className="flex min-w-0 flex-1 items-center gap-3">{content}</div>
      )}
      {onLoadWholeFile ? (
        <button
          className="shrink-0 rounded border border-gray-300 px-2 py-0.5 font-sans text-2xs font-medium text-gray-600 hover:bg-white disabled:opacity-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
          disabled={loadWholeFileState !== "idle" && loadWholeFileState !== "error"}
          onClick={onLoadWholeFile}
          type="button"
        >
          {loadWholeFileState === "loaded" ? "Whole file loaded" : loadWholeFileState === "loading" ? "Loading…" : "Load whole file"}
        </button>
      ) : null}
      {showFilesPopupTrigger ? (
        <button
          aria-label="Browse changed files"
          className="shrink-0 rounded border border-gray-300 px-2 py-0.5 font-sans text-2xs font-medium text-gray-600 hover:bg-white dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
          onClick={onToggleFilesPopup}
          type="button"
        >
          Files
        </button>
      ) : null}
    </div>
  )
}

function filesForMode(files: ReviewableDiffFile[], mode: "single-file" | "continuous", selectedPath: string | null | undefined) {
  if (mode === "continuous") return files
  if (!selectedPath) return files.slice(0, 1)
  const selected = files.find((file) => file.path === selectedPath)
  return selected ? [selected] : []
}

export function filesFromUnifiedDiff(diff: string): ReviewableDiffFile[] {
  const normalized = diff.replace(/\r\n/g, "\n").trimEnd()
  if (!normalized) return []

  const rawFiles = normalized.split(/\n(?=diff --git )/)
  const files = rawFiles.map((patch, index) => {
    const path = pathFromPatch(patch) || (rawFiles.length === 1 ? "diff" : `diff-${index + 1}`)
    return {
      path,
      patch,
      additions: patch.split("\n").filter((line) => line.startsWith("+") && !line.startsWith("+++")).length,
      deletions: patch.split("\n").filter((line) => line.startsWith("-") && !line.startsWith("---")).length,
      status: statusFromPatch(patch)
    }
  })

  return files.length > 0 ? files : [{ path: "diff", patch: normalized }]
}

function pathFromPatch(patch: string) {
  const header = patch.match(/^diff --git a\/(.+?) b\/(.+)$/m)
  if (header) return header[2]

  const newPath = patch.match(/^\+\+\+ b\/(.+)$/m)
  if (newPath) return newPath[1]

  const oldPath = patch.match(/^--- a\/(.+)$/m)
  return oldPath?.[1] || null
}

function statusFromPatch(patch: string) {
  if (/^new file mode /m.test(patch)) return "added"
  if (/^deleted file mode /m.test(patch)) return "removed"
  if (/^rename from /m.test(patch) || /^rename to /m.test(patch)) return "renamed"
  return "modified"
}

function annotationsForFile(
  annotations: ReviewableDiffProps["annotations"],
  path: string
): Record<string, LineAnnotation> | undefined {
  if (!annotations) return undefined
  if (isLineAnnotations(annotations)) return annotations
  return annotations[path]
}

function isLineAnnotations(annotations: NonNullable<ReviewableDiffProps["annotations"]>): annotations is Record<string, LineAnnotation> {
  return Object.values(annotations).every((value) => typeof value === "string")
}
