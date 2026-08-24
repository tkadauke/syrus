import { getJson } from "@app/api/client"

export type GitHistoryJobRef = { id: number; slug: string; title: string | null }
export type GitHistoryEpicRef = { id: number; slug: string; title: string | null }
export type GitHistoryUserRef = { id: number; display_name: string }
export type GitHistoryPersonRef = { name: string | null; email: string | null }

export type GitHistoryOrigin =
  | { type: "chat"; chat_session_id?: number; chat_title?: string | null }
  | { type: "cron"; scheduled_task: { id: number; name: string } }
  | { type: "github_issue"; issue_number: number | null; issue_url: string | null }
  | { type: "unknown" }

export type GitHistoryCommit = {
  sha: string
  short_sha: string
  subject: string
  authored_at: string | null
  classification: "syrus_landed" | "external_pr" | "external_push"
  job?: GitHistoryJobRef
  epic?: GitHistoryEpicRef | null
  user?: GitHistoryUserRef | null
  origin?: GitHistoryOrigin
  pr_number?: number
  pr_url?: string | null
  github_author?: string | null
  author?: GitHistoryPersonRef
  committer?: GitHistoryPersonRef
}

export type GitHistoryPage = {
  repository: { id: number; slug: string }
  available: boolean
  commits: GitHistoryCommit[]
  next_cursor: string | null
  has_more: boolean
}

export function fetchGitHistory(repositoryId: string | number, cursor?: string | null) {
  const params = new URLSearchParams()
  if (cursor) params.set("cursor", cursor)
  const query = params.toString()
  return getJson<GitHistoryPage>(`/api/v1/app/repositories/${repositoryId}/git_history/commits${query ? `?${query}` : ""}`)
}
