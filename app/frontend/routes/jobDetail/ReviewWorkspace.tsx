import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Button } from "../../components/Button"
import { SectionHeading } from "../../components/Heading"
import { Markdown } from "../../lib/Markdown"
import { errorMessage } from "../../lib/errorMessage"
import { useT } from "../../hooks/useT"
import {
  createDiffReviewComment,
  fetchDiffReviewComments,
  fetchJobSourceDiff,
  resolveDiffReviewComment,
  submitDiffReviewComments,
  updateDiffReviewComment,
  type DiffReviewComment,
  type DiffReviewCommentInput,
  type JobDetailPayload,
  type JobSourceDiffPayload,
  type JobWorkflow
} from "../../api/jobs"
import { ReviewableDiff, type DiffLineSelection, type DiffReviewThread } from "../../components/diff/ReviewableDiff"
import { PanelMessage } from "./components"
import { stepArtifactAdversarialReview, stepArtifactTestPlan, stepArtifactVisualReview } from "./stepArtifacts"

const SURFACE = "job_review_workspace"

export function ReviewWorkspace({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const jobId = payload.job.id
  const sourceDiff = useQuery({
    queryKey: ["jobs", String(jobId), "review_source_diff"],
    queryFn: () => fetchJobSourceDiff(String(jobId)),
    placeholderData: keepPreviousData
  })
  const comments = useQuery({
    queryKey: ["jobs", String(jobId), "diff_review_comments", SURFACE],
    queryFn: () => fetchDiffReviewComments(jobId, `?surface=${SURFACE}`),
    placeholderData: keepPreviousData
  })
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const [selection, setSelection] = useState<DiffLineSelection | null>(null)
  const [body, setBody] = useState("")
  const [editing, setEditing] = useState<DiffReviewComment | null>(null)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const commentQueryKey = ["jobs", String(jobId), "diff_review_comments", SURFACE] as const

  const createComment = useMutation({
    mutationFn: (input: DiffReviewCommentInput) => createDiffReviewComment(jobId, input),
    onSuccess: () => {
      setSelection(null)
      setBody("")
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    }
  })
  const updateComment = useMutation({
    mutationFn: ({ id, input }: { id: number; input: Partial<DiffReviewCommentInput> }) => updateDiffReviewComment(jobId, id, input),
    onSuccess: () => {
      setEditing(null)
      setBody("")
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    }
  })
  const resolveComment = useMutation({
    mutationFn: (id: number) => resolveDiffReviewComment(jobId, id),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: commentQueryKey })
  })
  const submitComments = useMutation({
    mutationFn: (ids: number[]) => submitDiffReviewComments(jobId, ids),
    onSuccess: () => {
      setSubmitError(null)
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    },
    onError: (error) => setSubmitError(errorMessage(error, t("review_submit_error")))
  })

  const commentList = comments.data?.comments ?? []
  const counts = useMemo(() => commentCountsByPath(commentList), [commentList])
  const diffThreads = useMemo(() => diffThreadsByPath(commentList), [commentList])
  const actionableComments = commentList.filter(isSubmittableDiffComment)
  const submittedComments = commentList.filter((comment) => comment.state === "submitted")
  const handledComments = commentList.filter((comment) => comment.state === "resolved" || comment.workflow?.state === "succeeded")
  const workflowActive = submittedComments.some((comment) => comment.workflow && !terminalWorkflowStates.has(comment.workflow.state))
  const reviewArtifacts = reviewArtifactSummaries(payload.workflows)

  function startComment(nextSelection: DiffLineSelection) {
    setSelection(nextSelection)
    setEditing(null)
    setBody("")
    setSelectedPath(nextSelection.file.path)
  }

  function saveComment() {
    const trimmed = body.trim()
    if (!trimmed) return
    if (editing) {
      updateComment.mutate({ id: editing.id, input: { body: trimmed } })
      return
    }
    if (!selection) return
    createComment.mutate(commentInputForSelection(selection, sourceDiff.data, trimmed))
  }

  function editComment(comment: DiffReviewComment) {
    setSelection(null)
    setEditing(comment)
    setBody(comment.body)
    setSelectedPath(comment.path)
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
                <ReviewStatePill label={t("review_pending_state", { count: actionableComments.length })} tone="pending" />
                <ReviewStatePill label={workflowActive ? t("review_submitted_active") : t("review_submitted_state", { count: submittedComments.length })} tone="submitted" />
                <ReviewStatePill label={t("review_handled_state", { count: handledComments.length })} tone="handled" />
              </div>
            </div>
            {payload.summary ? <Markdown className="chat-prose mt-3 text-sm text-gray-700 dark:text-gray-300" text={payload.summary.text} /> : <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>}
          </section>

          <ReviewArtifactsPanel payload={payload} reviewArtifacts={reviewArtifacts} />
        </div>

        <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
          <SectionHeading>{t("review_feedback_title")}</SectionHeading>
          <div className="mt-3 space-y-3">
            {commentList.length === 0 ? <p className="text-sm text-gray-400 dark:text-gray-500">{t("review_no_comments")}</p> : commentList.map((comment) => (
              <div className="rounded border border-gray-200 p-3 text-sm dark:border-gray-800" key={comment.id}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{comment.path}:{comment.side === "left" ? comment.old_line : comment.new_line}</span>
                  <ReviewStatePill label={comment.workflow ? `${comment.state} · ${comment.workflow.state}` : comment.state} tone={comment.state === "resolved" ? "handled" : comment.state === "submitted" ? "submitted" : "pending"} />
                </div>
                <p className="mt-2 whitespace-pre-wrap text-gray-800 dark:text-gray-200">{comment.body}</p>
                <div className="mt-3 flex flex-wrap gap-2">
                  {comment.state === "draft" ? <Button onClick={() => editComment(comment)} size="sm" variant="secondary">{t("review_edit_comment")}</Button> : null}
                  {comment.state !== "resolved" ? <Button disabled={resolveComment.isPending} onClick={() => resolveComment.mutate(comment.id)} size="sm" variant="secondary">{t("review_resolve_comment")}</Button> : null}
                </div>
              </div>
            ))}
          </div>

          {selection || editing ? (
            <div className="mt-4 rounded border border-brand/30 bg-brand/5 p-3">
              <p className="font-mono text-xs text-gray-600 dark:text-gray-300">
                {editing ? `${editing.path}:${editing.side === "left" ? editing.old_line : editing.new_line}` : `${selection?.file.path}:${selection?.side === "old" ? selection.line.oldLine : selection?.line.newLine}`}
              </p>
              <textarea
                aria-label={t("review_comment_body")}
                className="mt-2 min-h-24 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                onChange={(event) => setBody(event.target.value)}
                value={body}
              />
              <div className="mt-2 flex flex-wrap gap-2">
                <Button disabled={!body.trim() || createComment.isPending || updateComment.isPending} onClick={saveComment} size="sm">{editing ? t("review_save_comment") : t("review_create_comment")}</Button>
                <Button onClick={() => { setSelection(null); setEditing(null); setBody("") }} size="sm" variant="secondary">{t("tags_cancel")}</Button>
              </div>
              {createComment.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(createComment.error, t("review_create_error"))}</p> : null}
              {updateComment.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(updateComment.error, t("review_update_error"))}</p> : null}
            </div>
          ) : null}

          <div className="mt-4 border-t border-gray-100 pt-4 dark:border-gray-800">
            <Button disabled={actionableComments.length === 0 || submitComments.isPending} onClick={() => submitComments.mutate(actionableComments.map((comment) => comment.id))}>
              {submitComments.isPending ? t("submitting") : t("review_submit_feedback")}
            </Button>
            {submitError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{submitError}</p> : null}
          </div>
        </section>
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
              {counts[file.path] ? <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">{counts[file.path]}</span> : null}
            </button>
          ))}
        </div>
        <div className="min-w-0 overflow-auto">
          <ReviewableDiff
            comments={diffThreads}
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

function commentInputForSelection(selection: DiffLineSelection, diff: JobSourceDiffPayload | undefined, body: string): DiffReviewCommentInput {
  const left = selection.side === "old"
  return {
    surface: SURFACE,
    base_ref: diff?.base_ref,
    head_ref: diff?.head_ref,
    path: selection.file.path,
    side: left ? "left" : "right",
    old_line: selection.line.oldLine,
    new_line: selection.line.newLine,
    diff_hunk: hunkForLine(selection.file.patch, selection.line),
    body,
    context: {
      line_kind: selection.line.kind,
      line_text: selection.line.code
    }
  }
}

function hunkForLine(patch: string | null, line: DiffLineSelection["line"]) {
  if (!patch) return null
  const rows = patch.split("\n")
  const marker = line.newLine != null ? `+${line.code}` : line.oldLine != null ? `-${line.code}` : ` ${line.code}`
  const index = rows.findIndex((row) => row === marker)
  if (index === -1) return rows.find((row) => row.startsWith("@@ ")) || null
  return rows.slice(Math.max(0, index - 4), Math.min(rows.length, index + 5)).join("\n")
}

function commentCountsByPath(comments: DiffReviewComment[]) {
  return comments.reduce<Record<string, number>>((counts, comment) => {
    if (comment.state === "resolved" || comment.state === "superseded") return counts
    counts[comment.path] = (counts[comment.path] || 0) + 1
    return counts
  }, {})
}

function diffThreadsByPath(comments: DiffReviewComment[]) {
  return comments.reduce<Record<string, Record<string, DiffReviewThread[]>>>((paths, comment) => {
    if (comment.state === "superseded") return paths
    const pathThreads = paths[comment.path] || {}
    const anchorThreads = pathThreads[comment.anchor_key] || []
    pathThreads[comment.anchor_key] = [
      ...anchorThreads,
      {
        id: comment.id,
        author: comment.user?.display_name || comment.user?.email_address,
        body: comment.body,
        state: comment.state,
        workflowState: comment.workflow?.state || null
      }
    ]
    paths[comment.path] = pathThreads
    return paths
  }, {})
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

const terminalWorkflowStates = new Set(["succeeded", "failed", "cancelled"])
const retryableWorkflowStates = new Set(["failed", "cancelled"])

function isSubmittableDiffComment(comment: DiffReviewComment) {
  if (comment.state === "draft") return true
  if (comment.state !== "submitted") return false

  return retryableWorkflowStates.has(comment.workflow?.state || "")
}
