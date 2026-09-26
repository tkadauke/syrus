import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { Button } from "../../components/Button"
import { SectionHeading } from "../../components/Heading"
import { ArtifactBody } from "../../components/artifacts/TypedArtifactPanel"
import type { TypedArtifact } from "../../api/artifacts"
import { Markdown } from "../../lib/Markdown"
import { errorMessage } from "../../lib/errorMessage"
import { measureAsync, useMarkedRender } from "../../lib/performanceMarkers"
import { useT } from "../../hooks/useT"
import {
  fetchJobSourceDiff,
  fetchJobSourceFileContent,
  fetchDiffReviewVersion,
  type DiffReviewComment,
  type DiffReviewVersion,
  type JobDetailPayload,
  type JobWorkflow
} from "../../api/jobs"
import { DEFAULT_REVIEW_DIFF_SETTINGS, fetchReviewDiffSettings, patchReviewDiffSettings, type ReviewDiffSettings, type ReviewDiffSettingsPayload } from "../../api/reviewDiffSettings"
import { ImageDiffThumbnails } from "../../components/diff/ImageDiffThumbnails"
import { ReviewableDiff, type DiffLineSelection } from "../../components/diff/ReviewableDiff"
import { useOptionalShortcut } from "../../contexts/ShortcutsContext"
import { useResizableSplitter } from "../chat/useResizableSplitter"
import { useMediaQuery } from "../dashboard/components"
import { useDiffReviewFeedback } from "./DiffReviewFeedback"
import { DiffReviewVersionSelector, canonicalReviewVersions, type DiffReviewRangeSelection } from "./DiffReviewVersionSelector"
import { ReviewDiffSettingsModal } from "./ReviewDiffSettingsModal"
import { PanelMessage } from "./components"
import { stepArtifactAdversarialReview, stepArtifactTestPlan, stepArtifactVisualReview } from "./stepArtifacts"
import { Section, SURFACE_CLIP_ROUNDED_CLASS, surfaceClasses } from "../../components/ui"

const SURFACE = "job_review_workspace"
const REVIEW_COMMENTS_WIDTH_KEY = "syrus.review.comments.width"
const REVIEW_COMMENTS_COLLAPSED_KEY = "syrus.review.comments.collapsed"
const REVIEW_COMMENTS_DEFAULT_WIDTH = 384
const REVIEW_COMMENTS_MIN_WIDTH = 288
const REVIEW_COMMENTS_MAX_WIDTH = 640
const REVIEW_COMMENTS_SNAP_CLOSED_WIDTH = 224
const REVIEW_COMMENTS_REOPEN_WIDTH = 256
const REVIEW_COMMENTS_RAIL_WIDTH = 48
const REVIEW_COMMENTS_PEEK_OPEN_DELAY_MS = 350
const REVIEW_COMMENTS_PEEK_CLOSE_DELAY_MS = 150
const REVIEW_COMMENTS_SPLITTER_CLASS =
  "group relative z-10 hidden w-4 shrink-0 cursor-col-resize outline-none transition-colors hover:bg-brand/5 focus-visible:bg-brand/10 lg:block"
const REVIEW_COMMENTS_SPLITTER_GRIP_CLASS =
  "absolute left-1/2 top-1/2 h-10 w-1 -translate-x-1/2 -translate-y-1/2 rounded-full bg-text-muted transition-opacity"
const REVIEW_COMMENTS_RAIL_CLASS =
  "hidden h-screen w-12 shrink-0 border-l border-border bg-surface px-1.5 py-3 lg:block"

export function ReviewWorkspace({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const jobId = payload.job.id
  const sourceDiff = useQuery({
    queryKey: ["jobs", String(jobId), "review_source_diff"],
    queryFn: () => measureAsync("diff_review.fetch_source_diff", () => fetchJobSourceDiff(String(jobId)), { metadata: { job_id: jobId } }),
    placeholderData: keepPreviousData
  })
  const settingsQuery = useQuery({
    queryKey: ["review_diff_settings"],
    queryFn: fetchReviewDiffSettings,
    staleTime: Infinity
  })
  const reviewSettings = settingsQuery.data?.review_diff_settings ?? DEFAULT_REVIEW_DIFF_SETTINGS
  useReviewDiffSettingsShortcuts(reviewSettings)
  // Paint-phase (not just commit-phase) because the diff view keeps doing
  // virtualizer/Shiki work across several frames after the initial commit;
  // "paint" is a closer proxy for when the reviewer actually sees something.
  useMarkedRender("diff_review.initial_render", {
    deps: [jobId, sourceDiff.isSuccess],
    enabled: sourceDiff.isSuccess ? undefined : false,
    metadata: { total_files: sourceDiff.data?.files.length ?? 0 },
    phase: "paint"
  })
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const [selectedVersionId, setSelectedVersionId] = useState<number | null>(null)
  const [selectedRange, setSelectedRange] = useState<{ baseSha: string; headSha: string } | null>(null)
  const [pendingCommentFocus, setPendingCommentFocus] = useState<DiffReviewComment | null>(null)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [commentsPeekOpen, setCommentsPeekOpen] = useState(false)
  const commentsPeekOpenTimerRef = useRef<number | null>(null)
  const commentsPeekCloseTimerRef = useRef<number | null>(null)
  const isDesktopSplit = useMediaQuery("(min-width: 1024px)", true)
  const commentsSplitter = useResizableSplitter({
    widthKey: REVIEW_COMMENTS_WIDTH_KEY,
    collapsedKey: REVIEW_COMMENTS_COLLAPSED_KEY,
    initialWidth: storedReviewCommentsWidth,
    initialCollapsed: storedReviewCommentsCollapsed,
    defaultWidth: REVIEW_COMMENTS_DEFAULT_WIDTH,
    snapClosedWidth: REVIEW_COMMENTS_SNAP_CLOSED_WIDTH,
    reopenWidth: REVIEW_COMMENTS_REOPEN_WIDTH,
    resizeEdge: "start",
    clampWidth: clampReviewCommentsWidth
  })
  const versions = sourceDiff.data?.versions || []
  const payloadVersionId = sourceDiff.data?.version?.id ?? null
  const defaultVersionId = preferredReviewVersionId(sourceDiff.data?.version ?? null, versions)
  const rangeSearch = selectedRange ? `?${new URLSearchParams({ base: selectedRange.baseSha, head: selectedRange.headSha }).toString()}` : ""
  const rangeDiff = useQuery({
    enabled: sourceDiff.isSuccess && Boolean(selectedRange),
    queryKey: ["jobs", String(jobId), "review_source_diff_range", selectedRange?.baseSha, selectedRange?.headSha],
    queryFn: () => measureAsync("diff_review.fetch_source_diff", () => fetchJobSourceDiff(String(jobId), rangeSearch), { metadata: { job_id: jobId } })
  })
  const activeVersionId = selectedRange ? rangeDiff.data?.version?.id ?? null : selectedVersionId ?? defaultVersionId
  const historicalVersionSelected = !selectedRange && activeVersionId != null && activeVersionId !== payloadVersionId
  const historicalVersion = useQuery({
    enabled: sourceDiff.isSuccess && historicalVersionSelected,
    queryKey: ["jobs", String(jobId), "diff_review_versions", activeVersionId],
    queryFn: () => fetchDiffReviewVersion(jobId, activeVersionId!)
  })
  const selectedVersion = versions.find((version) => version.id === activeVersionId) ?? sourceDiff.data?.version ?? null
  const activeDiff = useMemo(() => {
    if (!sourceDiff.data) return null
    if (selectedRange && rangeDiff.data) return rangeDiff.data
    if (activeVersionId != null && activeVersionId !== payloadVersionId && historicalVersion.data) {
      return {
        ...sourceDiff.data,
        base_ref: historicalVersion.data.base_ref || historicalVersion.data.base_sha,
        head_ref: historicalVersion.data.head_ref || historicalVersion.data.head_sha,
        base_sha: historicalVersion.data.base_sha,
        head_sha: historicalVersion.data.head_sha,
        files: historicalVersion.data.files,
        truncated: historicalVersion.data.truncated,
        diff_error: historicalVersion.data.diff_error,
        version: historicalVersion.data
      }
    }
    return sourceDiff.data
  }, [activeVersionId, historicalVersion.data, payloadVersionId, rangeDiff.data, selectedRange, sourceDiff.data])
  const feedback = useDiffReviewFeedback({
    baseRef: activeDiff?.base_ref,
    diffReviewVersionId: activeVersionId,
    enabled: sourceDiff.isSuccess && Boolean(activeVersionId),
    headRef: activeDiff?.head_ref,
    includeAllVersions: true,
    jobId,
    onNavigateToFile: setSelectedPath,
    onViewCommentVersion: viewCommentVersion,
    supportsGlobalComments: true,
    surface: SURFACE,
    versions
  })
  const reviewArtifacts = reviewArtifactSummaries(payload.workflows)

  useEffect(() => {
    if (defaultVersionId && selectedVersionId == null) setSelectedVersionId(defaultVersionId)
  }, [defaultVersionId, selectedVersionId])

  useEffect(() => {
    return () => {
      clearReviewCommentsPeekTimers(commentsPeekOpenTimerRef, commentsPeekCloseTimerRef)
    }
  }, [])

  useEffect(() => {
    if (!pendingCommentFocus || activeVersionId !== pendingCommentFocus.diff_review_version_id) return
    const commentToFocus = pendingCommentFocus
    let cancelled = false
    let frame = 0
    let attempts = 0

    function scheduleFocus() {
      frame = window.requestAnimationFrame(() => {
        if (cancelled) return
        attempts += 1

        const focused = focusPendingComment(commentToFocus)
        if (focused || attempts >= 12) {
          setPendingCommentFocus(null)
          return
        }

        scheduleFocus()
      })
    }

    scheduleFocus()
    return () => {
      cancelled = true
      window.cancelAnimationFrame(frame)
    }
  }, [activeVersionId, pendingCommentFocus])

  function focusPendingComment(pendingCommentFocus: DiffReviewComment) {
    if (pendingCommentFocus.anchor_kind === "review") {
      const record = document.querySelector(`[data-diff-review-comment-id="${pendingCommentFocus.id}"]`)
      record?.scrollIntoView({ block: "center" })
      return Boolean(record)
    }

    if (!pendingCommentFocus.path) return true

    const file = document.querySelector(`[data-diff-file="${CSS.escape(pendingCommentFocus.path)}"]`)
    const anchor = pendingCommentFocus.anchor_key
      ? file?.querySelector(`[data-diff-anchor="${CSS.escape(pendingCommentFocus.anchor_key)}"]`)
      : null
    ;(anchor || file)?.scrollIntoView({ block: "center" })
    return Boolean(anchor || file)
  }

  function startComment(nextSelection: DiffLineSelection) {
    feedback.onCommentLine?.(nextSelection)
    setSelectedPath(nextSelection.file.path)
  }

  function viewCommentVersion(comment: DiffReviewComment) {
    setSelectedRange(null)
    setSelectedVersionId(comment.diff_review_version_id)
    if (comment.path) setSelectedPath(comment.path)
    setPendingCommentFocus(comment)
    if (comment.anchor_kind === "review") focusPendingComment(comment)
  }

  function selectVersion(versionId: number) {
    setSelectedRange(null)
    setSelectedVersionId(versionId)
  }

  function selectRange(range: DiffReviewRangeSelection) {
    setSelectedRange({ baseSha: range.baseSha, headSha: range.headSha })
    setSelectedVersionId(range.versionId)
  }

  function openCommentsPeek() {
    clearTimer(commentsPeekCloseTimerRef)
    if (!commentsSplitter.collapsed || commentsPeekOpen) return
    clearTimer(commentsPeekOpenTimerRef)
    commentsPeekOpenTimerRef.current = window.setTimeout(() => setCommentsPeekOpen(true), REVIEW_COMMENTS_PEEK_OPEN_DELAY_MS)
  }

  function closeCommentsPeek() {
    clearTimer(commentsPeekOpenTimerRef)
    if (!commentsPeekOpen) return
    clearTimer(commentsPeekCloseTimerRef)
    commentsPeekCloseTimerRef.current = window.setTimeout(() => setCommentsPeekOpen(false), REVIEW_COMMENTS_PEEK_CLOSE_DELAY_MS)
  }

  if (sourceDiff.isPending) return <PanelMessage>{t("review_loading")}</PanelMessage>
  if (sourceDiff.isError) return <PanelMessage tone="error">{errorMessage(sourceDiff.error, t("review_load_error"))}</PanelMessage>
  if (sourceDiff.data.diff_error) return <PanelMessage tone="error">{sourceDiff.data.diff_error}</PanelMessage>
  if (!activeDiff) return <PanelMessage>{t("review_loading")}</PanelMessage>
  if (historicalVersionSelected && historicalVersion.isPending) return <PanelMessage>{t("source_diff_loading")}</PanelMessage>
  if (historicalVersionSelected && historicalVersion.isError) return <PanelMessage tone="error">{errorMessage(historicalVersion.error, t("source_diff_error"))}</PanelMessage>
  if (selectedRange && rangeDiff.isPending) return <PanelMessage>{t("source_diff_loading")}</PanelMessage>
  if (selectedRange && rangeDiff.isError) return <PanelMessage tone="error">{errorMessage(rangeDiff.error, t("source_diff_error"))}</PanelMessage>
  if (activeDiff.diff_error) return <PanelMessage tone="error">{activeDiff.diff_error}</PanelMessage>

  return (
    <div className="relative grid min-w-0 max-w-full gap-4 lg:flex lg:items-start lg:gap-0">
      <div className="min-w-0 space-y-4 lg:flex-1">
        <Section.Root>
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <SectionHeading>{t("review_summary_title")}</SectionHeading>
              <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("review_changed_files", { count: activeDiff.files.length })}</p>
            </div>
            <div className="flex flex-wrap items-start gap-3 text-xs">
              <DiffReviewVersionSelector
                disabled={sourceDiff.isFetching || historicalVersion.isFetching || rangeDiff.isFetching}
                latestVersionId={defaultVersionId}
                onChange={selectVersion}
                onRangeChange={selectRange}
                selectedRange={selectedRange}
                selectedVersionId={activeVersionId}
                versions={versions.length > 0 ? versions : selectedVersion ? [selectedVersion] : []}
              />
              <Button onClick={() => setSettingsOpen(true)} size="sm" variant="secondary">{t("review_settings_button")}</Button>
            </div>
          </div>
          {payload.summary ? <Markdown className="chat-prose mt-3 text-sm text-gray-700 dark:text-gray-300" text={payload.summary.text} /> : <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>}
        </Section.Root>

        <ReviewArtifactsPanel
          payload={payload}
          reviewArtifacts={reviewArtifacts}
          selectedRange={selectedRange}
          selectedVersion={selectedVersion}
          versions={versions}
        />

        {/*
          Not `overflow-hidden`: this diff viewer renders with `scroll="natural"`,
          so its file headers pin via `position: sticky` against the page itself.
          Any ancestor whose `overflow` isn't `visible` -- including `hidden` --
          becomes the nearest scroll container for that sticky descendant even
          though this panel never scrolls, which permanently unpins the headers.
          `SURFACE_CLIP_ROUNDED_CLASS` clips the diff's square corners to the
          panel's rounded corners without that side effect.
        */}
        <Section.Root className={`min-w-0 max-w-full ${SURFACE_CLIP_ROUNDED_CLASS}`} padding="none">
          <ReviewableDiff
            changedFilesPopup={reviewSettings.file_list}
            comments={feedback.diffThreads}
            composingBody={feedback.composingBody}
            composingDiscussError={feedback.discussComposingError}
            composingDiscussPending={feedback.discussComposingPending}
            composingError={feedback.composingError}
            composingPending={feedback.composingPending}
            composingSelection={feedback.composingSelection}
            editingThreadBody={feedback.editingThreadBody}
            editingThreadId={feedback.editingThreadId}
            emptyState={<div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_changed_files")}</div>}
            fileCommentCounts={feedback.commentCounts}
            files={activeDiff.files}
            mode="continuous"
            onCancelComposing={feedback.onCancelComposing}
            onCancelEditThread={feedback.onCancelEditThread}
            onChangeComposingBody={feedback.onChangeComposingBody}
            onChangeEditingThreadBody={feedback.onChangeEditingThreadBody}
            onCommentLine={startComment}
            onDeleteThread={feedback.onDeleteThread}
            onDiscussComposing={feedback.onDiscussComposing}
            onLoadFileContext={activeDiff.head_ref ? (file) => fetchJobSourceFileContent(jobId, activeDiff.head_ref!, file.path) : undefined}
            onSaveComposing={feedback.onSaveComposing}
            onSaveEditThread={feedback.onSaveEditThread}
            onSelectFile={setSelectedPath}
            onStartEditThread={feedback.onStartEditThread}
            renderImageDiff={(file) => (
              <ImageDiffThumbnails baseRef={activeDiff.base_sha ?? activeDiff.base_ref} file={file} headRef={activeDiff.head_sha ?? activeDiff.head_ref} jobId={jobId} />
            )}
            reviewSettings={reviewSettings}
            scroll="natural"
            selectedPath={selectedPath}
            showFileHeaders
            unavailableState={t("source_diff_not_available")}
          />
        </Section.Root>
      </div>
      {isDesktopSplit ? (
        <ReviewCommentsSplitterHandle
          collapsed={commentsSplitter.collapsed}
          label={t("review_comments_splitter_label")}
          maxWidth={REVIEW_COMMENTS_MAX_WIDTH}
          onClick={() => {
            commentsSplitter.toggleCollapsed()
            setCommentsPeekOpen(false)
          }}
          onKeyDown={(event) => {
            commentsSplitter.resizeWithKeyboard(event)
            setCommentsPeekOpen(false)
          }}
          onMouseDown={commentsSplitter.beginResize}
          valueNow={commentsSplitter.collapsed ? 0 : commentsSplitter.width}
        />
      ) : null}
      <div
        className={`${isDesktopSplit && commentsSplitter.collapsed ? "hidden" : ""} min-w-0 max-w-full lg:sticky lg:top-0 lg:h-screen lg:shrink-0 lg:overflow-y-auto`}
        data-testid="review-comments-panel"
        style={isDesktopSplit ? { width: `${commentsSplitter.width}px` } : undefined}
      >
        {isDesktopSplit && commentsSplitter.collapsed ? null : feedback.panel}
      </div>
      {isDesktopSplit && commentsSplitter.collapsed ? (
        <ReviewCommentsCollapsedRail
          label={t("review_comments_collapsed_aria")}
          onMouseEnter={openCommentsPeek}
          onMouseLeave={closeCommentsPeek}
          summaries={feedback.versionSummaries}
        />
      ) : null}
      {isDesktopSplit && commentsSplitter.collapsed && commentsPeekOpen ? (
        <div
          className="absolute top-0 z-30 h-screen min-w-0 overflow-y-auto shadow-2xl"
          data-testid="review-comments-peek"
          onMouseEnter={openCommentsPeek}
          onMouseLeave={closeCommentsPeek}
          style={{ right: `${REVIEW_COMMENTS_RAIL_WIDTH}px`, width: `${commentsSplitter.width}px` }}
        >
          {feedback.panel}
        </div>
      ) : null}
      {settingsOpen ? <ReviewDiffSettingsModal initialSettings={reviewSettings} onClose={() => setSettingsOpen(false)} /> : null}
    </div>
  )
}

function ReviewCommentsSplitterHandle({
  collapsed,
  label,
  maxWidth,
  valueNow,
  onClick,
  onKeyDown,
  onMouseDown
}: {
  collapsed: boolean
  label: string
  maxWidth: number
  valueNow: number
  onClick: () => void
  onKeyDown: (event: ReactKeyboardEvent<HTMLDivElement>) => void
  onMouseDown: (event: ReactMouseEvent<HTMLDivElement>) => void
}) {
  return (
    <div
      aria-label={label}
      aria-orientation="vertical"
      aria-valuemax={maxWidth}
      aria-valuemin={0}
      aria-valuenow={valueNow}
      className={REVIEW_COMMENTS_SPLITTER_CLASS}
      onClick={onClick}
      onKeyDown={onKeyDown}
      onMouseDown={onMouseDown}
      role="separator"
      tabIndex={0}
      title={label}
    >
      <span className="absolute left-1/2 top-0 h-full -translate-x-1/2 border-l border-border" />
      <span className={`${REVIEW_COMMENTS_SPLITTER_GRIP_CLASS} ${collapsed ? "opacity-70" : "opacity-0 group-hover:opacity-70 group-focus-visible:opacity-80"}`} />
    </div>
  )
}

function ReviewCommentsCollapsedRail({
  label,
  onMouseEnter,
  onMouseLeave,
  summaries
}: {
  label: string
  onMouseEnter: () => void
  onMouseLeave: () => void
  summaries: { count: number; label: string; versionId: number }[]
}) {
  return (
    <aside
      aria-label={label}
      className={REVIEW_COMMENTS_RAIL_CLASS}
      data-testid="review-comments-rail"
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
    >
      <div className="flex flex-col items-center gap-3">
        <CommentIcon />
        <div className="flex w-full flex-col items-center gap-2">
          {summaries.map((summary) => (
            <div className="flex w-full flex-col items-center gap-1" data-testid="review-comments-rail-version" key={summary.versionId} title={`${summary.label}: ${summary.count}`}>
              <span className="max-w-full truncate text-[11px] font-semibold text-gray-700 dark:text-gray-300">{summary.label}</span>
              <span className="min-w-5 rounded-full bg-brand px-1.5 py-0.5 text-center text-[11px] font-semibold leading-none text-white">{summary.count}</span>
            </div>
          ))}
        </div>
      </div>
    </aside>
  )
}

function CommentIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5 text-gray-500 dark:text-gray-400" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z" />
    </svg>
  )
}

function storedReviewCommentsCollapsed(): boolean {
  try {
    return window.localStorage.getItem(REVIEW_COMMENTS_COLLAPSED_KEY) === "true"
  } catch (_error) {
    return false
  }
}

function storedReviewCommentsWidth() {
  try {
    return clampReviewCommentsWidth(Number.parseInt(window.localStorage.getItem(REVIEW_COMMENTS_WIDTH_KEY) || "", 10) || REVIEW_COMMENTS_DEFAULT_WIDTH)
  } catch (_error) {
    return REVIEW_COMMENTS_DEFAULT_WIDTH
  }
}

function clampReviewCommentsWidth(width: number) {
  return Math.min(Math.max(width, REVIEW_COMMENTS_MIN_WIDTH), REVIEW_COMMENTS_MAX_WIDTH)
}

function clearReviewCommentsPeekTimers(openTimerRef: { current: number | null }, closeTimerRef: { current: number | null }) {
  clearTimer(openTimerRef)
  clearTimer(closeTimerRef)
}

function clearTimer(timerRef: { current: number | null }) {
  if (timerRef.current == null) return
  window.clearTimeout(timerRef.current)
  timerRef.current = null
}

const REVIEW_SHORTCUT_GROUP_ORDER = 2

function useReviewDiffSettingsShortcuts(reviewSettings: ReviewDiffSettings) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const shortcutGroup = t("review_shortcuts_group")
  const mutation = useMutation({
    mutationFn: patchReviewDiffSettings,
    onMutate: async (patch: Partial<ReviewDiffSettings>) => {
      await queryClient.cancelQueries({ queryKey: ["review_diff_settings"] })
      const previous = queryClient.getQueryData<ReviewDiffSettingsPayload>(["review_diff_settings"])
      const currentSettings = previous?.review_diff_settings ?? reviewSettings
      queryClient.setQueryData<ReviewDiffSettingsPayload>(["review_diff_settings"], {
        ...previous,
        review_diff_settings: { ...currentSettings, ...patch }
      })
      return { previous }
    },
    onError: (_error, _patch, context) => {
      if (context?.previous) queryClient.setQueryData(["review_diff_settings"], context.previous)
    },
    onSuccess: (payload) => {
      queryClient.setQueryData(["review_diff_settings"], payload)
    }
  })

  function updateSetting<Key extends keyof ReviewDiffSettings>(key: Key, value: ReviewDiffSettings[Key]) {
    mutation.mutate({ [key]: value } as Partial<ReviewDiffSettings>)
  }

  useOptionalShortcut("alt+shift+w", () => {
    updateSetting("line_wrapping", reviewSettings.line_wrapping === "wrap" ? "scroll" : "wrap")
  }, {
    description: t("review_shortcut_toggle_wrapping"),
    group: shortcutGroup,
    groupOrder: REVIEW_SHORTCUT_GROUP_ORDER
  })
  useOptionalShortcut("alt+shift+v", () => {
    updateSetting("desktop_view", reviewSettings.desktop_view === "unified" ? "split" : "unified")
  }, {
    description: t("review_shortcut_cycle_view"),
    group: shortcutGroup,
    groupOrder: REVIEW_SHORTCUT_GROUP_ORDER
  })
  useOptionalShortcut("alt+shift+h", () => {
    updateSetting("syntax_highlighting", !reviewSettings.syntax_highlighting)
  }, {
    description: t("review_shortcut_toggle_syntax"),
    group: shortcutGroup,
    groupOrder: REVIEW_SHORTCUT_GROUP_ORDER
  })
  useOptionalShortcut("alt+shift+s", () => {
    updateSetting("whitespace", reviewSettings.whitespace === "show" ? "trim_trailing" : "show")
  }, {
    description: t("review_shortcut_cycle_whitespace"),
    group: shortcutGroup,
    groupOrder: REVIEW_SHORTCUT_GROUP_ORDER
  })
}

function preferredReviewVersionId(payloadVersion: DiffReviewVersion | null, versions: DiffReviewVersion[]) {
  const canonicalVersions = canonicalReviewVersions(versions)
  const allChangesVersion = canonicalVersions.find(isAllChangesVersion)
  return allChangesVersion?.id ?? payloadVersion?.id ?? canonicalVersions[0]?.id ?? versions[versions.length - 1]?.id ?? null
}

function isAllChangesVersion(version: DiffReviewVersion) {
  return version.reason === "source_diff" || version.metadata?.range_kind === "all_changes"
}

function ReviewArtifactsPanel({
  payload,
  reviewArtifacts,
  selectedRange,
  selectedVersion,
  versions
}: {
  payload: JobDetailPayload
  reviewArtifacts: string[]
  selectedRange: { baseSha: string; headSha: string } | null
  selectedVersion: DiffReviewVersion | null
  versions: DiffReviewVersion[]
}) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const hasArtifacts = Boolean(payload.test_plan) || reviewArtifacts.length > 0 || payload.typed_artifacts.length > 0

  return (
    <Section.Root>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <SectionHeading>{t("review_artifacts_title")}</SectionHeading>
        {hasArtifacts ? (
          <Button onClick={() => setExpanded((value) => !value)} size="sm" variant="secondary">
            {expanded ? t("review_artifacts_hide") : t("review_artifacts_show")}
          </Button>
        ) : null}
      </div>
      {!hasArtifacts ? <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("section_no_artifacts")}</p> : null}
      {hasArtifacts && expanded ? (
        <div className="mt-3 space-y-4">
          {payload.test_plan || reviewArtifacts.length > 0 ? (
            <div className="grid gap-3 md:grid-cols-2">
              {payload.test_plan ? (
                <div className={surfaceClasses("inset", "sm", "min-w-0 overflow-x-auto")}>
                  <p className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("section_test_plan")}</p>
                  <ul className="mt-2 list-disc space-y-1 pl-4 text-sm text-gray-700 dark:text-gray-300">
                    {payload.test_plan.steps.map((step, index) => <li className="break-words" key={`${index}-${step}`}>{step}</li>)}
                  </ul>
                </div>
              ) : null}
              {reviewArtifacts.map((artifact) => (
                <div className={surfaceClasses("inset", "sm", "min-w-0 overflow-x-auto")} key={artifact}>
                  <p className="break-words text-sm text-gray-700 dark:text-gray-300">{artifact}</p>
                </div>
              ))}
            </div>
          ) : null}
          <VersionedArtifactsList
            artifacts={payload.typed_artifacts}
            selectedRange={selectedRange}
            selectedVersion={selectedVersion}
            versions={versions}
          />
        </div>
      ) : null}
    </Section.Root>
  )
}

// An artifact has usable provenance when it can be compared against the
// selected diff review version/range at all — either a direct
// diff_review_version_id match, or a head_sha to compare against the
// version/range's own head_sha. Artifacts submitted before this provenance
// existed (or from a step that never resolved a diff review version) have
// neither, and must never be silently hidden — they're always shown, just
// under an honest "unversioned" label instead of pretending they belong to
// whatever version happens to be selected.
function hasArtifactProvenance(artifact: TypedArtifact) {
  return artifact.diff_review_version_id != null || Boolean(artifact.head_sha)
}

function artifactMatchesSelection(
  artifact: TypedArtifact,
  selectedVersion: DiffReviewVersion | null,
  selectedRange: { baseSha: string; headSha: string } | null
) {
  if (selectedRange) return artifact.head_sha === selectedRange.headSha
  if (!selectedVersion) return true
  if (artifact.diff_review_version_id != null) return artifact.diff_review_version_id === selectedVersion.id
  return artifact.head_sha === selectedVersion.head_sha
}

function VersionedArtifactsList({
  artifacts,
  selectedRange,
  selectedVersion,
  versions
}: {
  artifacts: TypedArtifact[]
  selectedRange: { baseSha: string; headSha: string } | null
  selectedVersion: DiffReviewVersion | null
  versions: DiffReviewVersion[]
}) {
  const { t } = useT("jobs")
  if (artifacts.length === 0) return null

  const matching: TypedArtifact[] = []
  const unversioned: TypedArtifact[] = []
  for (const artifact of artifacts) {
    if (!hasArtifactProvenance(artifact)) {
      unversioned.push(artifact)
    } else if (artifactMatchesSelection(artifact, selectedVersion, selectedRange)) {
      matching.push(artifact)
    }
  }
  const displayed = [ ...matching, ...unversioned ]

  if (displayed.length === 0) return <p className="text-sm text-text-muted">{t("review_artifacts_no_version_match")}</p>

  return (
    <div className="min-w-0 space-y-4">
      {displayed.map((artifact, index) => (
        <div className="min-w-0 overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900" key={artifactKey(artifact, index)}>
          <div className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1 border-b border-border px-4 py-2">
            <span className="min-w-0 break-words font-semibold text-text-primary">{artifact.title}</span>
            <span className="min-w-0 break-all text-xs text-text-muted">{artifact.type}</span>
          </div>
          <div className="border-b border-border px-4 py-1.5">
            <ArtifactProvenance artifact={artifact} versions={versions} />
          </div>
          <div className="overflow-x-auto p-4">
            <ArtifactBody artifact={artifact} />
          </div>
        </div>
      ))}
    </div>
  )
}

function artifactKey(artifact: TypedArtifact, index: number) {
  return [ artifact.type, artifact.workflow_id ?? "x", artifact.run_id ?? "x", artifact.created_at ?? index ].join("-")
}

function ArtifactProvenance({ artifact, versions }: { artifact: TypedArtifact; versions: DiffReviewVersion[] }) {
  const { t } = useT("jobs")

  if (!hasArtifactProvenance(artifact)) {
    return <span className="text-xs font-medium uppercase tracking-wide text-text-muted">{t("review_artifacts_unversioned")}</span>
  }

  const version = artifact.diff_review_version_id != null ? versions.find((candidate) => candidate.id === artifact.diff_review_version_id) : null
  const iteration = artifactIteration(artifact)
  const parts = [
    version ? version.label || t("review_version_prefix", { version: version.version_index }) : null,
    artifact.workflow_id != null ? t("review_version_workflow", { id: artifact.workflow_id }) : null,
    artifact.run_id != null ? t("review_version_run", { id: artifact.run_id }) : null,
    artifact.trigger_kind || null,
    iteration != null ? t("review_artifacts_iteration", { number: iteration }) : null,
    artifact.base_sha && artifact.head_sha ? `${shortSha(artifact.base_sha)} → ${shortSha(artifact.head_sha)}` : null
  ].filter((part): part is string => Boolean(part))

  return <span className="text-xs text-text-muted">{parts.join(" · ")}</span>
}

function artifactIteration(artifact: TypedArtifact) {
  const payload = artifact.payload
  if (!payload || typeof payload !== "object" || !("iteration" in payload)) return null

  const value = (payload as Record<string, unknown>).iteration
  return typeof value === "number" ? value : null
}

function shortSha(sha: string) {
  return sha.slice(0, 7)
}

function reviewArtifactSummaries(workflows: JobWorkflow[]) {
  return workflows.flatMap((workflow) => {
    const artifacts = workflow.artifacts || {}
    const summaries: string[] = []
    const testPlan = stepArtifactTestPlan(artifacts.test_plan)
    if (testPlan?.notes) summaries.push(testPlan.notes)
    for (const iteration of stepArtifactAdversarialReview(artifacts.adversarial_review_iterations) || []) {
      summaries.push(`Adversarial review ${iteration.iteration}: ${iteration.verdict} - ${iteration.critique}`)
    }
    for (const iteration of stepArtifactVisualReview(artifacts.visual_review_iterations) || []) {
      summaries.push(`Visual review ${iteration.iteration}: ${iteration.verdict} - ${iteration.critique}`)
    }
    return summaries
  }).slice(0, 6)
}
