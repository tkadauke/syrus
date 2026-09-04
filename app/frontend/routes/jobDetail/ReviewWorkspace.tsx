import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { SectionHeading } from "../../components/Heading"
import { Markdown } from "../../lib/Markdown"
import { errorMessage } from "../../lib/errorMessage"
import { useT } from "../../hooks/useT"
import {
  fetchJobSourceDiff,
  type JobDetailPayload,
  type JobWorkflow
} from "../../api/jobs"
import { ReviewableDiff, type DiffLineSelection } from "../../components/diff/ReviewableDiff"
import { useDiffReviewFeedback } from "./DiffReviewFeedback"
import { PanelMessage } from "./components"
import { stepArtifactAdversarialReview, stepArtifactTestPlan, stepArtifactVisualReview } from "./stepArtifacts"

const SURFACE = "job_review_workspace"

export function ReviewWorkspace({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const jobId = payload.job.id
  const sourceDiff = useQuery({
    queryKey: ["jobs", String(jobId), "review_source_diff"],
    queryFn: () => fetchJobSourceDiff(String(jobId)),
    placeholderData: keepPreviousData
  })
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const feedback = useDiffReviewFeedback({
    baseRef: sourceDiff.data?.base_ref,
    enabled: sourceDiff.isSuccess,
    headRef: sourceDiff.data?.head_ref,
    jobId,
    surface: SURFACE
  })
  const reviewArtifacts = reviewArtifactSummaries(payload.workflows)

  function startComment(nextSelection: DiffLineSelection) {
    feedback.onCommentLine?.(nextSelection)
    setSelectedPath(nextSelection.file.path)
  }

  if (sourceDiff.isPending) return <PanelMessage>{t("review_loading")}</PanelMessage>
  if (sourceDiff.isError) return <PanelMessage tone="error">{errorMessage(sourceDiff.error, t("review_load_error"))}</PanelMessage>
  if (sourceDiff.data.diff_error) return <PanelMessage tone="error">{sourceDiff.data.diff_error}</PanelMessage>

  return (
    <div className="space-y-4">
      <section className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_24rem]">
        <div className="min-w-0 space-y-4">
          <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <SectionHeading>{t("review_summary_title")}</SectionHeading>
                <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("review_changed_files", { count: sourceDiff.data.files.length })}</p>
              </div>
              <div className="flex flex-wrap gap-2 text-xs">
                <ReviewStatePill label={t("review_pending_state", { count: Object.values(feedback.commentCounts).reduce((sum, count) => sum + count, 0) })} tone="pending" />
              </div>
            </div>
            {payload.summary ? <Markdown className="chat-prose mt-3 text-sm text-gray-700 dark:text-gray-300" text={payload.summary.text} /> : <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>}
          </section>

          <ReviewArtifactsPanel payload={payload} reviewArtifacts={reviewArtifacts} />
        </div>
        {feedback.panel}
      </section>

      <section className="grid min-h-[42rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[22rem_minmax(0,1fr)] dark:border-gray-700 dark:bg-gray-900">
        <div className="max-h-[42rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {sourceDiff.data.files.map((file) => (
            <button
              className={`flex w-full items-center gap-2 px-3 py-2 text-left font-mono text-xs hover:bg-brand/10 ${selectedPath === file.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
              key={file.path}
              onClick={() => {
                setSelectedPath(file.path)
                document.querySelector(`[data-diff-file="${CSS.escape(file.path)}"]`)?.scrollIntoView({ block: "start" })
              }}
              title={`${file.path} (+${file.additions} -${file.deletions})`}
              type="button"
            >
              <span className="min-w-0 flex-1 truncate">{file.path}</span>
              <span className="text-emerald-600 dark:text-emerald-400">+{file.additions}</span>
              <span className="text-red-600 dark:text-red-400">-{file.deletions}</span>
              {feedback.commentCounts[file.path] ? <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">{feedback.commentCounts[file.path]}</span> : null}
            </button>
          ))}
        </div>
        <div className="min-w-0 overflow-auto">
          <ReviewableDiff
            comments={feedback.diffThreads}
            emptyState={<div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_changed_files")}</div>}
            files={sourceDiff.data.files}
            mode="continuous"
            onCommentLine={startComment}
            onSelectFile={setSelectedPath}
            selectedPath={selectedPath}
            showFileHeaders
            unavailableState={t("source_diff_not_available")}
          />
        </div>
      </section>
    </div>
  )
}

function ReviewArtifactsPanel({ payload, reviewArtifacts }: { payload: JobDetailPayload; reviewArtifacts: string[] }) {
  const { t } = useT("jobs")
  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading>{t("review_artifacts_title")}</SectionHeading>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        {payload.test_plan ? (
          <div className="rounded border border-gray-200 p-3 dark:border-gray-800">
            <p className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("section_test_plan")}</p>
            <ul className="mt-2 list-disc space-y-1 pl-4 text-sm text-gray-700 dark:text-gray-300">
              {payload.test_plan.steps.map((step, index) => <li key={`${index}-${step}`}>{step}</li>)}
            </ul>
          </div>
        ) : null}
        {reviewArtifacts.map((artifact) => (
          <div className="rounded border border-gray-200 p-3 dark:border-gray-800" key={artifact}>
            <p className="text-sm text-gray-700 dark:text-gray-300">{artifact}</p>
          </div>
        ))}
        {payload.typed_artifacts.slice(0, 4).map((artifact) => (
          <div className="rounded border border-gray-200 p-3 dark:border-gray-800" key={artifact.type}>
            <p className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{artifact.title}</p>
            <p className="mt-1 text-sm text-gray-700 dark:text-gray-300">{artifact.renderer_type}</p>
          </div>
        ))}
        {!payload.test_plan && reviewArtifacts.length === 0 && payload.typed_artifacts.length === 0 ? <p className="text-sm text-gray-400 dark:text-gray-500">{t("section_no_artifacts")}</p> : null}
      </div>
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
