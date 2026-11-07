import { postJson } from "@app/api/client"
import type { DiffReviewCommentInput, DiffReviewCommentsPayload } from "@app/api/jobs"

export type CognitiveReviewDiscussionEntry = {
  id: number
  body: string
  created_at: string
}

export type CognitiveReviewNotePayload = {
  id: number
  state: string
  discussion_entries: CognitiveReviewDiscussionEntry[]
}

export type CognitiveReviewNotesPayload = {
  note: CognitiveReviewNotePayload
}

export function acknowledgeCognitiveReviewNote(jobId: number, noteId: number) {
  return postJson<CognitiveReviewNotesPayload>(`/api/v1/app/jobs/${jobId}/review_notes/${noteId}/acknowledge`)
}

export function startCognitiveReviewNoteDiscussion(jobId: number, noteId: number, message?: string) {
  return postJson<CognitiveReviewNotesPayload & { redirect_to: string }>(
    `/api/v1/app/jobs/${jobId}/review_notes/${noteId}/start_discussion`,
    message ? { message } : undefined
  )
}

export function createCognitiveReviewNoteComment(jobId: number, input: DiffReviewCommentInput) {
  return postJson<DiffReviewCommentsPayload>(`/api/v1/app/jobs/${jobId}/diff_review_comments`, { diff_review_comment: input })
}
