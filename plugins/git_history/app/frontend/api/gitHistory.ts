import { getJson } from "@app/api/client"

export type GitHistoryJobRef = { id: number; slug: string; title: string | null }
export type GitHistoryEpicRef = { id: number; slug: string; title: string | null }
export type GitHistoryUserRef = { id: number; display_name: string }
export type GitHistoryGitIdentity = { name: string | null; email: string | null }

export type GitHistoryOrigin =
  | { type: "unknown" }
  | { type: "github_issue"; issue_number: number | null; issue_url: string | null }
  | { type: "cron"; scheduled_task: { id: number; name: string } }
  | { type: "chat"; chat_session_id?: number; chat_title?: string | null }

export type GitHistorySyrusLandedCommit = {
  classification: "syrus_landed"
  sha: string
  short_sha: string
  subject: string
  authored_at: string
  job: GitHistoryJobRef
  epic: GitHistoryEpicRef | null
  user: GitHistoryUserRef | null
  origin: GitHistoryOrigin
}

export type GitHistoryExternalPrCommit = {
  classification: "external_pr"
  sha: string
  short_sha: string
  subject: string
  authored_at: string
  job: GitHistoryJobRef
  pr_number: number | null
  pr_url: string | null
  author: GitHistoryGitIdentity
  committer: GitHistoryGitIdentity
  github_author: string | null
}

export type GitHistoryExternalPushCommit = {
  classification: "external_push"
  sha: string
  short_sha: string
  subject: string
  authored_at: string
  author: GitHistoryGitIdentity
  committer: GitHistoryGitIdentity
}

export type GitHistoryCommit = GitHistorySyrusLandedCommit | GitHistoryExternalPrCommit | GitHistoryExternalPushCommit

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
  const qs = params.toString()

  return getJson<GitHistoryPage>(`/api/v1/app/repositories/${repositoryId}/git_history/commits${qs ? `?${qs}` : ""}`)
}
