import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { Button } from "../../components/Button"
import { SectionHeading } from "../../components/Heading"
import { TypedArtifactPanel } from "../../components/artifacts/TypedArtifactPanel"
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
import { ReviewableDiff, type DiffLineSelection } from "../../components/diff/ReviewableDiff"
import { useDiffReviewFeedback } from "./DiffReviewFeedback"
import { DiffReviewVersionSelector, type DiffReviewRangeSelection } from "./DiffReviewVersionSelector"
import { PanelMessage } from "./components"
import { stepArtifactAdversarialReview, stepArtifactTestPlan, stepArtifactVisualReview } from "./stepArtifacts"

const SURFACE = "job_review_workspace"

export function ReviewWorkspace({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const jobId = payload.job.id
  const sourceDiff = useQuery({
    queryKey: ["jobs", String(jobId), "review_source_diff"],
    queryFn: () => measureAsync("diff_review.fetch_source_diff", () => fetchJobSourceDiff(String(jobId)), { metadata: { job_id: jobId } }),
    placeholderData: keepPreviousData
  })
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
    surface: SURFACE
  })
  const reviewArtifacts = reviewArtifactSummaries(payload.workflows)

  useEffect(() => {
    if (defaultVersionId && selectedVersionId == null) setSelectedVersionId(defaultVersionId)
  }, [defaultVersionId, selectedVersionId])

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
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-start">
      <div className="min-w-0 space-y-4">
        <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
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
              <ReviewStatePill label={t("review_pending_state", { count: Object.values(feedback.commentCounts).reduce((sum, count) => sum + count, 0) })} tone="pending" />
            </div>
          </div>
          {payload.summary ? <Markdown className="chat-prose mt-3 text-sm text-gray-700 dark:text-gray-300" text={payload.summary.text} /> : <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>}
        </section>

        <ReviewArtifactsPanel payload={payload} reviewArtifacts={reviewArtifacts} />

        <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          <ReviewableDiff
            changedFilesPopup
            comments={feedback.diffThreads}
            composingBody={feedback.composingBody}
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
            onLoadFileContext={activeDiff.head_ref ? (file) => fetchJobSourceFileContent(jobId, activeDiff.head_ref!, file.path) : undefined}
            onSaveComposing={feedback.onSaveComposing}
            onSaveEditThread={feedback.onSaveEditThread}
            onSelectFile={setSelectedPath}
            onStartEditThread={feedback.onStartEditThread}
            scroll="natural"
            selectedPath={selectedPath}
            showFileHeaders
            unavailableState={t("source_diff_not_available")}
          />
        </section>
      </div>
      <div className="min-w-0 lg:sticky lg:top-0 lg:h-screen lg:overflow-y-auto">
        {feedback.panel}
      </div>
    </div>
  )
}

function preferredReviewVersionId(payloadVersion: DiffReviewVersion | null, versions: DiffReviewVersion[]) {
  const allChangesVersion = versions.find(isAllChangesVersion)
  return allChangesVersion?.id ?? payloadVersion?.id ?? versions[versions.length - 1]?.id ?? null
}

function isAllChangesVersion(version: DiffReviewVersion) {
  return version.reason === "source_diff" || version.metadata?.range_kind === "all_changes"
}

function ReviewArtifactsPanel({ payload, reviewArtifacts }: { payload: JobDetailPayload; reviewArtifacts: string[] }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const hasArtifacts = Boolean(payload.test_plan) || reviewArtifacts.length > 0 || payload.typed_artifacts.length > 0

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
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
                <div className="min-w-0 overflow-x-auto rounded border border-gray-200 p-3 dark:border-gray-800">
                  <p className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("section_test_plan")}</p>
                  <ul className="mt-2 list-disc space-y-1 pl-4 text-sm text-gray-700 dark:text-gray-300">
                    {payload.test_plan.steps.map((step, index) => <li className="break-words" key={`${index}-${step}`}>{step}</li>)}
                  </ul>
                </div>
              ) : null}
              {reviewArtifacts.map((artifact) => (
                <div className="min-w-0 overflow-x-auto rounded border border-gray-200 p-3 dark:border-gray-800" key={artifact}>
                  <p className="break-words text-sm text-gray-700 dark:text-gray-300">{artifact}</p>
                </div>
              ))}
            </div>
          ) : null}
          <TypedArtifactPanel artifacts={payload.typed_artifacts} />
        </div>
      ) : null}
    </section>
  )
}

function ReviewStatePill({ label, tone }: { label: string; tone: "pending" | "submitted" | "handled" }) {
  const className = {
    handled: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-200",
    pending: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-200",
    submitted: "bg-info/10 text-info"
  }[tone]
  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${className}`}>{label}</span>
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
