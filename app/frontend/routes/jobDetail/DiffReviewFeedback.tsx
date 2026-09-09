import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Button } from "../../components/Button"
import { errorMessage } from "../../lib/errorMessage"
import { useConfirm } from "../../hooks/useConfirm"
import { useT } from "../../hooks/useT"
import {
  createDiffReviewComment,
  deleteDiffReviewComment,
  fetchDiffReviewComments,
  replyToDiffReviewComment,
  resolveDiffReviewComment,
  submitDiffReviewComments,
  updateDiffReviewComment,
  type DiffReviewComment,
  type DiffReviewCommentInput,
  type DiffReviewCommentAnchorKind
} from "../../api/jobs"
import { DiffHunkSnippet, type DiffLineSelection, type DiffReviewThread } from "../../components/diff/ReviewableDiff"

type DiffReviewFeedbackOptions = {
  baseRef?: string | null
  buildContext?: (selection: DiffLineSelection) => Record<string, unknown>
  diffReviewVersionId?: number | null
  enabled: boolean
  headRef?: string | null
  includeAllVersions?: boolean
  jobId: number | string
  // Called with a comment's file path when the caller clicks "View in
  // diff". The reviewable diff itself owns navigation (including scrolling
  // a virtualized, not-currently-mounted file into view), so this should
  // route into whatever state that diff's `selectedPath` prop is bound to,
  // e.g. `setSelectedPath`.
  onNavigateToFile?: (path: string) => void
  onViewCommentVersion?: (comment: DiffReviewComment) => void
  runId?: number | null
  supportsGlobalComments?: boolean
  surface: string
  workflowId?: number | null
}

export function diffReviewFeedbackAllowed(jobState: string) {
  return jobState === "implemented" || jobState === "approved" || jobState === "failed"
}

export function useDiffReviewFeedback({
  baseRef,
  buildContext,
  diffReviewVersionId,
  enabled,
  headRef,
  includeAllVersions = false,
  jobId,
  onNavigateToFile,
  onViewCommentVersion,
  runId,
  supportsGlobalComments = false,
  surface,
  workflowId
}: DiffReviewFeedbackOptions) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const { confirm, dialog: confirmDialog } = useConfirm()
  const [selection, setSelection] = useState<DiffLineSelection | null>(null)
  const [body, setBody] = useState("")
  const [editing, setEditing] = useState<DiffReviewComment | null>(null)
  const [reviewCommentBody, setReviewCommentBody] = useState("")
  const [editingThreadId, setEditingThreadId] = useState<number | null>(null)
  const [editingThreadBody, setEditingThreadBody] = useState("")
  const [replyingId, setReplyingId] = useState<number | null>(null)
  const [replyBody, setReplyBody] = useState("")
  const [submitError, setSubmitError] = useState<string | null>(null)
  const search = diffReviewCommentsSearch({ surface, baseRef, diffReviewVersionId, headRef, includeAllVersions, runId, workflowId })
  const commentQueryKey = ["jobs", String(jobId), "diff_review_comments", surface, search] as const
  const comments = useQuery({
    enabled,
    queryKey: commentQueryKey,
    queryFn: () => fetchDiffReviewComments(jobId, search)
  })

  const commentList = comments.data?.comments ?? []
  const selectedVersionComments = commentList.filter((comment) => comment.diff_review_version_id === diffReviewVersionId)
  const counts = useMemo(() => commentCountsByPath(selectedVersionComments), [selectedVersionComments])
  const diffThreads = useMemo(() => diffThreadsByPath(selectedVersionComments), [selectedVersionComments])
  const actionableComments = selectedVersionComments.filter(isSubmittableDiffComment)
  const submittedComments = selectedVersionComments.filter((comment) => comment.state === "submitted")
  const handledComments = selectedVersionComments.filter((comment) => comment.state === "resolved" || comment.workflow?.state === "succeeded")
  const workflowActive = submittedComments.some((comment) => comment.workflow && !terminalWorkflowStates.has(comment.workflow.state))

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
      setEditingThreadId(null)
      setEditingThreadBody("")
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    }
  })
  const resolveComment = useMutation({
    mutationFn: ({ id, versionId }: { id: number; versionId?: number | null }) => resolveDiffReviewComment(jobId, id, versionId),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: commentQueryKey })
  })
  const replyToComment = useMutation({
    mutationFn: ({ id, body: replyText, versionId }: { id: number; body: string; versionId?: number | null }) => replyToDiffReviewComment(jobId, id, replyText, versionId),
    onSuccess: () => {
      setReplyingId(null)
      setReplyBody("")
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    }
  })
  const deleteComment = useMutation({
    mutationFn: ({ id, versionId }: { id: number; versionId?: number | null }) => deleteDiffReviewComment(jobId, id, versionId),
    onSuccess: (_, { id }) => {
      if (editing?.id === id) {
        setEditing(null)
        setBody("")
      }
      if (editingThreadId === id) {
        setEditingThreadId(null)
        setEditingThreadBody("")
      }
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    }
  })
  const submitComments = useMutation({
    mutationFn: (ids: number[]) => submitDiffReviewComments(jobId, ids, diffReviewVersionId),
    onSuccess: () => {
      setSubmitError(null)
      void queryClient.invalidateQueries({ queryKey: commentQueryKey })
    },
    onError: (error) => setSubmitError(errorMessage(error, t("review_submit_error")))
  })

  function startComment(nextSelection: DiffLineSelection) {
    if (!enabled) return
    setSelection(nextSelection)
    setEditing(null)
    setBody("")
  }

  function saveComment() {
    const trimmed = body.trim()
    if (!trimmed) return
    if (editing) {
      updateComment.mutate({ id: editing.id, input: { body: trimmed, diff_review_version_id: editing.diff_review_version_id } })
      return
    }
    if (!selection) return
    createComment.mutate(commentInputForSelection({
      baseRef,
      body: trimmed,
      buildContext,
      diffReviewVersionId,
      headRef,
      runId,
      selection,
      surface,
      workflowId
    }))
  }

  function editComment(comment: DiffReviewComment) {
    setSelection(null)
    setEditing(comment)
    setBody(comment.body)
  }

  function cancelComposer() {
    setSelection(null)
    setEditing(null)
    setBody("")
  }

  function commentOnReview() {
    const trimmed = reviewCommentBody.trim()
    if (!trimmed) return
    createComment.mutate(commentInputForGlobal({ baseRef, body: trimmed, diffReviewVersionId, headRef, runId, surface, workflowId }), {
      onSuccess: () => setReviewCommentBody("")
    })
  }

  function submitFeedback() {
    const trimmed = reviewCommentBody.trim()
    if (!trimmed) {
      submitComments.mutate(actionableComments.map((comment) => comment.id))
      return
    }
    createComment.mutate(commentInputForGlobal({ baseRef, body: trimmed, diffReviewVersionId, headRef, runId, surface, workflowId }), {
      onSuccess: (payload) => {
        setReviewCommentBody("")
        const newCommentId = payload.comments[0]?.id
        const ids = actionableComments.map((comment) => comment.id)
        submitComments.mutate(newCommentId ? [...ids, newCommentId] : ids)
      }
    })
  }

  function startEditThread(thread: DiffReviewThread) {
    setEditingThreadId(thread.id)
    setEditingThreadBody(thread.body)
  }

  function saveEditThread() {
    const trimmed = editingThreadBody.trim()
    if (!trimmed || editingThreadId == null) return
    updateComment.mutate({ id: editingThreadId, input: { body: trimmed, diff_review_version_id: diffReviewVersionId } })
  }

  function cancelEditThread() {
    setEditingThreadId(null)
    setEditingThreadBody("")
  }

  function startReply(commentId: number) {
    setReplyingId(commentId)
    setReplyBody("")
  }

  function saveReply() {
    const trimmed = replyBody.trim()
    if (!trimmed || replyingId == null) return
    const comment = commentList.find((candidate) => candidate.id === replyingId)
    replyToComment.mutate({ id: replyingId, body: trimmed, versionId: comment?.diff_review_version_id ?? diffReviewVersionId })
  }

  function cancelReply() {
    setReplyingId(null)
    setReplyBody("")
  }

  async function requestDeleteComment(commentId: number, versionId?: number | null) {
    const confirmed = await confirm({
      message: t("review_delete_comment_confirm"),
      confirmLabel: t("review_delete_comment"),
      destructive: true
    })
    if (!confirmed) return
    deleteComment.mutate({ id: commentId, versionId })
  }

  const panel = enabled ? (
    <>
      <DiffReviewFeedbackPanel
        actionableComments={actionableComments}
        body={body}
        comments={commentList}
        currentVersionId={diffReviewVersionId ?? null}
        createError={createComment.error}
        createPending={createComment.isPending}
        deleteError={deleteComment.error}
        deletePending={deleteComment.isPending}
        editing={editing}
        handledComments={handledComments}
        isComposing={Boolean(editing)}
        onBodyChange={setBody}
        onCancel={cancelComposer}
        onCancelReply={cancelReply}
        onChangeReplyBody={setReplyBody}
        onComment={commentOnReview}
        onDelete={(comment) => requestDeleteComment(comment.id, comment.diff_review_version_id)}
        onEdit={editComment}
        onReply={saveReply}
        onResolve={(comment) => resolveComment.mutate({ id: comment.id, versionId: comment.diff_review_version_id })}
        onReviewCommentBodyChange={setReviewCommentBody}
        onSave={saveComment}
        onStartReply={startReply}
        onSubmit={submitFeedback}
        onViewInDiff={(comment) => {
          if (onViewCommentVersion) {
            onViewCommentVersion(comment)
            return
          }
          if (!comment.path) return
          if (onNavigateToFile) {
            onNavigateToFile(comment.path)
            return
          }
          scrollToDiffAnchor(comment.path)
        }}
        replyBody={replyBody}
        replyError={replyToComment.error}
        replyPending={replyToComment.isPending}
        replyingId={replyingId}
        resolvePending={resolveComment.isPending}
        reviewCommentBody={reviewCommentBody}
        submitError={submitError}
        submitPending={submitComments.isPending}
        supportsGlobalComments={supportsGlobalComments}
        updateError={updateComment.error}
        updatePending={updateComment.isPending}
        workflowActive={workflowActive}
      />
      {confirmDialog}
    </>
  ) : null

  return {
    commentCounts: counts,
    commentsQuery: comments,
    composingBody: body,
    composingError: createComment.error,
    composingPending: createComment.isPending,
    composingSelection: selection,
    diffThreads,
    editingThreadBody,
    editingThreadId,
    onCancelComposing: cancelComposer,
    onCancelEditThread: cancelEditThread,
    onChangeComposingBody: setBody,
    onChangeEditingThreadBody: setEditingThreadBody,
    onCommentLine: enabled ? startComment : undefined,
    onSaveComposing: saveComment,
    onDeleteThread: enabled ? (thread: DiffReviewThread) => requestDeleteComment(thread.id, diffReviewVersionId) : undefined,
    onSaveEditThread: saveEditThread,
    onStartEditThread: startEditThread,
    panel,
    selectedCommentPath: selection?.file.path || editing?.path || null
  }
}

function DiffReviewFeedbackPanel({
  actionableComments,
  body,
  comments,
  createError,
  currentVersionId,
  createPending,
  deleteError,
  deletePending,
  editing,
  handledComments,
  isComposing,
  onBodyChange,
  onCancel,
  onCancelReply,
  onChangeReplyBody,
  onComment,
  onDelete,
  onEdit,
  onReply,
  onResolve,
  onReviewCommentBodyChange,
  onSave,
  onStartReply,
  onSubmit,
  onViewInDiff,
  replyBody,
  replyError,
  replyPending,
  replyingId,
  resolvePending,
  reviewCommentBody,
  submitError,
  submitPending,
  supportsGlobalComments,
  updateError,
  updatePending,
  workflowActive
}: {
  actionableComments: DiffReviewComment[]
  body: string
  comments: DiffReviewComment[]
  createError: Error | null
  currentVersionId: number | null
  createPending: boolean
  deleteError: Error | null
  deletePending: boolean
  editing: DiffReviewComment | null
  handledComments: DiffReviewComment[]
  isComposing: boolean
  onBodyChange: (body: string) => void
  onCancel: () => void
  onCancelReply: () => void
  onChangeReplyBody: (body: string) => void
  onComment: () => void
  onDelete: (comment: DiffReviewComment) => void
  onEdit: (comment: DiffReviewComment) => void
  onReply: () => void
  onResolve: (comment: DiffReviewComment) => void
  onReviewCommentBodyChange: (body: string) => void
  onSave: () => void
  onStartReply: (commentId: number) => void
  onSubmit: () => void
  onViewInDiff: (comment: DiffReviewComment) => void
  replyBody: string
  replyError: Error | null
  replyPending: boolean
  replyingId: number | null
  resolvePending: boolean
  reviewCommentBody: string
  submitError: string | null
  submitPending: boolean
  supportsGlobalComments: boolean
  updateError: Error | null
  updatePending: boolean
  workflowActive: boolean
}) {
  const { t } = useT("jobs")

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("review_feedback_title")}</h3>
        <div className="flex flex-wrap gap-2">
          <ReviewStatePill label={t("review_pending_state", { count: actionableComments.length })} tone="pending" />
          <ReviewStatePill label={workflowActive ? t("review_submitted_active") : t("review_handled_state", { count: handledComments.length })} tone={workflowActive ? "submitted" : "handled"} />
        </div>
      </div>
      <div className="mt-3 space-y-3">
        {comments.length === 0 ? <p className="text-sm text-gray-400 dark:text-gray-500">{t("review_no_comments")}</p> : comments.map((comment) => {
          const isGlobal = comment.anchor_kind === "review"
          const selectedVersion = comment.diff_review_version_id === currentVersionId
          return (
          <div className={`min-w-0 rounded border p-3 text-sm ${selectedVersion ? "border-gray-200 dark:border-gray-800" : "border-amber-200 bg-amber-50/50 dark:border-amber-900 dark:bg-amber-950/20"}`} data-diff-review-comment-id={comment.id} key={comment.id}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="break-words font-mono text-xs text-gray-500 dark:text-gray-400">
                {isGlobal ? t("review_global_comment_label") : `${comment.path}:${comment.side === "left" ? comment.old_line : comment.new_line}`}
              </span>
              <div className="flex flex-wrap gap-2">
                {!selectedVersion ? <ReviewStatePill label={t("review_version_historical_badge", { version: comment.diff_review_version?.version_index ?? "?" })} tone="submitted" /> : null}
                <ReviewStatePill label={comment.workflow ? `${comment.state} · ${comment.workflow.state}` : comment.state} tone={comment.state === "resolved" ? "handled" : comment.state === "submitted" ? "submitted" : "pending"} />
              </div>
            </div>
            {!isGlobal && comment.diff_hunk ? (
              <div className="mt-2">
                <DiffHunkSnippet highlightLine={diffContextHighlightLine(comment)} hunk={comment.diff_hunk} />
              </div>
            ) : null}
            <p className="mt-2 whitespace-pre-wrap break-words text-gray-800 dark:text-gray-200">{comment.body}</p>
            <div className="mt-3 flex flex-wrap gap-2">
              {comment.state === "draft" && isGlobal ? <Button onClick={() => onEdit(comment)} size="sm" variant="secondary">{t("review_edit_comment")}</Button> : null}
              {supportsGlobalComments && (comment.path || isGlobal) ? <Button onClick={() => onViewInDiff(comment)} size="sm" variant="secondary">{t("review_view_in_diff")}</Button> : null}
              {comment.state !== "resolved" ? <Button disabled={resolvePending} onClick={() => onResolve(comment)} size="sm" variant="secondary">{t("review_resolve_comment")}</Button> : null}
              {replyingId !== comment.id ? <Button onClick={() => onStartReply(comment.id)} size="sm" variant="secondary">{t("review_reply_comment")}</Button> : null}
              {comment.state === "draft" && isGlobal ? <Button disabled={deletePending} onClick={() => onDelete(comment)} size="sm" variant="danger">{t("review_delete_comment")}</Button> : null}
            </div>
            {replyingId === comment.id ? (
              <div className="mt-3 rounded border border-brand/30 bg-brand/5 p-3">
                <textarea
                  aria-label={t("review_reply_comment")}
                  className="min-h-16 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                  onChange={(event) => onChangeReplyBody(event.target.value)}
                  value={replyBody}
                />
                <div className="mt-2 flex flex-wrap gap-2">
                  <Button disabled={!replyBody.trim() || replyPending} onClick={onReply} size="sm">{t("review_send_reply")}</Button>
                  <Button onClick={onCancelReply} size="sm" variant="secondary">{t("tags_cancel")}</Button>
                </div>
                {replyError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(replyError, t("review_reply_error"))}</p> : null}
              </div>
            ) : null}
          </div>
          )
        })}
      </div>
      {deleteError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(deleteError, t("review_delete_error"))}</p> : null}

      {isComposing ? (
        <div className="mt-4 min-w-0 rounded border border-brand/30 bg-brand/5 p-3">
          <p className="break-words font-mono text-xs text-gray-600 dark:text-gray-300">{t("review_global_comment_label")}</p>
          <textarea
            aria-label={t("review_comment_body")}
            className="mt-2 min-h-24 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            onChange={(event) => onBodyChange(event.target.value)}
            value={body}
          />
          <div className="mt-2 flex flex-wrap gap-2">
            <Button disabled={!body.trim() || createPending || updatePending} onClick={onSave} size="sm">{editing ? t("review_save_comment") : t("review_create_comment")}</Button>
            <Button onClick={onCancel} size="sm" variant="secondary">{t("tags_cancel")}</Button>
          </div>
          {createError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(createError, t("review_create_error"))}</p> : null}
          {updateError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(updateError, t("review_update_error"))}</p> : null}
        </div>
      ) : null}

      <div className="mt-4 border-t border-gray-100 pt-4 dark:border-gray-800">
        {supportsGlobalComments ? (
          <textarea
            aria-label={t("review_global_comment_label")}
            className="mb-2 min-h-20 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            onChange={(event) => onReviewCommentBodyChange(event.target.value)}
            placeholder={t("review_global_comment_label")}
            value={reviewCommentBody}
          />
        ) : null}
        <div className="flex flex-wrap gap-2">
          {supportsGlobalComments ? (
            <Button disabled={!reviewCommentBody.trim() || createPending} onClick={onComment} variant="secondary">
              {t("review_comment_button")}
            </Button>
          ) : null}
          <Button disabled={(actionableComments.length === 0 && !reviewCommentBody.trim()) || submitPending || createPending} onClick={onSubmit}>
            {submitPending ? t("submitting") : t("review_submit_feedback")}
          </Button>
        </div>
        {createError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{errorMessage(createError, t("review_create_error"))}</p> : null}
        {submitError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300">{submitError}</p> : null}
      </div>
    </section>
  )
}

function commentInputForSelection({
  baseRef,
  body,
  buildContext,
  diffReviewVersionId,
  headRef,
  runId,
  selection,
  surface,
  workflowId
}: {
  baseRef?: string | null
  body: string
  buildContext?: (selection: DiffLineSelection) => Record<string, unknown>
  diffReviewVersionId?: number | null
  headRef?: string | null
  runId?: number | null
  selection: DiffLineSelection
  surface: string
  workflowId?: number | null
}): DiffReviewCommentInput {
  const left = selection.side === "old"
  return {
    surface,
    diff_review_version_id: diffReviewVersionId,
    base_ref: baseRef,
    head_ref: headRef,
    anchor_kind: "line",
    path: selection.file.path,
    side: left ? "left" : "right",
    old_line: selection.line.oldLine,
    new_line: selection.line.newLine,
    diff_hunk: hunkForLine(selection.file.patch, selection.line),
    body,
    context: {
      line_kind: selection.line.kind,
      line_text: selection.line.code,
      ...(workflowId ? { workflow_id: workflowId } : {}),
      ...(runId ? { run_id: runId } : {}),
      ...(buildContext?.(selection) || {})
    },
    ...(workflowId ? { workflow_id: workflowId } : {}),
    ...(runId ? { run_id: runId } : {})
  }
}

function commentInputForGlobal({
  baseRef,
  body,
  diffReviewVersionId,
  headRef,
  runId,
  surface,
  workflowId
}: {
  baseRef?: string | null
  body: string
  diffReviewVersionId?: number | null
  headRef?: string | null
  runId?: number | null
  surface: string
  workflowId?: number | null
}): DiffReviewCommentInput {
  const anchorKind: DiffReviewCommentAnchorKind = "review"
  return {
    surface,
    diff_review_version_id: diffReviewVersionId,
    base_ref: baseRef,
    head_ref: headRef,
    anchor_kind: anchorKind,
    body,
    context: {
      ...(workflowId ? { workflow_id: workflowId } : {}),
      ...(runId ? { run_id: runId } : {})
    },
    ...(workflowId ? { workflow_id: workflowId } : {}),
    ...(runId ? { run_id: runId } : {})
  }
}

function diffContextHighlightLine(comment: DiffReviewComment): string | null {
  const lineText = comment.context?.line_text
  if (typeof lineText !== "string") return null
  const lineKind = comment.context?.line_kind
  if (lineKind === "add") return `+${lineText}`
  if (lineKind === "delete") return `-${lineText}`
  return ` ${lineText}`
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
    if (!comment.path) return counts
    counts[comment.path] = (counts[comment.path] || 0) + 1
    return counts
  }, {})
}

function diffThreadsByPath(comments: DiffReviewComment[]) {
  return comments.reduce<Record<string, Record<string, DiffReviewThread[]>>>((paths, comment) => {
    if (comment.state === "superseded") return paths
    if (!comment.path) return paths
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

function diffReviewCommentsSearch({ baseRef, diffReviewVersionId, headRef, includeAllVersions, runId, surface, workflowId }: {
  baseRef?: string | null
  diffReviewVersionId?: number | null
  headRef?: string | null
  includeAllVersions?: boolean
  runId?: number | null
  surface: string
  workflowId?: number | null
}) {
  const params = new URLSearchParams({ surface })
  if (includeAllVersions) {
    params.set("all_versions", "1")
  } else {
    if (diffReviewVersionId) params.set("diff_review_version_id", String(diffReviewVersionId))
    if (baseRef) params.set("base_ref", baseRef)
    if (headRef) params.set("head_ref", headRef)
  }
  if (runId) params.set("run_id", String(runId))
  if (workflowId) params.set("workflow_id", String(workflowId))
  return `?${params.toString()}`
}

function scrollToDiffAnchor(path: string) {
  document.querySelector(`[data-diff-file="${CSS.escape(path)}"]`)?.scrollIntoView({ block: "center" })
}

function ReviewStatePill({ label, tone }: { label: string; tone: "pending" | "submitted" | "handled" }) {
  const className = {
    handled: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-200",
    pending: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-200",
    submitted: "bg-info/10 text-info"
  }[tone]
  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${className}`}>{label}</span>
}

const terminalWorkflowStates = new Set(["succeeded", "failed", "cancelled"])
const retryableWorkflowStates = new Set(["failed", "cancelled"])

function isSubmittableDiffComment(comment: DiffReviewComment) {
  if (comment.state === "draft") return true
  if (comment.state !== "submitted") return false

  return retryableWorkflowStates.has(comment.workflow?.state || "")
}
