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
