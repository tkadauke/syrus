import { getJson, postJson } from "@app/api/client"
import type { RepositoryDetailRecord, RepositoryTab } from "@app/api/repositories"

export type IssueFolder = "inbox" | "delegated" | "open" | "closed"

export const ISSUE_FOLDERS: IssueFolder[] = [ "inbox", "delegated", "open", "closed" ]

export type RepositoryIssuesPayload = {
  message?: string | null
  error_message?: string | null
  repository: RepositoryDetailRecord
  tabs: RepositoryTab[]
  folder: IssueFolder
  query: string | null
  issue_count: number
  issues: RepositoryIssue[]
  folder_counts: Record<IssueFolder, number>
  folder_paths: Record<IssueFolder, string>
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

export function fetchRepositoryIssues(id: string, folder: IssueFolder, query: string) {
  const params = new URLSearchParams({ folder })
  if (query) params.set("q", query)
  return getJson<RepositoryIssuesPayload>(`/api/v1/app/repositories/${id}/issues?${params}`)
}

export function commentRepositoryIssue(path: string, values: { issueNumber: number; commentBody: string; folder: IssueFolder; query: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    comment_body: values.commentBody,
    folder: values.folder,
    q: values.query
  })
}

export function closeRepositoryIssue(path: string, values: { issueNumber: number; folder: IssueFolder; query: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    folder: values.folder,
    q: values.query
  })
}

export function delegateRepositoryIssue(path: string, values: { issueNumber: number; folder: IssueFolder; query: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    folder: values.folder,
    q: values.query
  })
}

export function bulkRepositoryIssues(path: string, values: { issueNumbers: number[]; bulkAction: "close" | "delegate"; folder: IssueFolder; query: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_numbers: values.issueNumbers,
    bulk_action: values.bulkAction,
    folder: values.folder,
    q: values.query
  })
}
