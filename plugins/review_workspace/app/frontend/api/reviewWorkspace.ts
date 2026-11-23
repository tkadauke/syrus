import { getJson } from "@app/api/client"

export type ReviewWorkspaceJob = {
  id: number
  revision: number
  slug: string
  title: string
  priority: string
  ready_at: string
  dependency_blocked: boolean
  repository: { id: number; slug: string }
  pr_number: number | null
}

export type ReviewWorkspacePayload = { count: number; jobs: ReviewWorkspaceJob[] }

export function fetchReviewWorkspace() {
  return getJson<ReviewWorkspacePayload>("/api/v1/app/review_workspace")
}

export type ReviewWorkspaceSummary = {
  current_head_sha?: string | null
  change_scope: { files_changed: number; additions: number; deletions: number; truncated?: boolean } | null
}

export function fetchReviewWorkspaceSummary(jobId: number) {
  return getJson<ReviewWorkspaceSummary>(`/api/v1/app/review_workspace/${jobId}/summary`)
}
