import { postJson } from "@app/api/client"

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
  job_id: number
  diff_review_version_id?: number | null
  unresolved_count: number
  handled_count: number
  notes: CognitiveReviewNotePayload[]
}

export function acknowledgeCognitiveReviewNote(jobId: number, noteId: number) {
  return postJson<CognitiveReviewNotesPayload>(`/api/v1/app/jobs/${jobId}/cognitive_review_notes/${noteId}/acknowledge`)
}

export function discussCognitiveReviewNote(jobId: number, noteId: number, body: string) {
  return postJson<CognitiveReviewNotesPayload>(`/api/v1/app/jobs/${jobId}/cognitive_review_notes/${noteId}/discussion_entries`, {
    body,
    metadata: { source: "review_tab" }
  })
}
