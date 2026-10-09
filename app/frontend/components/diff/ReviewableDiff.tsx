import { Fragment, useEffect, useMemo, useReducer, useRef, useState, type MouseEvent, type ReactNode, type RefObject } from "react"
import { createPortal } from "react-dom"
import type { ThemedToken } from "@shikijs/core"
import { useVirtualizer } from "@tanstack/react-virtual"
import { Button } from "../Button"
import { ChevronIcon } from "../ChevronIcon"
import { CloseIcon } from "../CloseIcon"
import { renderCodeLine } from "../CodeBlock"
import { CopyIcon } from "../CopyableSlug"
import { DEFAULT_REVIEW_DIFF_SETTINGS, type ReviewDiffSettings } from "../../api/reviewDiffSettings"
import { useCopyToClipboard } from "../../hooks/useCopyToClipboard"
import { useT } from "../../hooks/useT"
import type { DiffReviewAnnotation, DiffReviewAnnotationCount, DiffReviewAnnotationRange } from "../../api/jobs"
import { useDismissiblePopup } from "../../lib/useDismissiblePopup"
import { renderPluginReviewAnnotation } from "../../pluginReviewAnnotations"
import { detectHighlighterLanguage, tokenizeLines, type HighlighterLanguageId } from "../../lib/highlighter"
import { Markdown } from "../../lib/Markdown"
import { endMarker, measureSync, recordCount, startMarker, type PerformanceMarkerHandle } from "../../lib/performanceMarkers"
import {
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
  forcedGapStatesForAnnotationRanges,
  gapSize as contextGapSize,
  hunksFromLines,
  mergeGapRevealStates,
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
  generated?: boolean
  generated_reason?: string | null
  generated_source?: string | null
  is_image?: boolean
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
  composingDiscussError?: Error | null
  composingDiscussPending?: boolean
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
  onDiscussComposing?: () => void
  // Fetches the full current file text (at the diff's head ref) so hidden
  // hunk context and "load whole file" can reveal real content. Omit to
  // hide context-expansion affordances entirely (e.g. a standalone patch
  // view with no backing ref to fetch from).
  onLoadFileContext?: (file: ReviewableDiffFile) => Promise<string | null>
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onSelectFile?: (path: string) => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  // Renders a before/after thumbnail pair (or similar) for a file whose
  // patch is unavailable because it's a recognized image. Takes over from
  // `unavailableState` only when `file.is_image` is true; other
  // binary/large files still fall back to the plain placeholder.
  renderImageDiff?: (file: ReviewableDiffFile) => ReactNode
  scroll?: "bounded" | "natural"
  selectedPath?: string | null
  showFileHeaders?: boolean | "continuous"
  unavailableState?: ReactNode
  reviewSettings?: ReviewDiffSettings
  reviewAnnotations?: Record<string, Record<string, DiffReviewAnnotation[]>> | null
  reviewAnnotationCounts?: DiffReviewAnnotationCount[] | null
  reviewAnnotationRanges?: Record<string, DiffReviewAnnotationRange[]> | null
  highlightedReviewAnnotationId?: string | null
  activeDiffLineMetricProviderId?: string | null
  diffLineMetricProviders?: DiffLineMetricProvider[] | null
  wordHighlighting?: boolean
}

export type DiffLineMetricTone = "clear" | "risk" | "neutral" | "info" | "warning" | "danger" | "success"

export type DiffLineMetric = {
  id: string
  label: string
  tone: DiffLineMetricTone
  title?: string
  annotationIds?: string[]
}

export type DiffLineMetricContext = {
  file: ReviewableDiffFile
  line: DiffLine
  reviewNotes: DiffReviewAnnotation[]
}

export type DiffLineMetricProvider = {
  id: string
  label: string
  metricForLine: (context: DiffLineMetricContext) => DiffLineMetric | null
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
const DIFF_INLINE_REVIEW_PANEL_BASE_CLASS =
  "box-border min-w-0 w-[min(44rem,calc(100vw-3rem))] max-w-[min(44rem,calc(100vw-3rem))] md:w-[min(44rem,100cqw,calc(100vw-3rem))] md:max-w-[min(44rem,100cqw,calc(100vw-3rem))]"
const DIFF_INLINE_REVIEW_PANEL_MOBILE_CODE_COLUMN_CLASS =
  "box-border min-w-0 w-[min(44rem,calc(100vw-5rem))] max-w-[min(44rem,calc(100vw-5rem))] md:w-[min(44rem,100cqw,calc(100vw-3rem))] md:max-w-[min(44rem,100cqw,calc(100vw-3rem))]"
const DIFF_INLINE_REVIEW_PANEL_STICKY_CLASS = `sticky left-0 z-[1] ${DIFF_INLINE_REVIEW_PANEL_BASE_CLASS}`
const DIFF_FILE_HEADER_CONTROL_BASE_CLASS =
  "shrink-0 rounded border border-border font-sans font-medium text-text-secondary hover:bg-surface-raised disabled:opacity-50"

const DIFF_DENSITY_CLASSES: Record<
  ReviewDiffSettings["density"],
  {
    changedFilesHeader: string
    changedFilesRow: string
    codeCell: string
    commentButton: string
    fileHeader: string
    fileHeaderControl: string
    filePathCopy: string
    gutter: string
    hunkCodeCell: string
    inlineReviewCell: string
    marker: string
    tableText: string
  }
> = {
  compact: {
    changedFilesHeader: "px-2 py-1",
    changedFilesRow: "gap-1.5 px-2 py-1",
    codeCell: "px-2 py-0 leading-[14px]",
    commentButton: "h-3 w-3 text-[9px]",
    fileHeader: "gap-2 px-3 py-1 text-2xs",
    fileHeaderControl: "px-1.5 py-0 text-[10px]",
    filePathCopy: "gap-1 px-1 py-0",
    gutter: "px-1.5 py-0 leading-[14px]",
    hunkCodeCell: "px-2 py-0 leading-[14px]",
    inlineReviewCell: "px-2 py-1",
    marker: "px-1.5 py-0 leading-[14px]",
    tableText: "text-2xs"
  },
  comfortable: {
    changedFilesHeader: "px-3 py-2",
    changedFilesRow: "gap-2 px-3 py-2",
    codeCell: "px-3 py-0.5",
    commentButton: "h-4 w-4 text-2xs",
    fileHeader: "gap-3 px-4 py-2 text-xs",
    fileHeaderControl: "px-2 py-0.5 text-2xs",
    filePathCopy: "gap-1 px-1 py-0.5",
    gutter: "px-2 py-0.5",
    hunkCodeCell: "px-3 py-0.5",
    inlineReviewCell: "px-3 py-2",
    marker: "px-2 py-0.5",
    tableText: "text-xs"
  },
  spacious: {
    changedFilesHeader: "px-4 py-3",
    changedFilesRow: "gap-2.5 px-4 py-3",
    codeCell: "px-4 py-1 leading-6",
    commentButton: "h-5 w-5 text-xs",
    fileHeader: "gap-3 px-5 py-3 text-sm",
    fileHeaderControl: "px-2.5 py-1 text-xs",
    filePathCopy: "gap-1.5 px-1.5 py-1",
    gutter: "px-2.5 py-1 leading-6",
    hunkCodeCell: "px-4 py-1 leading-6",
    inlineReviewCell: "px-4 py-3",
    marker: "px-2.5 py-1 leading-6",
    tableText: "text-sm"
  }
}

const DIFF_DENSITY_ESTIMATES: Record<ReviewDiffSettings["density"], { header: number; row: number }> = {
  compact: { header: 29, row: 17 },
  comfortable: { header: DEFAULT_FILE_HEADER_HEIGHT_PX, row: DEFAULT_FILE_ROW_HEIGHT_PX },
  spacious: { header: 45, row: 25 }
}

// Per-file state that must survive a file section unmounting and remounting
// as the user scrolls it out of, then back into, the virtualized window --
// otherwise expanded hidden-context and fetched Shiki tokens would silently
// redo their work (or reset visually) every time a file leaves the overscan
// range. Held in a Map on the parent ReviewableDiff (keyed by file path, not
// component state), so the entry itself survives across DiffFileSection
// mount/unmount cycles; only the whole diff changing (see `fileCache.current
// = new Map()` below) clears it.
type FileCacheEntry = {
  collapsed: boolean
  contextState: FileContextState
  forceLoaded: boolean
  tokensByHunk: Map<number, ThemedToken[][]>
}

type ChangedFilesListLayout = ReviewDiffSettings["file_list_layout"]
type ChangedFileTreeNode = {
  children: ChangedFileTreeNode[]
  file: ReviewableDiffFile | null
  name: string
  path: string
}

function createFileCacheEntry(): FileCacheEntry {
  return { collapsed: false, contextState: { fullyExpanded: false, gaps: [], lines: null, status: "idle" }, forceLoaded: false, tokensByHunk: new Map() }
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
function estimateFileSectionHeight(
  file: ReviewableDiffFile,
  {
    collapsed,
    density,
    forceLoaded,
    largeFileRowThreshold,
    showHeader
  }: { collapsed: boolean; density: ReviewDiffSettings["density"]; forceLoaded: boolean; largeFileRowThreshold: number; showHeader: boolean }
): number {
  const estimates = DIFF_DENSITY_ESTIMATES[density]
  const header = showHeader ? estimates.header : 0
  if (collapsed) return header
  if (file.generated && !forceLoaded) return header + DEFAULT_FILE_PLACEHOLDER_HEIGHT_PX
  if (file.patch === null) return header + DEFAULT_FILE_UNAVAILABLE_HEIGHT_PX
  const rowCount = countDiffRows(file.patch)
  if (rowCount > largeFileRowThreshold && !forceLoaded) return header + DEFAULT_FILE_PLACEHOLDER_HEIGHT_PX
  return header + rowCount * estimates.row
}

export function ReviewableDiff({
  annotations,
  changedFilesPopup = false,
  comments,
  composingBody,
  composingDiscussError,
  composingDiscussPending,
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
  onDiscussComposing,
  onLoadFileContext,
  onSaveComposing,
  onSaveEditThread,
  onSelectFile,
  onStartEditThread,
  renderImageDiff,
  reviewSettings,
  reviewAnnotations,
  reviewAnnotationCounts,
  reviewAnnotationRanges,
  highlightedReviewAnnotationId,
  activeDiffLineMetricProviderId,
  diffLineMetricProviders,
  scroll = "bounded",
  selectedPath,
  showFileHeaders = "continuous",
  unavailableState = "Diff not available",
  wordHighlighting
}: ReviewableDiffProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const scrollContainerRef = useRef<HTMLDivElement>(null)
  const filesPopupTriggerRef = useRef<HTMLButtonElement | null>(null)
  const [filesPopupOpen, setFilesPopupOpen] = useState(false)
  const [filesPopupPlacement, setFilesPopupPlacement] = useState<FilesPopupPlacement | null>(null)
  // Started when the Files menu opens, ended once its popup has actually
  // been positioned and rendered -- open-to-render latency, not just the
  // click handler's own (near-zero) synchronous cost.
  const filesMenuMarkerRef = useRef<PerformanceMarkerHandle | null>(null)
  const [highlightedToken, setHighlightedToken] = useState<string | null>(null)
  const isMobileFilesMenu = useIsMobileViewport()
  const effectiveReviewSettings = { ...DEFAULT_REVIEW_DIFF_SETTINGS, ...reviewSettings }
  const wordHighlightingEnabled = wordHighlighting ?? effectiveReviewSettings.intraline_highlighting === "word"
  const { t } = useT("common")
  // Per-file cache (parsed context state, fetched Shiki tokens) keyed by file
  // path -- survives a file section unmounting when it scrolls out of the
  // virtualized window. Reset below whenever the diff itself changes.
  const fileCache = useRef(new Map<string, FileCacheEntry>())

  const sortedFiles = useMemo(() => sortReviewFiles(files, effectiveReviewSettings.file_sort), [files, effectiveReviewSettings.file_sort])
  const renderFiles = filesForMode(sortedFiles, mode, selectedPath)
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

  const containerClass =
    scroll === "natural"
      ? "min-w-0 max-w-full bg-white font-mono text-xs dark:bg-gray-950"
      : "max-h-[32rem] min-w-0 max-w-full overflow-y-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950"

  const visibleFiles = renderFiles.slice(0, visibleFileCount)
  const remainingFileCount = renderFiles.length - visibleFiles.length
  const showHeader = showFileHeaders === true || (showFileHeaders === "continuous" && mode === "continuous")
  const effectiveDiffLineMetricProviders = useMemo(() => {
    const providers = diffLineMetricProvidersForReview(reviewAnnotationCounts, t, diffLineMetricProviders)
    if (activeDiffLineMetricProviderId === "off") return []
    if (activeDiffLineMetricProviderId) return providers.filter((provider) => provider.id === activeDiffLineMetricProviderId)
    return providers
  }, [activeDiffLineMetricProviderId, reviewAnnotationCounts, t, diffLineMetricProviders])

  function estimateSize(index: number) {
    const file = visibleFiles[index]
    if (!file) return DEFAULT_FILE_HEADER_HEIGHT_PX
    const cacheEntry = fileCache.current.get(file.path)
    return estimateFileSectionHeight(file, {
      collapsed: cacheEntry?.collapsed ?? false,
      density: effectiveReviewSettings.density,
      forceLoaded: cacheEntry?.forceLoaded ?? false,
      largeFileRowThreshold,
      showHeader
    })
  }

  function getItemKey(index: number) {
    return visibleFiles[index]?.path ?? index
  }

  const virtualizer = useVirtualizer({
    count: visibleFiles.length,
    enabled: scroll === "bounded",
    estimateSize,
    getItemKey,
    getScrollElement: () => scrollContainerRef.current,
    overscan: DEFAULT_FILE_VIRTUALIZATION_OVERSCAN
  })

  // Navigates the virtualized list to `selectedPath` whenever it changes
  // (Files menu selection or a sidebar comment's "View in diff") -- unlike the old
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
    measureSync(
      "diff_review.anchor_scroll",
      () => {
        if (scroll === "natural") {
          document.querySelector(`[data-diff-file="${CSS.escape(target)}"]`)?.scrollIntoView({ block: "start" })
        } else {
          virtualizer.scrollToIndex(index, { align: "start" })
        }
      },
      {
        maxPerSession: 200,
        metadata: { selected_path: target, virtualization_mode: scroll }
      }
    )
  })

  const virtualItems = virtualizer.getVirtualItems()
  const renderedFileCount = scroll === "natural" ? visibleFiles.length : virtualItems.length

  // Throttled by the effect's own dependency array, not a timer: this only
  // fires when the *count* of virtualized (mounted) files actually changes
  // -- initial mount, "load more files", or files scrolling in/out of the
  // overscan range -- not on every scroll-position pixel.
  useEffect(() => {
    const mountedFiles =
      scroll === "natural" ? visibleFiles : virtualItems.map((item) => visibleFiles[item.index]).filter((file): file is ReviewableDiffFile => Boolean(file))
    const mountedRows = mountedFiles.reduce((sum, file) => sum + (file.patch ? countDiffRows(file.patch) : 0), 0)
    recordCount("diff_review.viewport_render", {
      maxPerSession: 300,
      metadata: {
        mounted_files: mountedFiles.length,
        mounted_rows: mountedRows,
        total_files: visibleFiles.length,
        virtualization_mode: scroll
      }
    })
  }, [renderedFileCount, visibleFiles, scroll, virtualItems])

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
    filesPopupTriggerRef.current = event.currentTarget
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
    document.querySelector(`[data-diff-file="${CSS.escape(path)}"]`)?.scrollIntoView({ block: "start" })
    setFilesPopupOpen(false)
  }

  function toggleHighlightToken(token: string) {
    setHighlightedToken((current) => (current === token ? null : token))
  }

  function clearHighlightOnDiffBackgroundClick(event: MouseEvent<HTMLDivElement>) {
    if (!highlightedToken) return
    if (event.target instanceof Element && event.target.closest("[data-diff-highlight-token]")) return

    setHighlightedToken(null)
  }

  return (
    <div className="relative min-w-0 max-w-full [contain:inline-size]" data-testid="agent-diff-viewer" ref={containerRef}>
      <div
        className={containerClass}
        data-rendered-file-count={renderedFileCount}
        data-total-file-count={visibleFiles.length}
        onClick={wordHighlightingEnabled ? clearHighlightOnDiffBackgroundClick : undefined}
        ref={scrollContainerRef}
      >
        {scroll === "natural" ? (
          visibleFiles.map((file, index) => renderFileSection(file, index))
        ) : (
          <div style={{ height: virtualizer.getTotalSize(), position: "relative", width: "100%" }}>
            {virtualItems.map((virtualItem) => {
              const file = visibleFiles[virtualItem.index]
              if (!file) return null
              return (
                <div data-index={virtualItem.index} key={virtualItem.key} ref={virtualizer.measureElement} style={virtualFileSectionStyle(virtualItem.start)}>
                  {renderFileSection(file, virtualItem.index)}
                </div>
              )
            })}
          </div>
        )}
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
      {changedFilesPopup && filesPopupOpen
        ? renderChangedFilesOverlay(
            isMobileFilesMenu ? (
              <MobileChangedFilesModal
                commentCounts={fileCommentCounts}
                files={sortedFiles}
                density={effectiveReviewSettings.density}
                layout={effectiveReviewSettings.file_list_layout}
                onClose={() => setFilesPopupOpen(false)}
                onSelectFile={selectFileFromPopup}
                selectedPath={selectedPath}
              />
            ) : (
              <ChangedFilesPopup
                commentCounts={fileCommentCounts}
                files={sortedFiles}
                filesPopupTriggerRef={filesPopupTriggerRef}
                density={effectiveReviewSettings.density}
                layout={effectiveReviewSettings.file_list_layout}
                onClose={() => setFilesPopupOpen(false)}
                onSelectFile={selectFileFromPopup}
                placement={filesPopupPlacement}
                selectedPath={selectedPath}
              />
            )
          )
        : null}
    </div>
  )

  function renderFileSection(file: ReviewableDiffFile, index: number) {
    return (
      <section
        className={index > 0 ? "border-t border-gray-200 dark:border-gray-800" : ""}
        data-diff-file={file.path}
        key={file.path}
        style={stickyFileHeaderBoundaryStyle(showHeader, effectiveReviewSettings.density)}
      >
        <DiffFileSection
          annotations={annotationsForFile(annotations, file.path)}
          cache={fileCache.current}
          comments={comments?.[file.path]}
          composingBody={composingBody}
          composingDiscussError={composingDiscussError}
          composingDiscussPending={composingDiscussPending}
          composingError={composingError}
          composingPending={composingPending}
          composingSelection={composingSelection?.file.path === file.path ? composingSelection : undefined}
          editingThreadBody={editingThreadBody}
          editingThreadId={editingThreadId}
          file={file}
          highlightedToken={wordHighlightingEnabled ? highlightedToken : null}
          largeFileRowThreshold={largeFileRowThreshold}
          onCancelComposing={onCancelComposing}
          onCancelEditThread={onCancelEditThread}
          onChangeComposingBody={onChangeComposingBody}
          onChangeEditingThreadBody={onChangeEditingThreadBody}
          onCommentLine={onCommentLine}
          onDeleteThread={onDeleteThread}
          onDiscussComposing={onDiscussComposing}
          onLoadFileContext={onLoadFileContext}
          onSaveComposing={onSaveComposing}
          onSaveEditThread={onSaveEditThread}
          onStartEditThread={onStartEditThread}
          onToggleFilesPopup={changedFilesPopup ? toggleFilesPopup : undefined}
          onToggleHighlightToken={wordHighlightingEnabled ? toggleHighlightToken : undefined}
          renderImageDiff={renderImageDiff}
          reviewSettings={effectiveReviewSettings}
          reviewAnnotations={reviewAnnotations?.[file.path]}
          diffLineMetricProviders={effectiveDiffLineMetricProviders}
          reviewAnnotationRanges={reviewAnnotationRanges?.[file.path]}
          highlightedReviewAnnotationId={highlightedReviewAnnotationId}
          selected={selectedPath === file.path}
          showFilesPopupTrigger={changedFilesPopup}
          showHeader={showHeader}
          unavailableState={unavailableState}
        />
      </section>
    )
  }
}

function renderChangedFilesOverlay(overlay: ReactNode) {
  if (typeof document === "undefined") return overlay

  return createPortal(overlay, document.body)
}

function virtualFileSectionStyle(offsetTop: number) {
  // Keep file sections out of transformed containing blocks. Safari in
  // particular mispositions sticky descendants when the virtualized row is
  // moved with translateY(), which makes diff file headers drift away from
  // the code rows as the review view scrolls.
  return { left: 0, position: "absolute" as const, top: offsetTop, width: "100%" }
}

function stickyFileHeaderBoundaryStyle(showHeader: boolean, density: ReviewDiffSettings["density"]) {
  if (!showHeader) return undefined

  // A sticky child is constrained by the bottom edge of its containing block.
  // Without this extra boundary room, the header releases during the final
  // header-height of its file section, leaving trailing rows visible at the
  // top of the review pane without their file label.
  const headerHeight = DIFF_DENSITY_ESTIMATES[density].header
  return { marginBottom: -headerHeight, paddingBottom: headerHeight }
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
  density,
  files,
  filesPopupTriggerRef,
  layout,
  onClose,
  onSelectFile,
  placement,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  density: ReviewDiffSettings["density"]
  files: ReviewableDiffFile[]
  filesPopupTriggerRef: RefObject<HTMLButtonElement | null>
  layout: ChangedFilesListLayout
  onClose: () => void
  onSelectFile: (path: string) => void
  placement: FilesPopupPlacement | null
  selectedPath?: string | null
}) {
  const { t } = useT("common")
  const popupRef = useDismissiblePopup<HTMLDivElement>(true, onClose, [filesPopupTriggerRef])

  return (
    <div className="fixed inset-0 z-30" onClick={onClose}>
      <div
        className="fixed z-30 flex flex-col overflow-hidden rounded border border-gray-200 bg-white font-mono text-xs shadow-lg dark:border-gray-700 dark:bg-gray-900"
        onClick={(event) => event.stopPropagation()}
        ref={popupRef}
        role="dialog"
        style={
          placement
            ? {
                bottom: placement.bottom,
                left: placement.left,
                maxHeight: placement.maxHeight,
                top: placement.top,
                width: placement.width
              }
            : { left: 16, maxHeight: 480, top: 56, width: 320 }
        }
      >
        <p
          className={`shrink-0 border-b border-gray-100 font-sans text-xs font-semibold uppercase tracking-wide text-gray-500 dark:border-gray-800 dark:text-gray-400 ${DIFF_DENSITY_CLASSES[density].changedFilesHeader}`}
        >
          {t("diff_review.changed_files")}
        </p>
        <div className="min-h-0 flex-1 overflow-auto">
          <ChangedFilesList
            commentCounts={commentCounts}
            density={density}
            files={files}
            layout={layout}
            onSelectFile={onSelectFile}
            selectedPath={selectedPath}
          />
        </div>
      </div>
    </div>
  )
}

function MobileChangedFilesModal({
  commentCounts,
  density,
  files,
  layout,
  onClose,
  onSelectFile,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  density: ReviewDiffSettings["density"]
  files: ReviewableDiffFile[]
  layout: ChangedFilesListLayout
  onClose: () => void
  onSelectFile: (path: string) => void
  selectedPath?: string | null
}) {
  const { t } = useT("common")
  const modalRef = useDismissiblePopup<HTMLDivElement>(true, onClose)

  return (
    <div className="fixed inset-0 z-[60] flex h-[100dvh] w-[100dvw] flex-col bg-white font-mono text-xs dark:bg-gray-950" ref={modalRef} role="dialog">
      <div className="flex shrink-0 items-center justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
        <p className="font-sans text-sm font-semibold text-gray-700 dark:text-gray-200">{t("diff_review.changed_files")}</p>
        <button
          aria-label={t("diff_review.close_changed_files")}
          className="rounded p-2 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
          onClick={onClose}
          type="button"
        >
          <CloseIcon className="h-5 w-5" />
        </button>
      </div>
      <div className="flex-1 overflow-auto">
        <ChangedFilesList
          commentCounts={commentCounts}
          density={density}
          files={files}
          layout={layout}
          onSelectFile={onSelectFile}
          selectedPath={selectedPath}
        />
      </div>
    </div>
  )
}

function ChangedFilesList({
  commentCounts,
  density,
  files,
  layout,
  onSelectFile,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  density: ReviewDiffSettings["density"]
  files: ReviewableDiffFile[]
  layout: ChangedFilesListLayout
  onSelectFile: (path: string) => void
  selectedPath?: string | null
}) {
  if (layout === "nested")
    return <NestedChangedFilesList commentCounts={commentCounts} density={density} files={files} onSelectFile={onSelectFile} selectedPath={selectedPath} />

  return (
    <>
      {files.map((file) => {
        return (
          <button
            className={`flex w-full items-center text-left hover:bg-brand/10 ${DIFF_DENSITY_CLASSES[density].changedFilesRow} ${selectedPath === file.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
            key={file.path}
            onClick={() => onSelectFile(file.path)}
            title={`${file.path} (+${file.additions ?? 0} -${file.deletions ?? 0})`}
            type="button"
          >
            <span className="min-w-0 flex-1 truncate">{file.path}</span>
            <GeneratedFileBadge file={file} />
            {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions}</span> : null}
            {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions}</span> : null}
            {commentCounts?.[file.path] ? (
              <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">
                {commentCounts[file.path]}
              </span>
            ) : null}
          </button>
        )
      })}
    </>
  )
}

function NestedChangedFilesList({
  commentCounts,
  density,
  files,
  onSelectFile,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  density: ReviewDiffSettings["density"]
  files: ReviewableDiffFile[]
  onSelectFile: (path: string) => void
  selectedPath?: string | null
}) {
  const tree = useMemo(() => buildChangedFileTree(files), [files])
  const directorySignature = useMemo(() => changedFileDirectoryPaths(tree).join("\n"), [tree])
  const [expandedState, setExpandedState] = useState(() => ({ paths: new Set(changedFileDirectoryPaths(tree)), signature: directorySignature }))
  let expandedPaths = expandedState.paths
  if (expandedState.signature !== directorySignature) {
    expandedPaths = new Set(changedFileDirectoryPaths(tree))
    setExpandedState({ paths: expandedPaths, signature: directorySignature })
  }

  function toggleDirectory(path: string) {
    setExpandedState((current) => {
      const paths = new Set(current.paths)
      if (paths.has(path)) paths.delete(path)
      else paths.add(path)
      return { paths, signature: current.signature }
    })
  }

  return (
    <>
      {tree.map((node) => (
        <ChangedFileTreeRow
          commentCounts={commentCounts}
          density={density}
          expandedPaths={expandedPaths}
          key={node.path}
          node={node}
          onSelectFile={onSelectFile}
          onToggleDirectory={toggleDirectory}
          selectedPath={selectedPath}
        />
      ))}
    </>
  )
}

function ChangedFileTreeRow({
  commentCounts,
  density,
  expandedPaths,
  node,
  onSelectFile,
  onToggleDirectory,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  density: ReviewDiffSettings["density"]
  expandedPaths: Set<string>
  node: ChangedFileTreeNode
  onSelectFile: (path: string) => void
  onToggleDirectory: (path: string) => void
  selectedPath?: string | null
}) {
  if (node.file) {
    const file = node.file
    return (
      <button
        className={`flex w-full items-center text-left hover:bg-brand/10 ${DIFF_DENSITY_CLASSES[density].changedFilesRow} ${selectedPath === file.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
        onClick={() => onSelectFile(file.path)}
        style={{ paddingLeft: `${0.75 + Math.min(file.path.split("/").length - 1, 6) * 0.75}rem` }}
        title={`${file.path} (+${file.additions ?? 0} -${file.deletions ?? 0})`}
        type="button"
      >
        <span className="min-w-0 flex-1 truncate">{node.name}</span>
        <GeneratedFileBadge file={file} />
        {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions}</span> : null}
        {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions}</span> : null}
        {commentCounts?.[file.path] ? (
          <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">
            {commentCounts[file.path]}
          </span>
        ) : null}
      </button>
    )
  }

  return (
    <>
      <button
        aria-expanded={expandedPaths.has(node.path)}
        aria-label={node.name}
        className={`block w-full truncate text-left font-mono text-xs font-semibold text-gray-500 hover:bg-brand/10 dark:text-gray-400 ${DIFF_DENSITY_CLASSES[density].changedFilesRow}`}
        onClick={() => onToggleDirectory(node.path)}
        style={{ paddingLeft: `${0.75 + Math.min(Math.max(node.path.split("/").length - 1, 0), 6) * 0.75}rem` }}
        title={node.path}
        type="button"
      >
        <span
          aria-hidden="true"
          className={`mr-1 inline-block w-3 text-gray-400 transition-transform dark:text-gray-500 ${expandedPaths.has(node.path) ? "rotate-90" : ""}`}
        >
          {">"}
        </span>
        {node.name}
      </button>
      {expandedPaths.has(node.path)
        ? node.children.map((child) => (
            <ChangedFileTreeRow
              commentCounts={commentCounts}
              density={density}
              expandedPaths={expandedPaths}
              key={child.path}
              node={child}
              onSelectFile={onSelectFile}
              onToggleDirectory={onToggleDirectory}
              selectedPath={selectedPath}
            />
          ))
        : null}
    </>
  )
}

function buildChangedFileTree(files: ReviewableDiffFile[]) {
  const root: ChangedFileTreeNode = { children: [], file: null, name: "", path: "" }
  const directories = new Map<string, ChangedFileTreeNode>([["", root]])

  for (const file of files) {
    const parts = file.path.split("/").filter(Boolean)
    let parent = root
    let currentPath = ""

    parts.forEach((part, index) => {
      currentPath = currentPath ? `${currentPath}/${part}` : part
      let node = index === parts.length - 1 ? undefined : directories.get(currentPath)

      if (!node) {
        node = { children: [], file: null, name: part, path: currentPath }
        if (index < parts.length - 1) directories.set(currentPath, node)
        parent.children.push(node)
      }

      if (index === parts.length - 1) node.file = file
      parent = node
    })
  }

  return root.children
}

function changedFileDirectoryPaths(nodes: ChangedFileTreeNode[]) {
  const paths: string[] = []
  for (const node of nodes) {
    if (!node.file) {
      paths.push(node.path)
      paths.push(...changedFileDirectoryPaths(node.children))
    }
  }
  return paths
}

type HunkContextControl = { lineCount: number; loading: boolean; onClick: () => void }
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
  composingDiscussError,
  composingDiscussPending,
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
  onDiscussComposing,
  onLoadFileContext,
  onSaveComposing,
  onSaveEditThread,
  onStartEditThread,
  onToggleFilesPopup,
  onToggleHighlightToken,
  renderImageDiff,
  reviewSettings,
  reviewAnnotations,
  diffLineMetricProviders,
  reviewAnnotationRanges,
  highlightedReviewAnnotationId,
  selected,
  showFilesPopupTrigger,
  showHeader,
  unavailableState
}: {
  annotations?: Record<string, LineAnnotation>
  cache: Map<string, FileCacheEntry>
  comments?: Record<string, DiffReviewThread[]>
  composingBody?: string
  composingDiscussError?: Error | null
  composingDiscussPending?: boolean
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
  onDiscussComposing?: () => void
  onLoadFileContext?: (file: ReviewableDiffFile) => Promise<string | null>
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  onToggleFilesPopup?: (event: MouseEvent<HTMLButtonElement>) => void
  onToggleHighlightToken?: (token: string) => void
  renderImageDiff?: (file: ReviewableDiffFile) => ReactNode
  reviewSettings: ReviewDiffSettings
  reviewAnnotations?: Record<string, DiffReviewAnnotation[]>
  diffLineMetricProviders?: DiffLineMetricProvider[]
  reviewAnnotationRanges?: DiffReviewAnnotationRange[]
  highlightedReviewAnnotationId?: string | null
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
  const collapsed = cacheEntry.collapsed
  const contextState = cacheEntry.contextState
  function setForceLoaded(value: boolean) {
    updateCacheEntry({ forceLoaded: value })
  }
  function setCollapsed(value: boolean) {
    updateCacheEntry({ collapsed: value })
  }
  function setContextState(updater: (prev: FileContextState) => FileContextState) {
    updateCacheEntry({ contextState: updater(cacheEntry.contextState) })
  }

  const gapsMeta = useMemo<ContextGap[]>(() => contextGapsForHunks(hunks, contextState.lines?.length ?? null), [hunks, contextState.lines])
  const reviewAnnotationVisibilitySignature = useMemo(
    () =>
      (reviewAnnotationRanges ?? [])
        .map((range) => `${range.side}:${range.start_line}-${range.end_line}`)
        .sort()
        .join("|"),
    [reviewAnnotationRanges]
  )

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
      const next = Math.min(size - other, current + reviewSettings.context_lines)
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

  useEffect(() => {
    if (
      !contextExpansionEnabled ||
      !reviewAnnotationRanges?.length ||
      contextState.fullyExpanded ||
      contextState.status === "loading" ||
      contextState.status === "error"
    )
      return

    let cancelled = false
    async function revealAnnotationContext() {
      const fileLines = await ensureFileLinesLoaded()
      if (cancelled || !fileLines) return

      const resolvedGaps = contextGapsForHunks(hunks, fileLines.length)
      const forcedGaps = forcedGapStatesForAnnotationRanges(resolvedGaps, reviewAnnotationRanges ?? [], reviewSettings.context_lines)
      if (forcedGaps.every((state) => !state)) return

      setContextState((prev) => ({ ...prev, gaps: mergeGapRevealStates(prev.gaps, forcedGaps) }))
    }

    void revealAnnotationContext()
    return () => {
      cancelled = true
    }
  }, [
    contextExpansionEnabled,
    contextState.fullyExpanded,
    contextState.lines,
    contextState.status,
    hunks,
    reviewAnnotationRanges,
    reviewAnnotationVisibilitySignature,
    reviewSettings.context_lines
  ])

  const hunkControls: HunkControls[] = contextExpansionEnabled
    ? hunks.map((_, hunkIndex) => {
        const upGap = gapsMeta[hunkIndex]
        const downGap = gapsMeta[hunkIndex + 1]
        const loading = contextState.status === "loading"
        const upVisible = !contextState.fullyExpanded && remainingInGap(upGap, contextState.gaps[hunkIndex]) > 0
        const downVisible = !contextState.fullyExpanded && remainingInGap(downGap, contextState.gaps[hunkIndex + 1]) > 0

        return {
          down: downVisible ? { lineCount: reviewSettings.context_lines, loading, onClick: () => expandGap(hunkIndex + 1, "fromTop") } : undefined,
          up: upVisible ? { lineCount: reviewSettings.context_lines, loading, onClick: () => expandGap(hunkIndex, "fromBottom") } : undefined
        }
      })
    : []

  if (collapsed) {
    return showHeader ? (
      <DiffFileHeader
        collapsed
        file={file}
        onToggleCollapsed={() => setCollapsed(false)}
        onToggleFilesPopup={onToggleFilesPopup}
        reviewSettings={reviewSettings}
        selected={selected}
        showFilesPopupTrigger={showFilesPopupTrigger}
      />
    ) : null
  }

  if (file.generated && !forceLoaded) {
    return (
      <>
        {showHeader ? (
          <DiffFileHeader
            file={file}
            onToggleCollapsed={() => setCollapsed(true)}
            onToggleFilesPopup={onToggleFilesPopup}
            reviewSettings={reviewSettings}
            selected={selected}
            showFilesPopupTrigger={showFilesPopupTrigger}
          />
        ) : null}
        <GeneratedFilePlaceholder file={file} onLoad={() => setForceLoaded(true)} />
      </>
    )
  }

  if (rowCount > largeFileRowThreshold && !forceLoaded) {
    return (
      <>
        {showHeader ? (
          <DiffFileHeader
            file={file}
            onToggleCollapsed={() => setCollapsed(true)}
            onToggleFilesPopup={onToggleFilesPopup}
            reviewSettings={reviewSettings}
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
          onToggleCollapsed={() => setCollapsed(true)}
          onToggleFilesPopup={onToggleFilesPopup}
          reviewSettings={reviewSettings}
          selected={selected}
          showFilesPopupTrigger={showFilesPopupTrigger}
        />
      ) : null}
      {file.patch !== null ? (
        <UnifiedDiffTable
          annotations={annotations}
          comments={comments}
          composingBody={composingBody}
          composingDiscussError={composingDiscussError}
          composingDiscussPending={composingDiscussPending}
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
          onDiscussComposing={onDiscussComposing}
          onSaveComposing={onSaveComposing}
          onSaveEditThread={onSaveEditThread}
          onStartEditThread={onStartEditThread}
          onToggleHighlightToken={onToggleHighlightToken}
          reviewSettings={reviewSettings}
          reviewAnnotations={reviewAnnotations}
          diffLineMetricProviders={diffLineMetricProviders}
          reviewAnnotationRanges={reviewAnnotationRanges}
          highlightedReviewAnnotationId={highlightedReviewAnnotationId}
          tokenCache={cacheEntry.tokensByHunk}
        />
      ) : file.is_image && renderImageDiff ? (
        renderImageDiff(file)
      ) : (
        <div className="px-4 py-8 text-center font-sans text-sm text-gray-400 dark:text-gray-500">{unavailableState}</div>
      )}
    </>
  )
}

function LargeFilePlaceholder({ file, onLoad, rowCount }: { file: ReviewableDiffFile; onLoad: () => void; rowCount: number }) {
  const { t } = useT("common")

  return (
    <div className="space-y-2 border-t border-gray-100 px-4 py-6 font-sans text-sm text-gray-600 dark:border-gray-800 dark:text-gray-300">
      <p className="font-mono text-xs text-gray-500 dark:text-gray-400">{file.path}</p>
      <p>
        {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions} </span> : null}
        {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions} </span> : null}
        {t("diff_review.large_file_hidden", { rowCount })}
      </p>
      <Button onClick={onLoad} size="sm" variant="secondary">
        {t("diff_review.load_file_diff")}
      </Button>
    </div>
  )
}

function GeneratedFilePlaceholder({ file, onLoad }: { file: ReviewableDiffFile; onLoad: () => void }) {
  const { t } = useT("common")
  const label = generatedFileLabel(file, t)

  return (
    <div className="space-y-2 border-t border-gray-100 px-4 py-6 font-sans text-sm text-gray-600 dark:border-gray-800 dark:text-gray-300">
      <p className="font-mono text-xs text-gray-500 dark:text-gray-400">{file.path}</p>
      <p>
        {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions} </span> : null}
        {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions} </span> : null}
        {t("diff_review.generated_file_hidden", { label })}
      </p>
      <Button onClick={onLoad} size="sm" variant="secondary">
        {t("diff_review.load_generated_file_diff")}
      </Button>
    </div>
  )
}

function GeneratedFileBadge({ file }: { file: ReviewableDiffFile }) {
  const { t } = useT("common")
  if (!file.generated) return null

  return (
    <span
      className="shrink-0 rounded border border-amber-200 bg-amber-50 px-1.5 py-0.5 font-sans text-2xs font-semibold uppercase text-amber-700 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200"
      title={file.generated_reason || t("diff_review.generated_file")}
    >
      {generatedFileLabel(file, t)}
    </span>
  )
}

function generatedFileLabel(file: ReviewableDiffFile, t: (key: string, options?: Record<string, unknown>) => string) {
  return file.generated_reason?.toLowerCase().includes("lockfile") ? t("diff_review.lockfile_badge") : t("diff_review.generated_badge")
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
// line index: hunk ids are stable across hidden-context expansion. Revealed
// context lines join the adjacent hunk whose syntax state they can borrow,
// while existing hunk body rows keep their original ids; if a hunk's visible
// line count changes, the cache entry is regenerated. The caller may pass a
// cache that outlives this component's own mount -- see FileCacheEntry -- so
// a file that scrolls out of the virtualized window and back doesn't redo
// Shiki work it already paid for.
function useHighlightedDiffLines(
  lines: DiffLine[],
  lang: HighlighterLanguageId | null,
  tokensByHunk: Map<number, ThemedToken[][]>
): (ThemedToken[] | undefined)[] {
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
    const missing = Array.from(hunkLineIndexes.entries()).filter(([hunkId, indexes]) => tokensByHunk.get(hunkId)?.length !== indexes.length)
    if (missing.length === 0) return

    let cancelled = false
    const marker = startMarker("diff_review.syntax_highlight", { maxPerSession: 300 })
    Promise.all(
      missing.map(async ([hunkId, indexes]) => {
        const code = indexes.map((index) => lines[index].code).join("\n")
        const tokens = await tokenizeLines(code, lang)
        return [hunkId, tokens] as const
      })
    )
      .then((results) => {
        if (cancelled) return
        for (const [hunkId, tokens] of results) tokensByHunk.set(hunkId, tokens)
        const tokenSpanCount = results.reduce((sum, [, tokens]) => sum + tokens.reduce((lineSum, lineTokens) => lineSum + lineTokens.length, 0), 0)
        endMarker(marker, { metadata: { hunk_count: missing.length, language: lang, token_span_count: tokenSpanCount } })
        bumpVersion()
      })
      .catch((error: unknown) => {
        // A blocked/failed highlighter load (e.g. CSP-blocked WASM in a
        // browser that hasn't picked up 'wasm-unsafe-eval' yet) must not
        // surface as an unhandled promise rejection -- the diff already
        // renders correctly as plain text without tokens, so this is a
        // silent degrade, not a UI error.
        if (cancelled) return
        endMarker(marker, { metadata: { hunk_count: missing.length, language: lang, error: true } })
        console.warn("Diff syntax highlighting failed; falling back to plain text.", error)
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
  composingDiscussError,
  composingDiscussPending,
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
  onDiscussComposing,
  onSaveComposing,
  onSaveEditThread,
  onStartEditThread,
  onToggleHighlightToken,
  reviewSettings = DEFAULT_REVIEW_DIFF_SETTINGS,
  reviewAnnotations,
  diffLineMetricProviders = [],
  reviewAnnotationRanges,
  highlightedReviewAnnotationId,
  testId,
  tokenCache: tokenCacheProp
}: {
  annotations?: Record<string, LineAnnotation>
  comments?: Record<string, DiffReviewThread[]>
  composingBody?: string
  composingDiscussError?: Error | null
  composingDiscussPending?: boolean
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
  onDiscussComposing?: () => void
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  onToggleHighlightToken?: (token: string) => void
  reviewSettings?: ReviewDiffSettings
  reviewAnnotations?: Record<string, DiffReviewAnnotation[]>
  diffLineMetricProviders?: DiffLineMetricProvider[]
  reviewAnnotationRanges?: DiffReviewAnnotationRange[]
  highlightedReviewAnnotationId?: string | null
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
  const { t } = useT("common")
  const isMobileViewport = useIsMobileViewport()
  const lineWrapping = reviewSettings.line_wrapping
  const lang = reviewSettings.syntax_highlighting ? detectHighlighterLanguage(file.path) : null
  const localTokenCache = useRef<{ patch: string | null; tokens: Map<number, ThemedToken[][]> }>({ patch: file.patch, tokens: new Map() })
  if (localTokenCache.current.patch !== file.patch) localTokenCache.current = { patch: file.patch, tokens: new Map() }
  const tokenCache = tokenCacheProp ?? localTokenCache.current.tokens
  const tokensByLine = useHighlightedDiffLines(lines, lang, tokenCache)
  const [localHighlight, setLocalHighlight] = useState<string | null>(null)
  const activeHighlight = highlightedToken !== undefined ? highlightedToken : localHighlight
  const toggleHighlight = onToggleHighlightToken ?? ((token: string) => setLocalHighlight((current) => (current === token ? null : token)))
  const composingKey = composingSelection ? anchorKeyForLine(composingSelection.line, composingSelection.side) : null
  const hideOldLineGutter = isAddedFileDiff(file)
  const showLineNumbers = reviewSettings.line_numbers
  const splitView = !isMobileViewport && reviewSettings.desktop_view === "split"
  const mobileUnifiedWrap = isMobileViewport && lineWrapping === "wrap"
  const collapseUnifiedGutters = isMobileViewport && showLineNumbers
  const hideSeparateOldLineGutter = hideOldLineGutter || collapseUnifiedGutters
  const gutterColSpan = hideSeparateOldLineGutter ? 1 : 2
  const codeCellClass = diffCodeCellClass(reviewSettings, lineWrapping, splitView, mobileUnifiedWrap)
  const showReviewNotes = hasReviewAnnotations(reviewAnnotations, reviewAnnotationRanges)
  const showMetricGutter = diffLineMetricProviders.length > 0
  const splitInlineRows = splitView

  let hunkIndex = -1

  const scrollClass =
    lineWrapping === "scroll"
      ? "w-full min-w-0 max-w-full overflow-x-scroll overscroll-x-contain [-webkit-overflow-scrolling:touch]"
      : "w-full min-w-0 max-w-full overflow-x-hidden"
  const splitInlineColSpan = (showLineNumbers ? 5 : 3) + (showReviewNotes ? 1 : 0) + (showMetricGutter ? 1 : 0)

  function renderThreadRow(threads: DiffReviewThread[], splitRow: boolean) {
    if (threads.length === 0) return null

    const panel = (
      <div className={`${diffInlineReviewPanelClass(!splitRow && !isMobileViewport, !splitRow && isMobileViewport)} space-y-2 bg-amber-50/70 dark:bg-amber-950/30`}>
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
                  {t("diff_review_composer.edit")}
                </button>
              ) : null}
              {thread.state === "draft" && onDeleteThread && editingThreadId !== thread.id ? (
                <button
                  className="normal-case tracking-normal text-red-700 underline hover:text-red-900 dark:text-red-300 dark:hover:text-red-100"
                  onClick={() => onDeleteThread(thread)}
                  type="button"
                >
                  {t("diff_review_composer.delete")}
                </button>
              ) : null}
            </div>
            {editingThreadId === thread.id ? (
              <div className="space-y-2">
                <textarea
                  aria-label={t("diff_review_composer.edit_comment_aria", { id: thread.id })}
                  className="min-h-20 w-full rounded border border-gray-300 bg-white px-2 py-1 text-sm normal-case tracking-normal text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                  onChange={(event) => onChangeEditingThreadBody?.(event.target.value)}
                  value={editingThreadBody ?? ""}
                />
                <div className="flex gap-2">
                  <Button disabled={!editingThreadBody?.trim()} onClick={onSaveEditThread} size="sm">
                    {t("save")}
                  </Button>
                  <Button onClick={onCancelEditThread} size="sm" variant="secondary">
                    {t("cancel")}
                  </Button>
                </div>
              </div>
            ) : (
              <p className="whitespace-pre-wrap break-words text-sm normal-case tracking-normal text-gray-800 dark:text-gray-200">{thread.body}</p>
            )}
          </div>
        ))}
      </div>
    )

    if (splitRow) {
      return (
        <tr className="bg-amber-50/70 font-sans dark:bg-amber-950/30" data-testid="diff-review-thread">
          <td className={`${diffInlineReviewCellClass(reviewSettings)} text-xs text-amber-950 dark:text-amber-100`} colSpan={splitInlineColSpan}>
            {panel}
          </td>
        </tr>
      )
    }

    return (
      <tr className="bg-amber-50/70 font-sans dark:bg-amber-950/30" data-testid="diff-review-thread">
        {showLineNumbers ? <td className="border-r border-amber-200 dark:border-amber-900" colSpan={gutterColSpan} /> : null}
        <td className={`text-amber-700 dark:text-amber-300 ${diffDensityClasses(reviewSettings).marker}`}>*</td>
        <td
          className={`${diffInlineReviewCellClass(reviewSettings)} text-xs text-amber-950 dark:text-amber-100`}
          colSpan={2 + (showReviewNotes ? 1 : 0) + (showMetricGutter ? 1 : 0)}
        >
          {panel}
        </td>
      </tr>
    )
  }

  function renderComposerRow(isComposingHere: boolean, splitRow: boolean) {
    if (!isComposingHere) return null

    const panel = (
      <div className={`${diffInlineReviewPanelClass(!splitRow && !isMobileViewport, !splitRow && isMobileViewport)} bg-brand/5`}>
        <div className="space-y-2">
          <textarea
            aria-label={t("diff_review_composer.comment")}
            autoFocus
            className="min-h-20 w-full rounded border border-gray-300 bg-white px-2 py-1 text-sm normal-case tracking-normal text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            onChange={(event) => onChangeComposingBody?.(event.target.value)}
            value={composingBody ?? ""}
          />
          <div className="flex gap-2">
            <Button disabled={!composingBody?.trim() || composingPending} onClick={onSaveComposing} size="sm">
              {t("diff_review_composer.create_comment")}
            </Button>
            {onDiscussComposing ? (
              <Button disabled={!composingBody?.trim() || composingDiscussPending} onClick={onDiscussComposing} size="sm" variant="secondary">
                {composingDiscussPending ? t("diff_review_composer.discussing") : t("diff_review_composer.discuss")}
              </Button>
            ) : null}
            <Button onClick={onCancelComposing} size="sm" variant="secondary">
              {t("cancel")}
            </Button>
          </div>
          {composingError ? <p className="text-xs text-red-700 dark:text-red-300">{t("diff_review_composer.create_error")}</p> : null}
          {composingDiscussError ? <p className="text-xs text-danger-text">{t("diff_review_composer.discuss_error")}</p> : null}
        </div>
      </div>
    )

    if (splitRow) {
      return (
        <tr className="font-sans" data-testid="diff-review-composer">
          <td className={diffInlineReviewCellClass(reviewSettings)} colSpan={splitInlineColSpan}>
            {panel}
          </td>
        </tr>
      )
    }

    return (
      <tr className="font-sans" data-testid="diff-review-composer">
        {showLineNumbers ? <td className="border-r border-brand/20" colSpan={gutterColSpan} /> : null}
        <td className={`text-brand ${diffDensityClasses(reviewSettings).marker}`}>*</td>
        <td className={diffInlineReviewCellClass(reviewSettings)} colSpan={2 + (showReviewNotes ? 1 : 0) + (showMetricGutter ? 1 : 0)}>
          {panel}
        </td>
      </tr>
    )
  }

  function renderReviewAnnotationRow(reviewNotes: DiffReviewAnnotation[], splitRow: boolean) {
    if (reviewNotes.length === 0) return null
    const rowToneClass = reviewAnnotationRowToneClass(reviewNotes)
    const panelToneClass = reviewAnnotationPanelToneClass(reviewNotes)

    const panelClass = diffInlineReviewPanelClass(!splitRow && !isMobileViewport, !splitRow && isMobileViewport)
    const panel = (
      <div className={`${panelClass} space-y-3 ${panelToneClass}`}>
        {reviewNotes.map((note, index) => {
          const inlineNote = reviewAnnotationInlineItem(note)
          return (
            <div key={String(note.id ?? index)}>
              {renderPluginReviewAnnotation(inlineNote, reviewAnnotationFallbackPanel(inlineNote), "inline")}
            </div>
          )
        })}
      </div>
    )

    if (splitRow) {
      return (
        <tr className={`font-sans ${rowToneClass}`} data-testid="diff-review-annotation">
          <td className={diffInlineReviewCellClass(reviewSettings)} colSpan={splitInlineColSpan}>
            {panel}
          </td>
        </tr>
      )
    }

    return (
      <tr className={`font-sans ${rowToneClass}`} data-testid="diff-review-annotation">
        {showLineNumbers ? <td className={reviewAnnotationGutterClass(reviewNotes)} colSpan={gutterColSpan} /> : null}
        <td className={`${reviewAnnotationMarkerTextClass(reviewNotes)} ${diffDensityClasses(reviewSettings).marker}`}>*</td>
        <td className={diffInlineReviewCellClass(reviewSettings)} colSpan={2 + (showReviewNotes ? 1 : 0) + (showMetricGutter ? 1 : 0)}>
          {panel}
        </td>
      </tr>
    )
  }

  return (
    <div className={`${scrollClass} [container-type:inline-size]`} data-testid={testId ? `${testId}-scroll` : "diff-file-scroll"}>
      <table
        className={diffTableClass(reviewSettings, splitView, mobileUnifiedWrap)}
        data-review-diff-view={isMobileViewport ? "unified" : reviewSettings.desktop_view}
        style={{ tabSize: reviewSettings.tab_width }}
        data-testid={testId}
      >
        {splitView ? <SplitDiffColGroup showLineNumbers={showLineNumbers} showMetricGutter={showMetricGutter} showReviewNotes={showReviewNotes} /> : null}
        {!splitView && mobileUnifiedWrap ? (
          <UnifiedDiffColGroup showLineNumbers={showLineNumbers} showMetricGutter={showMetricGutter} showReviewNotes={showReviewNotes} />
        ) : null}
        <tbody>
          {lines.map((line, index) => {
            if (line.kind === "hunk") {
              hunkIndex += 1
              const controls = hunkControls?.[hunkIndex]
              if (controls && !controls.up && !controls.down) return null
              return (
                <HunkRow
                  controls={controls}
                  hideOldLineGutter={hideSeparateOldLineGutter}
                  key={`${index}-hunk-${line.hunkNewStart ?? ""}`}
                  line={line}
                  mobileUnifiedWrap={mobileUnifiedWrap}
                  reviewSettings={reviewSettings}
                  showLineNumbers={showLineNumbers}
                  showMetricGutter={showMetricGutter}
                  showReviewNotes={showReviewNotes}
                  splitView={splitView}
                />
              )
            }

            const annotation = line.newLine != null ? annotations?.[String(line.newLine)] : undefined
            const reviewNotes = reviewNotesForLine(line, reviewAnnotations, reviewAnnotationRanges)
            const inlineReviewNotes = inlineReviewNotesForLine(line, reviewAnnotations, reviewAnnotationRanges)
            const lineMetrics = metricsForLine(diffLineMetricProviders, { file, line, reviewNotes })
            const reviewNoteIdsForLine = reviewNoteIds(reviewNotes)
            const reviewNoteRowClass = reviewAnnotationRowToneClass(reviewNotes)
            const highlightedReviewNote = Boolean(highlightedReviewAnnotationId && reviewNoteIdsForLine.includes(highlightedReviewAnnotationId))
            const highlightedGutterClass = highlightedReviewNote ? reviewAnnotationHighlightClass(reviewNotes) : ""
            const commentSide = line.newLine != null ? "new" : line.oldLine != null ? "old" : null
            const canComment = Boolean(onCommentLine && commentSide)
            const commentSelection: DiffLineSelection | null = canComment && commentSide ? { file, line, side: commentSide } : null
            const lineAnchorKey = commentSide ? anchorKeyForLine(line, commentSide) : null
            const threads = lineAnchorKey ? comments?.[lineAnchorKey] || [] : []
            const isComposingHere = Boolean(lineAnchorKey && composingKey && composingKey === lineAnchorKey)
            const visibleLineNumber = collapseUnifiedGutters ? (line.newLine ?? line.oldLine ?? "") : (line.newLine ?? "")
            const visibleLineNumberCommentSide = collapseUnifiedGutters ? commentSide : commentSide === "new" ? "new" : null
            if (splitView && isDiffCodeLine(line.kind)) {
              return (
                <Fragment key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
                  <SplitDiffRow
                    annotation={annotation}
                    canComment={canComment}
                    codeCellClass={codeCellClass}
                    file={file}
                    highlightedToken={activeHighlight}
                    line={line}
                    lineAnchorKey={lineAnchorKey}
                    onCommentLine={onCommentLine}
                    onToggleHighlightToken={toggleHighlight}
                    reviewSettings={reviewSettings}
                    lineMetrics={lineMetrics}
                    reviewNotes={reviewNotes}
                    reviewNoteIds={reviewNoteIdsForLine}
                    reviewNoteRowClass={reviewNoteRowClass}
                    highlightedGutterClass={highlightedGutterClass}
                    showReviewNotes={showReviewNotes}
                    showMetricGutter={showMetricGutter}
                    showLineNumbers={showLineNumbers}
                    tokens={reviewSettings.visible_whitespace ? undefined : tokensByLine[index]}
                  />
                  {renderReviewAnnotationRow(inlineReviewNotes, true)}
                  {renderThreadRow(threads, true)}
                  {renderComposerRow(isComposingHere, true)}
                </Fragment>
              )
            }
            if (splitView) {
              return (
                <Fragment key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
                  <tr className={`group ${diffLineClass(line.kind)} ${reviewNoteRowClass}`} data-diff-kind={line.kind}>
                    <td
                      className={`overflow-hidden whitespace-pre text-text-primary ${diffDensityClasses(reviewSettings).codeCell}`}
                      colSpan={splitInlineColSpan}
                    >
                      <DiffCode
                        code={reviewDisplayCode(line.code, reviewSettings)}
                        highlightedToken={activeHighlight}
                        kind={line.kind}
                        onToggleHighlightToken={toggleHighlight}
                        tokens={reviewSettings.visible_whitespace ? undefined : tokensByLine[index]}
                      />
                    </td>
                  </tr>
                  {renderReviewAnnotationRow(inlineReviewNotes, true)}
                  {renderThreadRow(threads, true)}
                  {renderComposerRow(isComposingHere, true)}
                </Fragment>
              )
            }
            return (
              <Fragment key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
                <tr
                  className={`group ${diffLineClass(line.kind)} ${reviewNoteRowClass}`}
                  data-coverage={annotation}
                  data-diff-anchor={lineAnchorKey || undefined}
                  data-diff-kind={line.kind}
                  data-diff-review-annotation-ids={reviewNoteIdsForLine.length > 0 ? reviewNoteIdsForLine.join(" ") : undefined}
                >
                  {hideSeparateOldLineGutter || !showLineNumbers ? null : (
                    <td className={`relative ${diffGutterClass(line.kind)} ${diffDensityClasses(reviewSettings).gutter} ${highlightedGutterClass}`}>
                      {commentSide === "old" && canComment ? (
                        <GutterCommentButton
                          file={file}
                          line={line}
                          lineNumber={line.oldLine ?? ""}
                          reviewSettings={reviewSettings}
                          onCommentLine={onCommentLine}
                          side="old"
                        />
                      ) : (
                        (line.oldLine ?? "")
                      )}
                    </td>
                  )}
                  {showLineNumbers ? (
                    <td className={`relative ${diffGutterClass(line.kind)} ${diffDensityClasses(reviewSettings).gutter} ${highlightedGutterClass}`}>
                      {visibleLineNumberCommentSide && canComment ? (
                        <GutterCommentButton
                          file={file}
                          line={line}
                          lineNumber={visibleLineNumber}
                          reviewSettings={reviewSettings}
                          onCommentLine={onCommentLine}
                          side={visibleLineNumberCommentSide}
                        />
                      ) : (
                        visibleLineNumber
                      )}
                    </td>
                  ) : null}
                  <td className={`${diffMarkerClass(line.kind)} ${diffDensityClasses(reviewSettings).marker}`}>{line.marker}</td>
                  {/* eslint-disable-next-line design-system/no-raw-table-classes */}
                  <td className={`${codeCellClass} ${diffCoverageBorderClass(annotation)}`}>
                    <DiffCode
                      code={reviewDisplayCode(line.code, reviewSettings)}
                      highlightedToken={activeHighlight}
                      kind={line.kind}
                      onToggleHighlightToken={toggleHighlight}
                      tokens={reviewSettings.visible_whitespace ? undefined : tokensByLine[index]}
                    />
                  </td>
                  {/* eslint-disable-next-line design-system/no-raw-table-classes */}
                  <td className={`w-4 select-none text-center ${diffDensityClasses(reviewSettings).marker}`}>
                    {annotation === "covered" ? (
                      <span className="text-emerald-600 dark:text-emerald-400">✓</span>
                    ) : annotation === "uncovered" ? (
                      <span className="text-red-600 dark:text-red-400">✗</span>
                    ) : null}
                  </td>
                  {showReviewNotes ? <ReviewNotesCell reviewNotes={reviewNotes} reviewSettings={reviewSettings} /> : null}
                  {showMetricGutter ? <MetricGutterCell metrics={lineMetrics} reviewSettings={reviewSettings} /> : null}
                </tr>
                {renderReviewAnnotationRow(inlineReviewNotes, false)}
                {renderThreadRow(threads, splitInlineRows)}
                {renderComposerRow(isComposingHere, splitInlineRows)}
              </Fragment>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function isAddedFileDiff(file: ReviewableDiffFile) {
  return file.status === "added" || Boolean(file.patch && /^new file mode /m.test(file.patch))
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
  if (!highlightable || !code) return <>{tokens ? renderCodeLine(tokens, code || " ") : code || " "}</>

  if (tokens) {
    return (
      <>
        {tokens.map((shikiToken, tokenIndex) => (
          <Fragment key={tokenIndex}>
            {tokenizeCode(shikiToken.content).map((word, wordIndex) =>
              word.highlightable ? (
                <span
                  className={`cursor-pointer rounded-sm ${highlightedToken === word.text ? "bg-warning-surface text-warning-text" : "hover:bg-warning-surface"}`}
                  data-diff-highlight-token
                  key={wordIndex}
                  onClick={() => onToggleHighlightToken(word.text)}
                  style={{ color: shikiToken.color }}
                >
                  {word.text}
                </span>
              ) : (
                <span key={wordIndex} style={{ color: shikiToken.color }}>
                  {word.text}
                </span>
              )
            )}
          </Fragment>
        ))}
      </>
    )
  }

  const wordTokens = tokenizeCode(code)
  return (
    <>
      {wordTokens.map((token, index) =>
        token.highlightable ? (
          <span
            className={`cursor-pointer rounded-sm ${highlightedToken === token.text ? "bg-warning-surface text-warning-text" : "hover:bg-warning-surface"}`}
            data-diff-highlight-token
            key={index}
            onClick={() => onToggleHighlightToken(token.text)}
          >
            {token.text}
          </span>
        ) : (
          <span key={index}>{token.text}</span>
        )
      )}
    </>
  )
}

/* eslint-disable design-system/no-raw-table-classes */
function SplitDiffRow({
  annotation,
  canComment,
  codeCellClass,
  file,
  highlightedToken,
  lineMetrics,
  line,
  lineAnchorKey,
  onCommentLine,
  onToggleHighlightToken,
  reviewSettings,
  reviewNotes,
  reviewNoteIds,
  reviewNoteRowClass,
  highlightedGutterClass,
  showMetricGutter,
  showReviewNotes,
  showLineNumbers,
  tokens
}: {
  annotation?: LineAnnotation
  canComment: boolean
  codeCellClass: string
  file: ReviewableDiffFile
  highlightedToken?: string | null
  lineMetrics: DiffLineMetric[]
  line: DiffLine
  lineAnchorKey?: string | null
  onCommentLine?: (selection: DiffLineSelection) => void
  onToggleHighlightToken: (token: string) => void
  reviewSettings: ReviewDiffSettings
  reviewNotes?: DiffReviewAnnotation[]
  reviewNoteIds: string[]
  reviewNoteRowClass: string
  highlightedGutterClass: string
  showMetricGutter: boolean
  showReviewNotes: boolean
  showLineNumbers: boolean
  tokens?: ThemedToken[]
}) {
  const oldCode = line.kind === "delete" || line.kind === "context" ? reviewDisplayCode(line.code, reviewSettings) : ""
  const newCode = line.kind === "add" || line.kind === "context" ? reviewDisplayCode(line.code, reviewSettings) : ""

  return (
    <tr
      className={`group ${diffLineClass(line.kind)} ${reviewNoteRowClass}`}
      data-coverage={annotation}
      data-diff-anchor={lineAnchorKey || undefined}
      data-diff-kind={line.kind}
      data-diff-review-annotation-ids={reviewNoteIds.length > 0 ? reviewNoteIds.join(" ") : undefined}
      data-diff-split-row="true"
    >
      {showLineNumbers ? (
        <td className={`relative ${diffGutterClass(line.kind)} ${diffDensityClasses(reviewSettings).gutter} ${highlightedGutterClass}`}>
          {line.kind === "delete" && canComment ? (
            <GutterCommentButton
              file={file}
              line={line}
              lineNumber={line.oldLine ?? ""}
              reviewSettings={reviewSettings}
              onCommentLine={onCommentLine}
              side="old"
            />
          ) : (
            (line.oldLine ?? "")
          )}
        </td>
      ) : null}
      <td className={`${codeCellClass} ${line.kind === "delete" ? diffCoverageBorderClass(annotation) : ""}`} data-diff-split-side="old">
        {oldCode ? (
          <DiffCode code={oldCode} highlightedToken={highlightedToken} kind={line.kind} onToggleHighlightToken={onToggleHighlightToken} tokens={tokens} />
        ) : null}
      </td>
      {showLineNumbers ? (
        <td className={`relative ${diffGutterClass(line.kind)} ${diffDensityClasses(reviewSettings).gutter} ${highlightedGutterClass}`}>
          {line.kind === "add" && canComment ? (
            <GutterCommentButton
              file={file}
              line={line}
              lineNumber={line.newLine ?? ""}
              reviewSettings={reviewSettings}
              onCommentLine={onCommentLine}
              side="new"
            />
          ) : (
            (line.newLine ?? "")
          )}
        </td>
      ) : null}
      <td className={`${codeCellClass} ${line.kind !== "delete" ? diffCoverageBorderClass(annotation) : ""}`} data-diff-split-side="new">
        {newCode ? (
          <DiffCode code={newCode} highlightedToken={highlightedToken} kind={line.kind} onToggleHighlightToken={onToggleHighlightToken} tokens={tokens} />
        ) : null}
      </td>
      <td className={`w-4 select-none text-center ${diffDensityClasses(reviewSettings).marker}`}>
        {annotation === "covered" ? (
          <span className="text-success-text">✓</span>
        ) : annotation === "uncovered" ? (
          <span className="text-danger-text">✗</span>
        ) : null}
      </td>
      {showReviewNotes ? <ReviewNotesCell reviewNotes={reviewNotes ?? []} reviewSettings={reviewSettings} /> : null}
      {showMetricGutter ? <MetricGutterCell metrics={lineMetrics} reviewSettings={reviewSettings} /> : null}
    </tr>
  )
}

function MetricGutterCell({ metrics, reviewSettings }: { metrics: DiffLineMetric[]; reviewSettings: ReviewDiffSettings }) {
  return (
    <td
      className={`sticky right-0 z-[2] w-5 min-w-5 select-none border-l border-border bg-inherit text-center shadow-[-1px_0_0_var(--color-border)] ${diffDensityClasses(reviewSettings).marker}`}
      data-diff-metric-gutter="true"
      data-diff-metric-ids={metrics.map((metric) => metric.id).join(" ") || undefined}
      data-testid="diff-metric-gutter-cell"
    >
      {metrics.length > 0 ? (
        <div className="flex h-full min-h-4 items-stretch justify-center gap-px" role="list">
          {metrics.map((metric) => (
            <span
              aria-label={metric.title || metric.label}
              className={`block min-h-4 w-1.5 rounded-sm outline-none ring-offset-1 focus:ring-2 focus:ring-brand ${metricToneClass(metric.tone)}`}
              data-diff-metric-id={metric.id}
              data-diff-review-annotation-ids={metric.annotationIds?.length ? metric.annotationIds.join(" ") : undefined}
              key={metric.id}
              role="listitem"
              tabIndex={0}
              title={metric.title || metric.label}
            />
          ))}
        </div>
      ) : null}
    </td>
  )
}

function ReviewNotesCell({ reviewNotes, reviewSettings }: { reviewNotes: DiffReviewAnnotation[]; reviewSettings: ReviewDiffSettings }) {
  if (reviewNotes.length === 0) return <td className={`w-4 select-none ${diffDensityClasses(reviewSettings).marker}`} />

  const title = reviewNotes
    .map((note) => note.title || note.body)
    .filter(Boolean)
    .join("\n")
  return (
    <td
      className={`w-4 select-none text-center ${diffDensityClasses(reviewSettings).marker}`}
      data-diff-review-annotation-ids={reviewNoteIds(reviewNotes).join(" ")}
    >
      {reviewNotes.length === 1
        ? renderPluginReviewAnnotation(reviewAnnotationMarkerItem(reviewNotes[0]!), reviewNotesFallbackMarker(1, title, reviewNotes), "marker")
        : reviewNotesFallbackMarker(reviewNotes.length, title, reviewNotes)}
    </td>
  )
}

function reviewAnnotationMarkerItem(note: DiffReviewAnnotation) {
  return note.marker_component ? { ...note, component: note.marker_component } : note
}

function reviewAnnotationInlineItem(note: DiffReviewAnnotation) {
  return note.inline_component ? { ...note, component: note.inline_component } : note
}

function reviewAnnotationFallbackPanel(note: DiffReviewAnnotation) {
  return (
    <div className={`rounded border p-3 text-sm ${reviewAnnotationToneClass(note.tone)}`}>
      {note.title ? <div className="font-medium">{note.title}</div> : null}
      {note.body ? <Markdown className="mt-1 text-text-secondary" text={note.body} /> : null}
    </div>
  )
}

function reviewAnnotationToneClass(tone: string | null | undefined) {
  if (tone === "danger") return "border-danger-border bg-danger-bg text-danger-text"
  if (tone === "warning") return "border-warning-border bg-warning-bg text-warning-text"
  if (tone === "success") return "border-success-border bg-success-bg text-success-text"
  if (tone === "info") return "border-info-border bg-info-bg text-info-text"
  return "border-border bg-surface text-text-primary"
}

function reviewAnnotationHasWarning(reviewNotes: DiffReviewAnnotation[]) {
  return reviewNotes.some((note) => note.tone == null || note.tone === "warning")
}

function reviewAnnotationHasSuccess(reviewNotes: DiffReviewAnnotation[]) {
  return reviewNotes.some((note) => note.tone === "success")
}

function reviewAnnotationRowToneClass(reviewNotes: DiffReviewAnnotation[]) {
  if (reviewNotes.length === 0) return ""
  if (reviewAnnotationHasWarning(reviewNotes)) return "bg-warning-bg/35 dark:bg-warning-bg/20"
  if (reviewAnnotationHasSuccess(reviewNotes)) return "bg-success-bg/30 dark:bg-success-bg/15"

  return "bg-surface-raised"
}

function reviewAnnotationPanelToneClass(reviewNotes: DiffReviewAnnotation[]) {
  if (reviewAnnotationHasWarning(reviewNotes)) return "bg-warning-bg/55 dark:bg-warning-bg/25"
  if (reviewAnnotationHasSuccess(reviewNotes)) return "bg-success-bg/45 dark:bg-success-bg/20"

  return "bg-surface-raised"
}

function reviewAnnotationGutterClass(reviewNotes: DiffReviewAnnotation[]) {
  if (reviewAnnotationHasWarning(reviewNotes)) return "border-r border-warning-border/60"
  if (reviewAnnotationHasSuccess(reviewNotes)) return "border-r border-success-border/60"

  return "border-r border-border"
}

function reviewAnnotationMarkerTextClass(reviewNotes: DiffReviewAnnotation[]) {
  if (reviewAnnotationHasWarning(reviewNotes)) return "text-warning-text"
  if (reviewAnnotationHasSuccess(reviewNotes)) return "text-success-text"

  return "text-text-secondary"
}

function reviewAnnotationHighlightClass(reviewNotes: DiffReviewAnnotation[]) {
  if (reviewAnnotationHasWarning(reviewNotes)) return "ring-2 ring-inset ring-warning-border bg-warning-bg text-warning-text"
  if (reviewAnnotationHasSuccess(reviewNotes)) return "ring-2 ring-inset ring-success-border bg-success-bg text-success-text"

  return "ring-2 ring-inset ring-border bg-surface-raised text-text-primary"
}

function reviewNoteIds(reviewNotes: DiffReviewAnnotation[]) {
  return reviewNotes
    .map((note) => note.id)
    .filter((id): id is string | number => id !== undefined && id !== null)
    .map(String)
}

function metricsForLine(providers: DiffLineMetricProvider[], context: DiffLineMetricContext) {
  if (!isDiffCodeLine(context.line.kind)) return []
  return providers.map((provider) => provider.metricForLine(context)).filter((metric): metric is DiffLineMetric => Boolean(metric))
}

export function diffLineMetricProvidersForReview(
  counts: DiffReviewAnnotationCount[] | null | undefined,
  t: (key: string, options?: Record<string, unknown>) => string,
  providers: DiffLineMetricProvider[] | null | undefined = []
) {
  return uniqueDiffLineMetricProviders([...cognitiveReviewRiskMetricProviders(counts, t), ...(providers ?? [])])
}

function uniqueDiffLineMetricProviders(providers: DiffLineMetricProvider[]) {
  const seen = new Set<string>()
  return providers.filter((provider) => {
    if (seen.has(provider.id)) return false

    seen.add(provider.id)
    return true
  })
}

function cognitiveReviewRiskMetricProviders(
  counts: DiffReviewAnnotationCount[] | null | undefined,
  t: (key: string, options?: Record<string, unknown>) => string
) {
  const hasCognitiveReviewDebtData = (counts ?? []).some((count) => String(count.id ?? "").startsWith("cognitive_review."))
  if (!hasCognitiveReviewDebtData) return []

  const provider: DiffLineMetricProvider = {
    id: "cognitive_review.risk",
    label: t("diff_review.metrics.cognitive_review_risk"),
    metricForLine: ({ reviewNotes }) => {
      const cognitiveReviewNoteIds = reviewNoteIds(reviewNotes.filter((note) => note.tone == null || note.tone === "warning")).filter((id) =>
        id.startsWith("cognitive_review_note:")
      )
      const hasOpenRisk = cognitiveReviewNoteIds.length > 0
      return {
        id: "cognitive_review.risk",
        label: t("diff_review.metrics.cognitive_review_risk"),
        tone: hasOpenRisk ? "risk" : "clear",
        title: hasOpenRisk
          ? t("diff_review.metrics.cognitive_review_risk_open", { count: cognitiveReviewNoteIds.length })
          : t("diff_review.metrics.cognitive_review_risk_clear"),
        annotationIds: cognitiveReviewNoteIds
      }
    }
  }
  return [provider]
}

function metricToneClass(tone: DiffLineMetricTone) {
  const classes: Record<DiffLineMetricTone, string> = {
    clear: "bg-info",
    danger: "bg-danger",
    info: "bg-info",
    neutral: "bg-border-strong",
    risk: "bg-danger",
    success: "bg-success",
    warning: "bg-warning"
  }
  return classes[tone]
}

function reviewNotesFallbackMarker(count: number, title: string, reviewNotes: DiffReviewAnnotation[] = []) {
  return (
    <span
      className={`inline-flex min-h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] font-semibold ring-1 ring-inset ${reviewAnnotationFallbackMarkerClass(reviewNotes)}`}
      data-diff-review-annotation-marker="true"
      title={title || undefined}
    >
      {count}
    </span>
  )
}

function reviewAnnotationFallbackMarkerClass(reviewNotes: DiffReviewAnnotation[]) {
  if (reviewAnnotationHasWarning(reviewNotes)) return "bg-warning-bg text-warning-text ring-warning-border"
  if (reviewAnnotationHasSuccess(reviewNotes)) return "bg-success-bg text-success-text ring-success-border"

  return "bg-surface-raised text-text-secondary ring-border"
}

function diffTableClass(settings: ReviewDiffSettings, splitView = false, mobileUnifiedWrap = false) {
  const layoutClass = splitView || mobileUnifiedWrap ? "w-full table-fixed" : "min-w-full"
  return `${layoutClass} border-separate border-spacing-0 font-mono ${diffDensityClasses(settings).tableText}`
}

function diffCodeCellClass(settings: ReviewDiffSettings, lineWrapping: ReviewDiffSettings["line_wrapping"], splitView = false, mobileUnifiedWrap = false) {
  const constrainedWrap = splitView || mobileUnifiedWrap
  const wrapClass =
    lineWrapping === "wrap"
      ? `${constrainedWrap ? "max-w-0 overflow-hidden" : ""} min-w-0 whitespace-pre-wrap break-words [&_span]:break-words`
      : splitView
        ? "min-w-0 overflow-hidden whitespace-pre"
        : "min-w-[40rem] whitespace-pre"
  return `${wrapClass} ${diffDensityClasses(settings).codeCell} text-text-primary`
}

function diffDensityClasses(settings: ReviewDiffSettings) {
  return DIFF_DENSITY_CLASSES[settings.density]
}

function diffInlineReviewCellClass(settings: ReviewDiffSettings) {
  return `w-[min(44rem,calc(100vw-3rem))] max-w-[calc(100vw-3rem)] align-top max-md:w-auto max-md:max-w-none max-md:p-0 ${diffDensityClasses(settings).inlineReviewCell}`
}

function diffInlineReviewPanelClass(sticky: boolean, mobileCodeColumn = false) {
  if (mobileCodeColumn) return DIFF_INLINE_REVIEW_PANEL_MOBILE_CODE_COLUMN_CLASS
  return sticky ? DIFF_INLINE_REVIEW_PANEL_STICKY_CLASS : DIFF_INLINE_REVIEW_PANEL_BASE_CLASS
}

function reviewDisplayCode(code: string, settings: ReviewDiffSettings) {
  const normalizedCode = settings.whitespace === "trim_trailing" ? code.replace(/[ \t]+$/u, "") : code
  if (!settings.visible_whitespace) return normalizedCode

  return normalizedCode.replace(/\t/gu, "→\t").replace(/ /gu, "·")
}

function hasReviewAnnotations(
  reviewAnnotations: Record<string, DiffReviewAnnotation[]> | undefined,
  reviewAnnotationRanges: DiffReviewAnnotationRange[] | undefined
) {
  return Object.values(reviewAnnotations ?? {}).some((notes) => notes.length > 0) || Boolean(reviewAnnotationRanges?.length)
}

function reviewNotesForLine(
  line: DiffLine,
  reviewAnnotations: Record<string, DiffReviewAnnotation[]> | undefined,
  reviewAnnotationRanges: DiffReviewAnnotationRange[] | undefined
) {
  const legacyNotes = line.newLine != null ? (reviewAnnotations?.[String(line.newLine)] ?? []) : []
  const rangeNotes = (reviewAnnotationRanges ?? []).filter((note) => rangeAnnotationMatchesLine(note, line))
  return legacyNotes.concat(rangeNotes)
}

function inlineReviewNotesForLine(
  line: DiffLine,
  reviewAnnotations: Record<string, DiffReviewAnnotation[]> | undefined,
  reviewAnnotationRanges: DiffReviewAnnotationRange[] | undefined
) {
  const legacyNotes = line.newLine != null ? (reviewAnnotations?.[String(line.newLine)] ?? []) : []
  const rangeNotes = (reviewAnnotationRanges ?? []).filter((note) => rangeAnnotationEndsOnLine(note, line))
  return legacyNotes.concat(rangeNotes)
}

function rangeAnnotationMatchesLine(note: DiffReviewAnnotationRange, line: DiffLine) {
  const lineNumber = note.side === "old" ? line.oldLine : line.newLine
  return lineNumber != null && lineNumber >= note.start_line && lineNumber <= note.end_line
}

function rangeAnnotationEndsOnLine(note: DiffReviewAnnotationRange, line: DiffLine) {
  const lineNumber = note.side === "old" ? line.oldLine : line.newLine
  return lineNumber === note.end_line
}

function SplitDiffColGroup({
  showLineNumbers,
  showMetricGutter,
  showReviewNotes
}: {
  showLineNumbers: boolean
  showMetricGutter: boolean
  showReviewNotes: boolean
}) {
  const fixedColumnsRem = 1.5 + (showReviewNotes ? 1.5 : 0) + (showMetricGutter ? 1.25 : 0)
  if (!showLineNumbers) {
    return (
      <colgroup>
        <col style={{ width: `calc((100% - ${fixedColumnsRem}rem) / 2)` }} />
        <col style={{ width: `calc((100% - ${fixedColumnsRem}rem) / 2)` }} />
        <col style={{ width: "1.5rem" }} />
        {showReviewNotes ? <col style={{ width: "1.5rem" }} /> : null}
        {showMetricGutter ? <col style={{ width: "1.25rem" }} /> : null}
      </colgroup>
    )
  }

  const codeWidth = `calc((100% - ${fixedColumnsRem + 6}rem) / 2)`
  return (
    <colgroup>
      <col style={{ width: "3rem" }} />
      <col style={{ width: codeWidth }} />
      <col style={{ width: "3rem" }} />
      <col style={{ width: codeWidth }} />
      <col style={{ width: "1.5rem" }} />
      {showReviewNotes ? <col style={{ width: "1.5rem" }} /> : null}
      {showMetricGutter ? <col style={{ width: "1.25rem" }} /> : null}
    </colgroup>
  )
}

function UnifiedDiffColGroup({
  showLineNumbers,
  showMetricGutter,
  showReviewNotes
}: {
  showLineNumbers: boolean
  showMetricGutter: boolean
  showReviewNotes: boolean
}) {
  if (!showLineNumbers) {
    return (
      <colgroup>
        <col style={{ width: "1.5rem" }} />
        <col />
        <col style={{ width: "1.5rem" }} />
        {showReviewNotes ? <col style={{ width: "1.5rem" }} /> : null}
        {showMetricGutter ? <col style={{ width: "1.25rem" }} /> : null}
      </colgroup>
    )
  }

  return (
    <colgroup>
      <col style={{ width: "3rem" }} />
      <col style={{ width: "1.5rem" }} />
      <col />
      <col style={{ width: "1.5rem" }} />
      {showReviewNotes ? <col style={{ width: "1.5rem" }} /> : null}
      {showMetricGutter ? <col style={{ width: "1.25rem" }} /> : null}
    </colgroup>
  )
}

function HunkRow({
  controls,
  hideOldLineGutter,
  line,
  mobileUnifiedWrap = false,
  reviewSettings,
  showMetricGutter = false,
  showLineNumbers = true,
  showReviewNotes = false,
  splitView = false
}: {
  controls?: HunkControls
  hideOldLineGutter?: boolean
  line: DiffLine
  mobileUnifiedWrap?: boolean
  reviewSettings: ReviewDiffSettings
  showMetricGutter?: boolean
  showLineNumbers?: boolean
  showReviewNotes?: boolean
  splitView?: boolean
}) {
  if (splitView) {
    const codeColSpan = showLineNumbers ? 3 : 2
    return (
      <tr className={`group ${diffLineClass("hunk")}`} data-diff-kind="hunk">
        {showLineNumbers ? (
          <td className={`${diffGutterClass("hunk")} ${diffDensityClasses(reviewSettings).gutter}`}>
            {controls?.up ? (
              <HunkContextButton direction="up" lineCount={controls.up.lineCount} loading={controls.up.loading} onClick={controls.up.onClick} />
            ) : null}
          </td>
        ) : null}
        <td className={`overflow-hidden whitespace-pre text-text-primary ${diffDensityClasses(reviewSettings).hunkCodeCell}`} colSpan={codeColSpan}>
          {line.code}
        </td>
        <td className={`w-4 select-none text-center ${diffDensityClasses(reviewSettings).marker}`}>
          {showLineNumbers && controls?.down ? (
            <HunkContextButton direction="down" lineCount={controls.down.lineCount} loading={controls.down.loading} onClick={controls.down.onClick} />
          ) : null}
        </td>
        {showReviewNotes ? <td className={`w-4 select-none ${diffDensityClasses(reviewSettings).marker}`} /> : null}
        {showMetricGutter ? <MetricGutterCell metrics={[]} reviewSettings={reviewSettings} /> : null}
      </tr>
    )
  }

  return (
    <tr className={`group ${diffLineClass("hunk")}`} data-diff-kind="hunk">
      {hideOldLineGutter || !showLineNumbers ? null : (
        <td className={`${diffGutterClass("hunk")} ${diffDensityClasses(reviewSettings).gutter}`}>
          {controls?.up ? (
            <HunkContextButton direction="up" lineCount={controls.up.lineCount} loading={controls.up.loading} onClick={controls.up.onClick} />
          ) : null}
        </td>
      )}
      {showLineNumbers ? (
        <td className={`${diffGutterClass("hunk")} ${diffDensityClasses(reviewSettings).gutter}`}>
          {hideOldLineGutter ? (
            <div className="flex justify-center gap-1">
              {controls?.up ? (
                <HunkContextButton direction="up" lineCount={controls.up.lineCount} loading={controls.up.loading} onClick={controls.up.onClick} />
              ) : null}
              {controls?.down ? (
                <HunkContextButton direction="down" lineCount={controls.down.lineCount} loading={controls.down.loading} onClick={controls.down.onClick} />
              ) : null}
            </div>
          ) : controls?.down ? (
            <HunkContextButton direction="down" lineCount={controls.down.lineCount} loading={controls.down.loading} onClick={controls.down.onClick} />
          ) : null}
        </td>
      ) : null}
      <td className={`${diffMarkerClass("hunk")} ${diffDensityClasses(reviewSettings).marker}`}>{line.marker}</td>
      <td
        className={`${mobileUnifiedWrap ? "min-w-0 max-w-0 overflow-hidden whitespace-pre-wrap break-words" : "min-w-[40rem] whitespace-pre"} text-text-primary ${diffDensityClasses(reviewSettings).hunkCodeCell}`}
      >
        {line.code}
      </td>
      <td className={`w-4 select-none text-center ${diffDensityClasses(reviewSettings).marker}`} />
      {showReviewNotes ? <td className={`w-4 select-none ${diffDensityClasses(reviewSettings).marker}`} /> : null}
      {showMetricGutter ? <MetricGutterCell metrics={[]} reviewSettings={reviewSettings} /> : null}
    </tr>
  )
}
/* eslint-enable design-system/no-raw-table-classes */

function HunkContextButton({ direction, lineCount, loading, onClick }: { direction: "down" | "up"; lineCount: number; loading: boolean; onClick: () => void }) {
  return (
    <button
      aria-label={direction === "up" ? `Load ${lineCount} more lines above` : `Load ${lineCount} more lines below`}
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
  lineNumber,
  onCommentLine,
  reviewSettings,
  side
}: {
  file: ReviewableDiffFile
  line: DiffLine
  lineNumber: number | string
  onCommentLine?: (selection: DiffLineSelection) => void
  reviewSettings: ReviewDiffSettings
  side: "old" | "new"
}) {
  return (
    <button
      aria-label={`Comment on ${file.path}:${side}:${line.newLine ?? line.oldLine}`}
      className="relative block h-full w-full text-right"
      onClick={() => onCommentLine?.({ file, line, side })}
      type="button"
    >
      <span
        aria-hidden="true"
        className={`absolute left-0.5 top-1/2 flex -translate-y-1/2 items-center justify-center rounded-full bg-brand leading-none text-on-brand opacity-0 transition-opacity hover:opacity-100 group-hover:opacity-100 ${diffDensityClasses(reviewSettings).commentButton}`}
      >
        +
      </span>
      <span>{lineNumber}</span>
    </button>
  )
}

function anchorKeyForLine(line: DiffLine, side: "old" | "new") {
  if (side === "old") return `left:${line.oldLine ?? ""}:${line.newLine ?? ""}`
  return `right:${line.oldLine ?? ""}:${line.newLine ?? ""}`
}

function DiffFileHeader({
  collapsed = false,
  file,
  loadWholeFileState,
  onLoadWholeFile,
  onToggleCollapsed,
  onToggleFilesPopup,
  reviewSettings,
  selected,
  showFilesPopupTrigger
}: {
  collapsed?: boolean
  file: ReviewableDiffFile
  loadWholeFileState?: "error" | "idle" | "loaded" | "loading" | null
  onLoadWholeFile?: () => void
  onToggleCollapsed?: () => void
  onToggleFilesPopup?: (event: MouseEvent<HTMLButtonElement>) => void
  reviewSettings: ReviewDiffSettings
  selected: boolean
  showFilesPopupTrigger?: boolean
}) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()
  // The mobile top offset comes from the shared app chrome layer. When the
  // mobile chrome hides, the variable drops toward zero so diff file headers
  // reclaim that vertical space while still sticking below visible chrome.
  // A collapsed file has nothing left to scroll past, so it must not stay
  // pinned -- it scrolls away with the rest of the page like any other row.
  const stickyClass = collapsed ? "" : "sticky top-0 z-10 max-lg:top-[var(--mobile-chrome-visible-top-inset,0px)] "
  const densityClasses = diffDensityClasses(reviewSettings)
  const className = `${stickyClass}flex w-full items-center border-b border-gray-100 bg-gray-50 text-left font-mono text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400 ${densityClasses.fileHeader} ${selected ? "text-brand dark:text-brand-emphasis" : ""}`

  return (
    <div className={className} title={file.path}>
      {onToggleCollapsed ? (
        // Collapsing frees up review space on wide diffs (e.g. large generated
        // files); the viewport is too narrow on mobile to spare the control.
        <button
          aria-expanded={!collapsed}
          aria-label={collapsed ? t("diff_review.expand_file") : t("diff_review.collapse_file")}
          className="flex h-4 w-4 shrink-0 items-center justify-center text-text-muted hover:text-text-primary max-md:hidden"
          onClick={onToggleCollapsed}
          type="button"
        >
          <ChevronIcon className={`h-3.5 w-3.5 transition-transform ${collapsed ? "" : "rotate-90"}`} />
        </button>
      ) : null}
      <button
        aria-label={t("diff_review.copy_file_path_to_clipboard", { path: file.path })}
        className={`group flex min-w-0 flex-1 items-center rounded text-left hover:bg-surface-raised hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand ${densityClasses.filePathCopy}`}
        onClick={() => copy(file.path)}
        title={copied ? t("copy.copied") : t("diff_review.copy_file_path", { path: file.path })}
        type="button"
      >
        <span className="min-w-0 flex-1 truncate">{file.path}</span>
        <CopyIcon className={`h-3.5 w-3.5 shrink-0 ${copied ? "text-success-text" : "text-text-secondary group-hover:text-text-primary"}`} />
      </button>
      <GeneratedFileBadge file={file} />
      {typeof file.additions === "number" ? <span>+{file.additions}</span> : null}
      {typeof file.deletions === "number" ? <span>-{file.deletions}</span> : null}
      {onLoadWholeFile ? (
        <button
          className={`${DIFF_FILE_HEADER_CONTROL_BASE_CLASS} ${densityClasses.fileHeaderControl}`}
          disabled={loadWholeFileState !== "idle" && loadWholeFileState !== "error"}
          onClick={onLoadWholeFile}
          type="button"
        >
          {loadWholeFileState === "loaded" ? "Whole file loaded" : loadWholeFileState === "loading" ? "Loading…" : "Load whole file"}
        </button>
      ) : null}
      {showFilesPopupTrigger ? (
        <button
          aria-label={t("diff_review.browse_changed_files")}
          className={`${DIFF_FILE_HEADER_CONTROL_BASE_CLASS} ${densityClasses.fileHeaderControl}`}
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

export function sortReviewFiles(files: ReviewableDiffFile[], sort: ReviewDiffSettings["file_sort"]) {
  if (sort === "original") return files
  const indexedFiles = files.map((file, index) => ({ file, index }))
  indexedFiles.sort((left, right) => {
    if (sort === "alphabetical") {
      return left.file.path.localeCompare(right.file.path) || left.index - right.index
    }

    return changeSize(right.file) - changeSize(left.file) || left.file.path.localeCompare(right.file.path) || left.index - right.index
  })
  return indexedFiles.map(({ file }) => file)
}

function changeSize(file: ReviewableDiffFile) {
  return (file.additions ?? 0) + (file.deletions ?? 0)
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

export function annotationsForFile(annotations: ReviewableDiffProps["annotations"], path: string): Record<string, LineAnnotation> | undefined {
  if (!annotations || Object.keys(annotations).length === 0) return undefined
  if (isLineAnnotations(annotations)) return annotations
  return annotations[path]
}

// Empty objects satisfy `.every` vacuously, so an empty map must never reach
// this heuristic (annotationsForFile short-circuits it above); requiring at
// least one entry keeps this predicate honest if it's ever called directly.
export function isLineAnnotations(annotations: NonNullable<ReviewableDiffProps["annotations"]>): annotations is Record<string, LineAnnotation> {
  const values = Object.values(annotations)
  return values.length > 0 && values.every((value) => typeof value === "string")
}
