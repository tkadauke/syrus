import { getJson, postJson } from "@app/api/client"
import type { RepositoryDetailRecord, RepositoryTab } from "@app/api/repositories"

export type RepositoryIssuesPayload = {
  message?: string | null
  error_message?: string | null
  repository: RepositoryDetailRecord
  tabs: RepositoryTab[]
  state: "open" | "closed"
  issue_count: number
  issues: RepositoryIssue[]
  state_paths: {
    open: string
    closed: string
  }
  paths: {
    github_issues_path: string
    app_comment_issue_path: string
    app_close_issue_path: string
    app_delegate_issue_path: string
    app_bulk_issues_path: string
  }
}

export type RepositoryIssue = {
  number: number
  title: string
  state: string
  html_url: string
  body_excerpt: string
  user_login: string | null
  created_at: string | null
  labels: Array<{
    name: string
    color: string
  }>
  delegated: boolean
}

export function fetchRepositoryIssues(id: string, state: string) {
  const params = new URLSearchParams({ state })
  return getJson<RepositoryIssuesPayload>(`/api/v1/app/repositories/${id}/issues?${params}`)
}

export function commentRepositoryIssue(path: string, values: { issueNumber: number; commentBody: string; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    comment_body: values.commentBody,
    state: values.state
  })
}

export function closeRepositoryIssue(path: string, values: { issueNumber: number; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    state: values.state
  })
}

export function delegateRepositoryIssue(path: string, values: { issueNumber: number; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    state: values.state
  })
}

export function bulkRepositoryIssues(path: string, values: { issueNumbers: number[]; bulkAction: "close" | "delegate"; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_numbers: values.issueNumbers,
    bulk_action: values.bulkAction,
    state: values.state
  })
}
